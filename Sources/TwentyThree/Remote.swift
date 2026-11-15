import Foundation
import Network
import Combine

// MARK: - Which Mac runs 23

/// 23 either runs here (the mini) or is a remote for another Mac's 23 over Tailscale (the MacBook).
enum Remote {
    static let port: UInt16 = 2323

    /// The other Mac this one is a remote for ("" = this Mac runs 23 itself). Read at launch.
    static var host: String {
        get { UserDefaults.standard.string(forKey: "remoteHost") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "remoteHost") }
    }
    static let active: Bool = !(UserDefaults.standard.string(forKey: "remoteHost") ?? "").isEmpty
    static var base: URL? { active ? URL(string: "http://\(reachableHost):\(port)") : nil }

    /// The other Mac's Tailscale address, remembered with its name: used when this Mac can't look the name up
    /// (Tailscale's "Use Tailscale DNS" switched off here).
    static var address: String {
        get { UserDefaults.standard.string(forKey: "remoteAddress") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "remoteAddress") }
    }

    /// The host to use: the name if this Mac can look it up, otherwise the remembered address.
    static var reachableHost: String {
        let a = address
        guard !a.isEmpty, host != a, !nameResolves else { return host }
        return a
    }
    private static let nameResolves: Bool = {
        let h = UserDefaults.standard.string(forKey: "remoteHost") ?? ""
        var res: UnsafeMutablePointer<addrinfo>?
        let ok = getaddrinfo(h, nil, nil, &res) == 0
        if let res { freeaddrinfo(res) }
        return ok
    }()

    /// A remote set up before addresses were remembered: find the address through Tailscale.
    @MainActor static func learnAddressIfNeeded() async {
        guard active, address.isEmpty, !nameResolves else { return }
        let short = host.split(separator: ".").first.map(String.init) ?? host
        let peers = await Discovery.find()
        if let p = peers.first(where: { $0.dnsName == host || $0.dnsName.hasPrefix(short + ".") }) ?? peers.first {
            address = p.address
            Visualizer.shared.log("remote: \(host) doesn't resolve here; using its Tailscale address \(p.address)")
            ConversationStore.shared.refreshRemote()
        }
    }

    /// Switches this Mac to being a remote for `peer` (restart follows).
    static func use(_ peer: Discovery.Peer) {
        host = peer.dnsName.isEmpty ? peer.address : peer.dnsName
        address = peer.address
    }

    /// Whether this Mac serves its 23 to the other devices on the tailnet.
    static var serving: Bool {
        get { UserDefaults.standard.object(forKey: "serveTailnet") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "serveTailnet") }
    }

    /// This Mac's Tailscale address (100.64.0.0/10), if Tailscale is up.
    static var tailscaleAddress: String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            var sin = UnsafeRawPointer(a).load(as: sockaddr_in.self)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buf)
            if isTailnet(ip) { return ip }
        }
        return nil
    }

    /// Tailscale's address range, 100.64.0.0/10.
    static func isTailnet(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

/// What the remote sees of one chat.
struct RemoteSnapshot: Codable {
    var id: UUID
    var revision: Int
    var title: String
    var updated: Date
    var pinned: Bool
    var agentName: String?
    var messages: [ChatMessage]
    var state: String
    var statusLine: String
    var contextTokens: Int
    var droppedOldMessages: Bool
    var compacted: Bool
    var canCompact: Bool
    var thinkEnabled: Bool
}

struct RemoteSummary: Codable { var id: UUID; var title: String; var updated: Date; var pinned: Bool; var agentName: String? }

extension OrbState {
    var isWorking: Bool { self == .thinking || self == .speaking || self == .acting }
    var wire: String {
        switch self { case .idle: "idle"; case .thinking: "thinking"; case .speaking: "speaking"; case .acting: "acting"
        case .error: "error"; case .listening: "listening"; case .talking: "talking" }
    }
    init(wire: String) {
        switch wire { case "thinking": self = .thinking; case "speaking": self = .speaking; case "acting": self = .acting
        case "error": self = .error; case "talking": self = .talking; default: self = .idle }
    }
}

// MARK: - The mini: serving 23 over Tailscale

@MainActor
final class RemoteServer: ObservableObject {
    static let shared = RemoteServer()
    @Published private(set) var listeningOn: String?
    @Published private(set) var lastClient: String?
    private var listener: SocketListener?
    private var revisions: [UUID: Int] = [:]
    private var watching: [UUID: AnyCancellable] = [:]
    private var retry: Timer?
    private var seenClients = Set<String>()

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    func start() {
        guard Remote.serving, !Remote.active else { return }
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in RemoteServer.shared.ensureListening() } }
        ensureListening()
    }

    func stop() { listener?.cancel(); listener = nil; listeningOn = nil; retry?.invalidate() }

    /// Listens on the Tailscale address only: not on the home network, not on the internet.
    private func ensureListening() {
        guard Remote.serving else { stop(); return }
        guard let ip = Remote.tailscaleAddress else {
            if listener != nil { listener?.cancel(); listener = nil; listeningOn = nil }
            return
        }
        if listeningOn == ip, listener != nil { return }
        listener?.cancel()
        // A plain socket bound to the Tailscale address (Network.framework's listener scopes itself to one interface,
        // which drops connections that reach this address another way).
        guard let l = SocketListener(ip: ip, port: Remote.port, handler: { req, client in
            await RemoteServer.shared.serve(req, from: client)
        }) else { Visualizer.shared.log("remote: couldn't listen on \(ip):\(Remote.port)"); return }
        listener = l
        listeningOn = ip
        Visualizer.shared.log("remote: serving on \(ip):\(Remote.port) (Tailscale only)")
    }

    private func serve(_ req: HTTPRequest, from client: String) async -> HTTPResponse {
        // Only the tailnet may talk to it (the socket is bound to the Tailscale address anyway).
        guard Remote.isTailnet(client) else { return HTTPResponse(status: 400) }
        if !seenClients.contains(client) { seenClients.insert(client); ActivityLog.add("remote", "connected from \(client)") }
        lastClient = client
        return await handle(req)
    }

    // MARK: Requests

    private func handle(_ r: HTTPRequest) async -> HTTPResponse {
        let parts = r.path.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
        let store = ConversationStore.shared
        func json<T: Encodable>(_ v: T) -> HTTPResponse { HTTPResponse(status: 200, body: (try? Self.encoder.encode(v)) ?? Data(), type: "application/json") }
        func body() -> [String: Any] { (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:] }
        let ok = HTTPResponse(status: 200, body: Data("{}".utf8), type: "application/json")

        switch (r.method, parts) {
        case ("GET", ["23.zip"]):
            // The app itself, so another Mac on the tailnet can install it as a remote (Safari: http://<this Mac>:2323/23.zip).
            let zip = FileManager.default.temporaryDirectory.appendingPathComponent("23-\(UUID().uuidString.prefix(6)).zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", Bundle.main.bundlePath, zip.path]
            try? p.run(); p.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: zip) }
            guard let d = try? Data(contentsOf: zip) else { return HTTPResponse(status: 500) }
            ActivityLog.add("remote", "app downloaded")
            return HTTPResponse(status: 200, body: d, type: "application/zip")

        case ("GET", ["v1", "hello"]):
            return json(["name": Host.current().localizedName ?? "23", "model": Prefs.model, "app": "23"])

        case ("GET", ["v1", "chats"]):
            return json(store.summaries.map { RemoteSummary(id: $0.id, title: $0.title, updated: $0.updated, pinned: $0.pinned,
                                                             agentName: $0.agentID.flatMap { AgentStore.shared.agent($0)?.name }) })

        case (_, let p) where p.count >= 3 && p[0] == "v1" && p[1] == "chat":
            guard let id = UUID(uuidString: p[2]) else { return HTTPResponse(status: 400) }
            let rest = Array(p.dropFirst(3))
            if r.method == "GET" && rest.isEmpty {
                guard let c = store.chat(id) else { return HTTPResponse(status: 404) }
                watch(c)
                let rev = revisions[id] ?? 0
                if let since = r.query["since"].flatMap(Int.init), since == rev { return HTTPResponse(status: 304) }
                return json(snapshot(c, rev))
            }
            guard r.method == "POST", let action = rest.first else { return HTTPResponse(status: 404) }
            let b = body()
            switch action {
            case "send":
                let c = store.chat(id) ?? store.remoteChat(id)
                watch(c)
                var atts: [Attachment] = []
                for f in b["attachments"] as? [[String: Any]] ?? [] {
                    guard let name = f["name"] as? String, let data = (f["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { continue }
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent((name as NSString).lastPathComponent)
                    try? FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? data.write(to: tmp)) != nil, var a = try? AttachmentStore.add(tmp) { a.original = nil; atts.append(a) }
                    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
                }
                if let t = b["think"] as? Bool { c.thinkEnabled = t }
                c.silent = true              // replies are read aloud on the remote, not on this Mac
                c.send(b["text"] as? String ?? "", spoken: b["spoken"] as? Bool ?? false, attachments: atts)
                return json(snapshot(c, revisions[id] ?? 0))
            case "approve":
                guard let c = store.chat(id), let card = (b["card"] as? String).flatMap(UUID.init(uuidString:)) else { return HTTPResponse(status: 404) }
                c.answerApproval(card, approved: b["approved"] as? Bool ?? false)
                return ok
            case "undo":
                guard let c = store.chat(id), let card = (b["card"] as? String).flatMap(UUID.init(uuidString:)) else { return HTTPResponse(status: 404) }
                c.undoAction(card); return ok
            case "stop": store.chat(id)?.stop(); return ok
            case "compact": store.chat(id)?.compactNow(); return ok
            case "rename": store.rename(id, to: b["title"] as? String ?? ""); return ok
            case "pin": store.togglePin(id); return ok
            case "delete": store.delete(id); return ok
            case "opened": store.touch(id); return ok
            default: return HTTPResponse(status: 404)
            }

        case ("POST", ["v1", "transcribe"]):
            // The remote's microphone recording (16 kHz WAV), transcribed here by whisper.
            do { return json(["text": try await Voice.shared.transcribeWithWhisper(r.body)]) }
            catch { return HTTPResponse(status: 500, body: Data(error.localizedDescription.utf8)) }

        case ("POST", ["v1", "audio", "speech"]):
            // The remote's voice: Kokoro runs here and the audio goes back.
            guard await Voice.shared.ensureKokoro() else { return HTTPResponse(status: 503) }
            var req = URLRequest(url: Voice.kokoroBase.appendingPathComponent("v1/audio/speech"))
            req.httpMethod = "POST"; req.httpBody = r.body; req.timeoutInterval = 60
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return HTTPResponse(status: 502) }
            return HTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 200, body: data, type: "application/octet-stream")

        default:
            return HTTPResponse(status: 404)
        }
    }

    /// Bumps a chat's revision whenever it changes, so remotes only fetch it when there's something new.
    private func watch(_ c: ChatModel) {
        guard watching[c.id] == nil else { return }
        watching[c.id] = c.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.revisions[c.id, default: 0] += 1 } }
    }

    private func snapshot(_ c: ChatModel, _ rev: Int) -> RemoteSnapshot {
        RemoteSnapshot(id: c.id, revision: rev, title: c.title, updated: c.updated, pinned: c.pinned, agentName: c.agent?.name,
                       messages: c.messages, state: c.isPaused ? "acting" : c.state.wire, statusLine: c.statusLine,
                       contextTokens: c.contextTokens, droppedOldMessages: c.droppedOldMessages, compacted: !c.contextSummary.isEmpty,
                       canCompact: c.canCompact, thinkEnabled: c.thinkEnabled)
    }
}

