import Foundation
import Security

// MARK: - What can be installed

/// Something found in the MCP Registry, in Anthropic's skills, or from a pasted link.
struct AddonCandidate: Identifiable, Hashable {
    enum Kind: String { case npmServer, skill }
    struct EnvVar: Hashable { let name: String; let description: String; let required: Bool; let secret: Bool; let defaultValue: String? }

    var id: String                      // short id: becomes the server id or skill folder
    var kind: Kind
    var title: String
    var summary: String
    var source: String                  // shown to the user: where it comes from
    var npmPackage: String? = nil
    var version: String? = nil
    var args: [String] = []
    var env: [EnvVar] = []
    var repository: String? = nil
    var skillPath: (owner: String, repo: String, ref: String, path: String)? = nil
    var unsupported: String? = nil      // why it can't be installed here (Python without uv, remote, Docker…)

    static func == (a: AddonCandidate, b: AddonCandidate) -> Bool { a.id == b.id && a.source == b.source }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(source) }

    static func slug(_ s: String) -> String {
        let base = s.split(separator: "/").last.map(String.init) ?? s
        let cleaned = base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(cleaned).split(separator: "-").joined(separator: "-").prefix(40))
    }
}

/// Claude's reading of an add-on's code before it is installed.
struct AddonReview: Codable, Equatable {
    var risk: String            // low, medium, high
    var whatItDoes: String
    var needsInternet: Bool
    var touches: String         // files, apps or accounts it reaches
    var redFlags: [String]
    var verdict: String

    enum CodingKeys: String, CodingKey { case risk, whatItDoes = "what_it_does", needsInternet = "needs_internet", touches, redFlags = "red_flags", verdict }
}

enum InstallError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Finding things