// MARK: - The MacBook: talking to the mini

@MainActor
enum RemoteClient {
    static func request(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil, timeout: TimeInterval = 20) async throws -> (Data, Int) {
        guard let base = Remote.base else { throw AddonError.message("No remote Mac is set.") }
        var req = URLRequest(url: URL(string: base.absoluteString + path)!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let body { req.httpBody = body }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func hello() async throws -> [String: String] {
        let (d, code) = try await request("GET", "/v1/hello", timeout: 6)
        guard code == 200, let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { throw AddonError.message("It answered, but not like 23 (\(code)).") }
        return o
    }

    static func summaries() async throws -> [RemoteSummary] {
        let (d, code) = try await request("GET", "/v1/chats")
        guard code == 200 else { throw AddonError.message("The other Mac answered \(code).") }
        return try RemoteServer.decoder.decode([RemoteSummary].self, from: d)
    }

    /// The chat if it changed since `since` (nil = unchanged).
    static func snapshot(_ id: UUID, since: Int?) async throws -> RemoteSnapshot? {
        let (d, code) = try await request("GET", "/v1/chat/\(id.uuidString)" + (since.map { "?since=\($0)" } ?? ""))
        if code == 304 || code == 404 { return nil }
        guard code == 200 else { throw AddonError.message("The other Mac answered \(code).") }
        return try RemoteServer.decoder.decode(RemoteSnapshot.self, from: d)
    }

    static func post(_ id: UUID, _ action: String, _ json: [String: Any] = [:], timeout: TimeInterval = 20) async throws {
        let (_, code) = try await request("POST", "/v1/chat/\(id.uuidString)/\(action)", json: json, timeout: timeout)
        guard code == 200 else { throw AddonError.message("The other Mac answered \(code).") }
    }
}

// MARK: - A tiny HTTP/1.1 parser and writer (one request per connection)

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var length = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            length = Int(l.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(first[0])
        let target = String(first[1])
        path = target
        var q: [String: String] = [:]
        if let qs = target.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { q[String(kv[0])] = String(kv[1]).removingPercentEncoding }
            }
        }
        query = q
        body = data[bodyStart..<(bodyStart + length)]
    }
}

struct HTTPResponse {
    var status: Int
    var body = Data()
    var type = "text/plain"
    var bytes: Data {
        let reason = [200: "OK", 304: "Not Modified", 400: "Bad Request", 404: "Not Found", 500: "Error", 502: "Bad Gateway", 503: "Unavailable"][status] ?? "Status"
        var d = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        d.append(body)
        return d
    }
}

// MARK: - Settings › General › Remote

import SwiftUI
import AppKit

struct RemoteSettings: View {
    @ObservedObject private var server = RemoteServer.shared
    @State private var serving = Remote.serving
    @State private var host = Remote.host
    @State private var found: [Discovery.Peer] = []
    @State private var searching = false
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        if Remote.active {
            SettingsGroup(title: "This Mac is a remote",
                          note: "Chats, the model, files and actions are on \(Remote.host); this Mac shows them, and listens and speaks for it. The connection goes over Tailscale only.") {
                LabeledContent("Using 23 on") { Text(Remote.host) }
                HStack {
                    Button(testing ? "Checking…" : "Check connection") { Task { await test(Remote.reachableHost) } }.disabled(testing)
                    Spacer()
                    Button("Run 23 on this Mac instead…") { Remote.host = ""; RemoteSettings.relaunch() }
                }
                if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
            }
        } else {
            SettingsGroup(title: "Remote access",
                          note: "Your other devices on Tailscale (like your MacBook) can use this 23: the same chats, with their microphone and speakers. It listens only on the Tailscale network, never on your home network or the internet.") {
                Toggle("Let devices on my Tailscale use 23", isOn: $serving)
                    .onChange(of: serving) { _, v in Remote.serving = v; v ? server.start() : server.stop(); ActivityLog.add("setting", "remote access → \(v ? "on" : "off")") }
                LabeledContent("Status") {
                    Text(!serving ? "off" : server.listeningOn.map { "on, at \($0):\(Remote.port)" } ?? "waiting for Tailscale")
                }
                if let c = server.lastClient { LabeledContent("Last device") { Text(c) } }
            }
            SettingsGroup(title: "Use 23 on another Mac",
                          note: "Turns this Mac into a remote for a Mac that runs 23 (it needs Tailscale on both). This Mac's own chats stay here, unused, until you switch back.") {
                HStack {
                    Button(searching ? "Looking…" : "Find 23 on my Tailscale") { Task { searching = true; found = await Discovery.find(); searching = false
                        result = found.isEmpty ? "No other Mac on your Tailscale is running 23 with remote access on." : nil } }
                        .disabled(searching)
                    Spacer()
                }
                ForEach(found) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) { Text(p.name); Text("\(p.dnsName.isEmpty ? p.address : p.dnsName) · \(p.model)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Use it (restarts 23)") { Remote.use(p); RemoteSettings.relaunch() }
                    }
                }
                TextField("Mac", text: $host, prompt: Text("or type its Tailscale name or 100.x address"))
                HStack {
                    Button(testing ? "Checking…" : "Check") { Task { await test(host) } }.disabled(testing || host.isEmpty)
                    Spacer()
                    Button("Switch to it (restarts 23)") { Remote.host = host; RemoteSettings.relaunch() }.disabled(host.isEmpty)
                }
                if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    private func test(_ h: String) async {
        testing = true; defer { testing = false }
        do {
            var req = URLRequest(url: URL(string: "http://\(h):\(Remote.port)/v1/hello")!)
            req.timeoutInterval = 6
            var answer = try? await URLSession.shared.data(for: req)
            if answer == nil, !Remote.address.isEmpty, h != Remote.address {
                // This Mac may not use Tailscale's DNS: try the remembered address.
                req.url = URL(string: "http://\(Remote.address):\(Remote.port)/v1/hello")
                answer = try? await URLSession.shared.data(for: req)
            }
            guard let (d, _) = answer else { throw URLError(.cannotFindHost) }
            let o = (try? JSONSerialization.jsonObject(with: d) as? [String: String]) ?? [:]
            result = "Connected to 23 on \(o["name"] ?? h), using \(o["model"] ?? "its model")."
        } catch { result = "Couldn't reach it: \(error.localizedDescription). Is 23 running there with remote access on, and Tailscale connected here?" }
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}


/// A minimal TCP server on one address: each connection carries one HTTP request, read off the main thread.
final class SocketListener: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let handler: @MainActor (HTTPRequest, String) async -> HTTPResponse