@MainActor
enum AddonCatalog {
    private static func json(_ url: String) async throws -> Any {
        guard let u = URL(string: url) else { throw InstallError.message("That isn't a valid address.") }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("23-local-assistant", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw InstallError.message(code == 404 ? "Nothing was found there." : "The server answered \(code).") }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// The official MCP Registry (registry.modelcontextprotocol.io).
    static func searchRegistry(_ q: String) async throws -> [AddonCandidate] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let obj = try await json("https://registry.modelcontextprotocol.io/v0/servers?search=\(enc)&limit=30") as? [String: Any]
        var seen = Set<String>()
        var out: [AddonCandidate] = []
        for entry in obj?["servers"] as? [[String: Any]] ?? [] {
            guard let s = entry["server"] as? [String: Any], let name = s["name"] as? String, !seen.contains(name) else { continue }
            seen.insert(name)
            var c = AddonCandidate(id: AddonCandidate.slug(name), kind: .npmServer, title: name, summary: s["description"] as? String ?? "",
                                   source: "MCP Registry: \(name)", repository: (s["repository"] as? [String: Any])?["url"] as? String)
            let packages = s["packages"] as? [[String: Any]] ?? []
            if let npm = packages.first(where: { $0["registryType"] as? String == "npm" && (($0["transport"] as? [String: Any])?["type"] as? String ?? "stdio") == "stdio" }) {
                c.npmPackage = npm["identifier"] as? String
                c.version = npm["version"] as? String
                c.args = (npm["packageArguments"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String ?? $0["default"] as? String }
                c.env = (npm["environmentVariables"] as? [[String: Any]] ?? []).map {
                    .init(name: $0["name"] as? String ?? "", description: $0["description"] as? String ?? "", required: $0["isRequired"] as? Bool ?? false,
                          secret: $0["isSecret"] as? Bool ?? false, defaultValue: $0["default"] as? String)
                }
            } else if packages.contains(where: { $0["registryType"] as? String == "pypi" }) {
                c.unsupported = "It's a Python server: installing those needs “uv”, which isn't on this Mac yet."
            } else if packages.contains(where: { $0["registryType"] as? String == "oci" }) {
                c.unsupported = "It runs in Docker, which 23 doesn't use."
            } else if s["remotes"] != nil {
                c.unsupported = "It's an online service rather than something that runs on this Mac; 23 only runs local add-ons for now."
            } else {
                c.unsupported = "It doesn't say how to install it."
            }
            out.append(c)
        }
        return out.sorted { ($0.unsupported == nil ? 0 : 1) < ($1.unsupported == nil ? 0 : 1) }
    }

    /// Anthropic's skills (github.com/anthropics/skills).
    static func anthropicSkills(matching q: String) async throws -> [AddonCandidate] {
        let list = try await json("https://api.github.com/repos/anthropics/skills/contents/skills") as? [[String: Any]] ?? []
        let names = list.filter { $0["type"] as? String == "dir" }.compactMap { $0["name"] as? String }
        let words = q.lowercased().split(separator: " ").map(String.init)
        let picked = names.filter { n in words.isEmpty || words.contains { n.contains($0) } }
        return await withTaskGroup(of: AddonCandidate?.self) { g in
            for n in picked {
                g.addTask {
                    let md = try? String(contentsOf: URL(string: "https://raw.githubusercontent.com/anthropics/skills/main/skills/\(n)/SKILL.md")!, encoding: .utf8)
                    let desc = md.map { SkillStore.frontmatter($0)["description"] ?? "" } ?? ""
                    return AddonCandidate(id: n, kind: .skill, title: n, summary: desc, source: "Anthropic skills: \(n)",
                                          repository: "https://github.com/anthropics/skills/tree/main/skills/\(n)",
                                          skillPath: ("anthropics", "skills", "main", "skills/\(n)"))
                }
            }
            var out: [AddonCandidate] = []
            for await c in g { if let c { out.append(c) } }
            return out.sorted { $0.title < $1.title }
        }
    }

    /// A pasted link: an npm package, or a GitHub folder holding a skill (SKILL.md).
    static func fromLink(_ raw: String) async throws -> AddonCandidate {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"npmjs\.com/package/((@[^/\s]+/)?[^/\s?#]+)"#, options: .regularExpression) {
            let pkg = String(t[r]).replacingOccurrences(of: "npmjs.com/package/", with: "")
            return try await npm(pkg)
        }
        if t.hasPrefix("npm:") { return try await npm(String(t.dropFirst(4))) }
        if let r = t.range(of: #"github\.com/[^/\s]+/[^/\s]+(/tree/[^/\s]+(/[^\s?#]*)?)?"#, options: .regularExpression) {
            let parts = String(t[r]).split(separator: "/").map(String.init)      // github.com, owner, repo, tree, ref, path…
            let owner = parts[1], repo = parts[2].replacingOccurrences(of: ".git", with: "")
            let ref = parts.count > 4 ? parts[4] : "HEAD"
            let path = parts.count > 5 ? parts[5...].joined(separator: "/") : ""
            let md = try? String(contentsOf: URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(path.isEmpty ? "" : path + "/")SKILL.md")!, encoding: .utf8)
            if let md {
                let fm = SkillStore.frontmatter(md)
                let name = fm["name"] ?? (path.split(separator: "/").last.map(String.init) ?? repo)
                return AddonCandidate(id: AddonCandidate.slug(name), kind: .skill, title: name, summary: fm["description"] ?? "",
                                      source: "GitHub: \(owner)/\(repo)\(path.isEmpty ? "" : "/" + path)", repository: "https://github.com/\(owner)/\(repo)",
                                      skillPath: (owner, repo, ref, path))
            }
            // Not a skill: maybe the repo is published to npm under its package.json name.
            if let pj = try? await json("https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(path.isEmpty ? "" : path + "/")package.json") as? [String: Any],
               let name = pj["name"] as? String, (try? await json("https://registry.npmjs.org/\(name)/latest")) != nil {
                var c = try await npm(name)
                c.source = "GitHub \(owner)/\(repo), published on npm as \(name)"
                return c
            }
            throw InstallError.message("That GitHub folder has no SKILL.md and isn't published on npm, so 23 can't install it safely.")
        }
        if t.range(of: #"^(@[a-z0-9-~][a-z0-9-._~]*/)?[a-z0-9-~][a-z0-9-._~]*$"#, options: .regularExpression) != nil { return try await npm(t) }
        throw InstallError.message("Paste an npm package (npmjs.com/package/… or a package name) or a GitHub link to a skill folder.")
    }

    static func npm(_ pkg: String) async throws -> AddonCandidate {
        let enc = pkg.replacingOccurrences(of: "/", with: "%2F")
        guard let latest = try await json("https://registry.npmjs.org/\(enc)/latest") as? [String: Any] else { throw InstallError.message("npm has no package called \(pkg).") }
        guard latest["bin"] != nil else { throw InstallError.message("\(pkg) isn't a program 23 can run (it has no command).") }
        let repo = (latest["repository"] as? [String: Any])?["url"] as? String ?? latest["repository"] as? String
        return AddonCandidate(id: AddonCandidate.slug(pkg), kind: .npmServer, title: pkg, summary: latest["description"] as? String ?? "",
                              source: "npm: \(pkg)", npmPackage: pkg, version: latest["version"] as? String, repository: repo)
    }
}

// MARK: - Downloading, reviewing, installing

@MainActor
enum AddonInstaller {
    static let staging = AddonStore.root.appendingPathComponent(".staging")

    /// Downloads into a staging folder without running anything from it (npm install scripts are switched off).
    static func download(_ c: AddonCandidate) async throws -> URL {
        let dir = staging.appendingPathComponent("\(c.id)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch c.kind {
        case .npmServer:
            guard let pkg = c.npmPackage, let npm = CodeTools.which("npm") else { throw InstallError.message("npm isn't available on this Mac.") }
            let spec = c.version.map { "\(pkg)@\($0)" } ?? pkg
            let out = try await sandboxed(npm, ["install", "--prefix", dir.path, "--ignore-scripts", "--no-audit", "--no-fund", "--omit=dev", spec], writeRoot: dir)
            guard FileManager.default.fileExists(atPath: packageDir(dir, pkg).path) else { throw InstallError.message("npm couldn't download it: \(out.suffix(300))") }
        case .skill:
            guard let p = c.skillPath else { throw InstallError.message("No skill location.") }
            var count = 0, bytes = 0
            func fetch(_ path: String, into local: URL) async throws {
                let api = "https://api.github.com/repos/\(p.owner)/\(p.repo)/contents/\(path)?ref=\(p.ref)"
                var req = URLRequest(url: URL(string: api.replacingOccurrences(of: " ", with: "%20"))!)
                req.setValue("23-local-assistant", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                let items = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                for it in items {
                    let name = it["name"] as? String ?? ""
                    guard !name.hasPrefix("."), !name.contains("/") else { continue }
                    if it["type"] as? String == "dir" { try await fetch(path + "/" + name, into: local.appendingPathComponent(name)); continue }
                    count += 1; bytes += it["size"] as? Int ?? 0
                    guard count <= 80, bytes <= 10_000_000 else { throw InstallError.message("That skill is unusually large (over 80 files or 10 MB), so 23 won't install it.") }
                    guard let raw = it["download_url"] as? String, let u = URL(string: raw) else { continue }
                    let (d, _) = try await URLSession.shared.data(from: u)
                    try d.write(to: local.appendingPathComponent(name))
                }
            }
            try await fetch(p.path, into: dir.appendingPathComponent("skill"))
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("skill/SKILL.md").path) else { throw InstallError.message("No SKILL.md came down with it.") }
        }
        return dir
    }

    static func packageDir(_ staging: URL, _ pkg: String) -> URL { staging.appendingPathComponent("node_modules").appendingPathComponent(pkg) }

    /// Claude reads the downloaded code (read-only tools, only inside that folder) and reports what it does and any red flags.
    static func review(_ c: AddonCandidate, at dir: URL) async throws -> AddonReview {
        guard let claude = CodeTools.which("claude") else { throw InstallError.message("Claude Code isn't installed, so the code can't be reviewed.") }
        let codeDir: URL
        var context = ""
        switch c.kind {
        case .npmServer:
            codeDir = packageDir(dir, c.npmPackage ?? "")
            if let pj = try? JSONSerialization.jsonObject(with: Data(contentsOf: codeDir.appendingPathComponent("package.json"))) as? [String: Any] {
                let deps = (pj["dependencies"] as? [String: Any] ?? [:]).keys.sorted()
                context = "It is the npm package \(c.npmPackage ?? "") \(c.version ?? ""). Its dependencies (not in this folder): \(deps.prefix(60).joined(separator: ", "))."
            }
            if !c.env.isEmpty { context += " It asks for these settings: " + c.env.map { "\($0.name)\($0.secret ? " (secret)" : "")" }.joined(separator: ", ") + "." }
        case .skill:
            codeDir = dir.appendingPathComponent("skill")
            context = "It is a skill: a SKILL.md of instructions an assistant follows, possibly with scripts the assistant may run."
        }
        let ask = """
        You are reviewing an add-on before a person installs it into their local AI assistant ("23") on their Mac. The add-on's files are in the \
        current folder. \(context)
        23 will run it in a macOS sandbox: no access to iCloud, the keychain or SSH keys; it can only write in its own folder, temp and caches. \
        Read the code (start with the entry point, then anything that runs commands, opens network connections, reads files, or is obfuscated). \
        Look for: data sent to unexpected servers, reading credentials or personal files, running shell commands, downloading and running more code, \
        obfuscated or minified-only code, persistence (login items, cron), and anything unrelated to its stated purpose (\(c.summary.prefix(200))).
        Answer with ONLY a JSON object, no other text:
        {"risk": "low" | "medium" | "high", "what_it_does": "two plain sentences", "needs_internet": true/false, \
        "touches": "the files, apps, accounts or services it reaches", "red_flags": ["…"], "verdict": "one plain sentence of advice"}
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.currentDirectoryURL = codeDir
        p.arguments = ["-p", ask, "--output-format", "json", "--tools", "Read,Grep,Glob", "--strict-mcp-config", "--no-session-persistence"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CodeTools.userPath
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
        try p.run()
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timer)
        let data: Data = await withCheckedContinuation { cont in
            DispatchQueue.global().async { let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); cont.resume(returning: d) }
        }
        timer.cancel()
        guard let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let result = wrapper["result"] as? String else {
            throw InstallError.message(p.terminationReason == .uncaughtSignal ? "The review took too long." : "Claude couldn't review it.")
        }
        // The answer should be bare JSON; take the outermost object if there's anything around it.
        guard let a = result.firstIndex(of: "{"), let b = result.lastIndex(of: "}"),
              let review = try? JSONDecoder().decode(AddonReview.self, from: Data(result[a...b].utf8)) else {
            throw InstallError.message("Claude's review couldn't be read: \(result.prefix(200))")
        }
        ActivityLog.add("add-on reviewed", "\(c.source): risk \(review.risk)")
        return review
    }

    /// After the user approves: move it into place and register it (servers start switched on and sandboxed).
    static func install(_ c: AddonCandidate, from dir: URL, review: AddonReview, network: Bool, readOnlyFree: Bool, values: [String: String]) throws {
        switch c.kind {
        case .skill:
            let dest = SkillStore.root.appendingPathComponent(c.id)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.trashItem(at: dest, resultingItemURL: nil) }
            try FileManager.default.createDirectory(at: SkillStore.root, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: dir.appendingPathComponent("skill"), to: dest)
            try? FileManager.default.removeItem(at: dir)
            SkillStore.shared.reload()
            ActivityLog.add("skill installed", "\(c.title) (\(c.source)); review: \(review.risk)")
        case .npmServer:
            guard let pkg = c.npmPackage else { return }
            let home = AddonStore.root.appendingPathComponent(c.id)
            if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.trashItem(at: home, resultingItemURL: nil) }
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let pkgHome = home.appendingPathComponent("package")
            try FileManager.default.moveItem(at: dir, to: pkgHome)
            // Its command, from package.json "bin".
            let pj = try JSONSerialization.jsonObject(with: Data(contentsOf: packageDir(pkgHome, pkg).appendingPathComponent("package.json"))) as? [String: Any] ?? [:]
            var bin: String?
            if let s = pj["bin"] as? String { bin = s }
            if let d = pj["bin"] as? [String: String] { bin = d[pkg.split(separator: "/").last.map(String.init) ?? pkg] ?? d.values.sorted().first }
            guard let rel = bin else { throw InstallError.message("Couldn't find its command.") }
            let script = packageDir(pkgHome, pkg).appendingPathComponent(rel).standardizedFileURL
            guard let node = CodeTools.which("node") else { throw InstallError.message("Node isn't available.") }
            var env: [String: String] = [:]
            for v in c.env {
                guard let value = values[v.name], !value.isEmpty else { continue }
                if v.secret { Keychain.set(value, for: "\(c.id).\(v.name)"); env[v.name] = "keychain:" + v.name } else { env[v.name] = value }
            }
            let server = AddonServer(id: c.id, name: c.title, summary: c.summary.isEmpty ? c.title : String(c.summary.prefix(200)),
                                     command: node, args: [script.path] + c.args, env: env, network: network,
                                     policy: readOnlyFree ? .readOnlyFree : .askAll, source: c.source + (c.version.map { " \($0)" } ?? ""),
                                     review: "\(review.risk) risk: \(review.verdict)")
            AddonStore.shared.add(server)
        }
    }

    static func discard(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// Runs a command in the sandbox (network on: it downloads), writing only in `writeRoot`, temp and caches.
    static func sandboxed(_ exe: String, _ args: [String], writeRoot: URL) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", PathPolicy.sandboxProfile(writeRoot: writeRoot.path, internet: true, allowSecrets: false, allowAppControl: false), exe] + args
        p.currentDirectoryURL = writeRoot
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CodeTools.userPath
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        try p.run()
        let data: Data = await withCheckedContinuation { c in
            DispatchQueue.global().async { let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); c.resume(returning: d) }
        }
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw InstallError.message("The download failed: \(text.suffix(300))") }
        return text
    }
}

// MARK: - Secrets for add-ons (API keys) live in the login keychain, not in a file

enum Keychain {
    static let service = "23 add-ons"
    static func set(_ value: String, for account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Skills

/// Skills: folders with a SKILL.md of instructions (and maybe scripts). 23 lists them in its instructions and reads one when it's relevant.
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()
    static let root = Voice.support.appendingPathComponent("skills")

    struct Skill: Identifiable { let id: String; let name: String; let description: String; let folder: URL; var enabled: Bool }
    @Published private(set) var skills: [Skill] = []

    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "disabledSkills") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "disabledSkills") }
    }

    private init() { reload() }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        let off = disabled
        skills = dirs.compactMap { d in
            guard let md = try? String(contentsOf: d.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
            let fm = Self.frontmatter(md)
            return Skill(id: d.lastPathComponent, name: fm["name"] ?? d.lastPathComponent, description: fm["description"] ?? "", folder: d, enabled: !off.contains(d.lastPathComponent))
        }.sorted { $0.name < $1.name }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var off = disabled; if on { off.remove(id) } else { off.insert(id) }; disabled = off
        reload()
        ActivityLog.add("setting", "skill \(id) → \(on ? "on" : "off")")
    }

    func remove(_ id: String) {
        try? FileManager.default.trashItem(at: Self.root.appendingPathComponent(id), resultingItemURL: nil)
        reload()
        ActivityLog.add("skill removed", id)
    }

    var enabled: [Skill] { skills.filter(\.enabled) }

    /// The name: and description: lines of a SKILL.md's header.
    nonisolated static func frontmatter(_ md: String) -> [String: String] {
        guard md.hasPrefix("---") else { return [:] }
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        var out: [String: String] = [:]
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let c = l.firstIndex(of: ":") else { continue }
            let k = l[..<c].trimmingCharacters(in: .whitespaces)
            var v = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            out[k] = v
        }
        return out
    }
}