    init?(ip: String, port: UInt16, handler: @escaping @MainActor (HTTPRequest, String) async -> HTTPResponse) {
        self.handler = handler
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(sock, 32) == 0 else { close(sock); return nil }
        _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK)
        fd = sock
        source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .global())
        let src = source
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.resume()
    }

    func cancel() { source.cancel(); close(fd) }

    private func acceptAll() {
        while true {
            var a = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) } }
            guard c >= 0 else { return }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let client = String(cString: buf)
            DispatchQueue.global().async { self.serve(c, client) }
        }
    }

    private func serve(_ c: Int32, _ client: String) {
        _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var request: HTTPRequest?
        while request == nil {
            let n = recv(c, &chunk, chunk.count, 0)
            if n <= 0 || data.count > 300_000_000 { close(c); return }
            data.append(contentsOf: chunk[0..<n])
            request = HTTPRequest(data)
        }
        let req = request!
        let handler = self.handler
        Task { @MainActor in
            let bytes = await handler(req, client).bytes
            DispatchQueue.global().async {
                bytes.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let n = send(c, raw.baseAddress! + sent, raw.count - sent, 0)
                        if n <= 0 { break }
                        sent += n
                    }
                }
                close(c)
            }
        }
    }
}

/// First launch on a Mac without the AI model: offer to use 23 running on another of the user's Macs.
@MainActor
enum RemoteSetup {
    /// Returns true if the user chose a remote (23 then restarts).
    @discardableResult
    static func offerIfNeeded() async -> Bool {
        var req = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        req.timeoutInterval = 2
        if (try? await URLSession.shared.data(for: req)) != nil { return false }      // this Mac runs Ollama itself
        UserDefaults.standard.set(true, forKey: "askedRemoteSetup")
        let peers = await Discovery.find()
        guard let peer = peers.first else { return false }                           // nothing to offer: Setup takes over
        let alert = NSAlert()
        alert.messageText = "Use 23 on \(peer.name)?"
        alert.informativeText = "This Mac doesn't run an AI model, but 23 is running on \(peer.name) (over Tailscale). This Mac can be its remote: the same chats, with this Mac's microphone and speakers. Or set 23 up to run on this Mac instead."
        alert.addButton(withTitle: "Use \(peer.name)")
        alert.addButton(withTitle: "Run 23 on this Mac")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        Remote.use(peer)
        ActivityLog.add("setting", "use 23 on \(peer.name)")
        RemoteSettings.relaunch()
        return true
    }
}

/// Finds Macs on the user's Tailscale that are running 23 with remote access on.
enum Discovery {
    struct Peer: Identifiable, Hashable { var id: String { address }; let name: String; let dnsName: String; let address: String; let model: String }

    static let cli = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func find() async -> [Peer] {
        guard let cli else { return [] }
        let candidates: [(String, String, String)] = await Task.detached {
            let p = Process(); p.executableURL = URL(fileURLWithPath: cli); p.arguments = ["status", "--json"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (d["Peer"] as? [String: [String: Any]] ?? [:]).values.compactMap { peer in
                guard peer["Online"] as? Bool == true, (peer["OS"] as? String ?? "") == "macOS",
                      let ip = (peer["TailscaleIPs"] as? [String])?.first(where: { !$0.contains(":") }) else { return nil }
                let dns = (peer["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (peer["HostName"] as? String ?? ip, dns, ip)
            }
        }.value
        return await withTaskGroup(of: Peer?.self) { g in
            for (name, dns, ip) in candidates {
                g.addTask {
                    var r = URLRequest(url: URL(string: "http://\(ip):\(Remote.port)/v1/hello")!)
                    r.timeoutInterval = 3
                    guard let (d, _) = try? await URLSession.shared.data(for: r),
                          let o = try? JSONSerialization.jsonObject(with: d) as? [String: String], o["app"] == "23" else { return nil }
                    return Peer(name: o["name"] ?? name, dnsName: dns, address: ip, model: o["model"] ?? "")
                }
            }
            var out: [Peer] = []
            for await p in g { if let p { out.append(p) } }
            return out.sorted { $0.name < $1.name }
        }
    }
}
