import Foundation
import SwiftUI

/// All of 23's conversations: one JSON file each in ~/Library/Application Support/23/conversations.
@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    struct Summary: Identifiable, Equatable {
        let id: UUID
        var title: String
        var updated: Date
        var pinned: Bool
        var agentID: UUID? = nil
        var opened: Date? = nil
        /// Old chats are judged by the later of: last change, last opened.
        var lastTouched: Date { max(updated, opened ?? updated) }
    }

    enum Page: Equatable { case chat, settings, agents }

    @Published private(set) var summaries: [Summary] = []
    @Published var currentID: UUID
    @Published var page: Page = .chat
    @Published var showInspector = false
    @Published var settingsSection: SettingsSection = .general
    /// The agent open on the Agents page (nil: the list).
    @Published var agentSelection: UUID?

    private var open: [UUID: ChatModel] = [:]
    static let folder: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/23/conversations")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private init() {
        let fresh = ChatModel()
        currentID = fresh.id
        open[fresh.id] = fresh
        attach(fresh)
        loadSummaries()
    }

    // MARK: Reading

    private struct Header: Decodable { let id: UUID; let title: String; let updated: Date; let pinned: Bool; let agentID: UUID?; let opened: Date? }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    private func url(_ id: UUID) -> URL { Self.folder.appendingPathComponent("\(id.uuidString).json") }

    func loadSummaries() {
        if Remote.active { refreshRemote(); return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        summaries = files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let data = try? Data(contentsOf: f), let h = try? Self.decoder.decode(Header.self, from: data) else { return nil }
            return Summary(id: h.id, title: h.title, updated: h.updated, pinned: h.pinned, agentID: h.agentID, opened: h.opened)
        }.sorted { $0.updated > $1.updated }
    }

    /// The chat on screen.
    var current: ChatModel { chat(currentID) ?? newChat() }

    /// The chat the orb follows: the one working, otherwise the one on screen.
    var orbChat: ChatModel { (ChatModel.running?.isBusy == true ? ChatModel.running : nil) ?? current }

    func chat(_ id: UUID) -> ChatModel? {
        if let c = open[id] { return c }
        if Remote.active {
            // A chat on the other Mac: shown from what it sends.
            guard let s = summaries.first(where: { $0.id == id }) else { return nil }
            let c = ChatModel(id: id, title: s.title, created: s.updated)
            open[id] = c
            attach(c)
            c.followRemote()
            return c
        }
        guard let data = try? Data(contentsOf: url(id)), let f = try? Self.decoder.decode(ChatModel.File.self, from: data) else { return nil }
        let c = ChatModel(file: f)
        open[id] = c
        attach(c)
        return c
    }

    private func attach(_ c: ChatModel) {
        c.persist = { [weak self, weak c] in
            guard let self, let c else { return }
            self.save(c)
        }
    }

    // MARK: Changing

    func save(_ c: ChatModel) {
        guard !c.messages.isEmpty else { return }          // empty chats aren't kept
        guard !Remote.active else { return }               // the other Mac keeps them
        if let data = try? Self.encoder.encode(c.file) { try? data.write(to: url(c.id), options: .atomic) }
        let s = Summary(id: c.id, title: c.title, updated: c.updated, pinned: c.pinned, agentID: c.agentID, opened: c.opened)
        if let i = summaries.firstIndex(where: { $0.id == c.id }) { summaries[i] = s } else { summaries.insert(s, at: 0) }
        summaries.sort { $0.updated > $1.updated }
    }

    @discardableResult
    func newChat() -> ChatModel {
        page = .chat
        // Re-use the chat on screen if nothing has been said in it yet.
        if let c = open[currentID], c.messages.isEmpty { return c }
        let c = ChatModel()
        open[c.id] = c
        attach(c)
        currentID = c.id
        return c
    }

    // MARK: Remote

    /// Server side: a chat a remote started (kept and listed, but not put on this Mac's screen).
    func remoteChat(_ id: UUID) -> ChatModel {
        let c = ChatModel(id: id)
        open[id] = c
        attach(c)
        return c
    }

    private var remoteTimer: Timer?
    /// Remote side: the chat list from the other Mac, refreshed every few seconds.
    func refreshRemote() {
        if remoteTimer == nil {
            remoteTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in ConversationStore.shared.refreshRemote() } }
        }
        Task {
            guard let list = try? await RemoteClient.summaries() else { return }
            let fresh = list.map { Summary(id: $0.id, title: $0.title, updated: $0.updated, pinned: $0.pinned) }
            // Keep a chat started here that the other Mac doesn't list yet.
            let local = summaries.filter { s in !fresh.contains { $0.id == s.id } && open[s.id]?.messages.isEmpty == false }
            let merged = (fresh + local).sorted { $0.updated > $1.updated }
            if merged != summaries { summaries = merged }
        }
    }

    /// Remote side: a chat just sent its first message, so it belongs in the list now.
    func remoteSent(_ c: ChatModel) {
        let s = Summary(id: c.id, title: c.title, updated: Date(), pinned: c.pinned)
        if let i = summaries.firstIndex(where: { $0.id == c.id }) { summaries[i] = s } else { summaries.insert(s, at: 0) }
    }

    /// A chat for an agent run by itself: saved and listed, but not put on screen (it shouldn't take over what the user is doing).
    func newRunChat(for agent: Agent) -> ChatModel {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm"
        let c = ChatModel(title: "\(agent.name) · \(f.string(from: Date()))")
        c.agentID = agent.id
        open[c.id] = c
        attach(c)
        return c
    }

    /// Starts a chat with an agent, on screen.
    func newChat(with agent: Agent) {
        let c = newChat()
        c.agentID = agent.id
        c.title = "New chat"
        page = .chat
    }

    /// A chat only if it is already loaded (doesn't read files).
    func openChat(_ id: UUID) -> ChatModel? { open[id] }

    /// A chat's saved file, read without opening the chat.
    func file(_ id: UUID) -> ChatModel.File? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? Self.decoder.decode(ChatModel.File.self, from: data)
    }

    /// Marks a chat as opened now (so it isn't old any more).
    func touch(_ id: UUID) {
        guard let c = chat(id) else { return }
        c.opened = Date()
        save(c)
    }

    func select(_ id: UUID) {
        guard let picked = chat(id) else { return }
        if Remote.active { picked.followRemote(); Task { try? await RemoteClient.post(id, "opened") } }
        else if !picked.messages.isEmpty { picked.opened = Date(); save(picked) }
        // Drop an untouched empty chat when leaving it.
        if id != currentID, let old = open[currentID], old.messages.isEmpty, !old.isBusy { open[currentID] = nil }
        currentID = id
        page = .chat
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let c = chat(id) else { return }
        if Remote.active { c.title = t; Task { try? await RemoteClient.post(id, "rename", ["title": t]); refreshRemote() }; return }
        c.title = String(t.prefix(80))
        save(c)
    }

    func togglePin(_ id: UUID) {
        guard let c = chat(id) else { return }
        if Remote.active { c.pinned.toggle(); Task { try? await RemoteClient.post(id, "pin"); refreshRemote() }; return }
        c.pinned.toggle()
        save(c)
    }

    /// Deleted chats go to the Trash (so a mistake can be undone from Finder).
    func delete(_ id: UUID) {
        if Remote.active {
            open[id] = nil
            summaries.removeAll { $0.id == id }
            Task { try? await RemoteClient.post(id, "delete"); refreshRemote() }
            if currentID == id { if let next = summaries.first { select(next.id) } else { let c = ChatModel(); open[c.id] = c; attach(c); currentID = c.id } }
            return
        }
        if let c = open[id] { if c.isBusy { c.stop() }; open[id] = nil }
        // Its attachments go to the Bin with it (23's copies only; the user's originals are never touched).
        if let data = try? Data(contentsOf: url(id)), let file = try? Self.decoder.decode(ChatModel.File.self, from: data) {
            for a in file.messages.flatMap({ $0.attachments ?? [] }) {
                let dir = a.storedURL.deletingLastPathComponent()
                if dir.deletingLastPathComponent().standardizedFileURL.path == AttachmentStore.root.standardizedFileURL.path {
                    try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                }
            }
        }
        try? FileManager.default.trashItem(at: url(id), resultingItemURL: nil)
        summaries.removeAll { $0.id == id }
        ActivityLog.add("delete chat", id.uuidString)
        if currentID == id {
            if let next = summaries.first { select(next.id) } else { let c = ChatModel(); open[c.id] = c; attach(c); currentID = c.id }
        }
    }

    // MARK: Sidebar groups

    func groups(matching query: String) -> [(String, [Summary])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? summaries : summaries.filter { $0.title.lowercased().contains(q) }
        let cal = Calendar.current
        var pinned: [Summary] = [], today: [Summary] = [], yesterday: [Summary] = [], week: [Summary] = [], older: [Summary] = []
        for s in list {
            if s.pinned { pinned.append(s) }
            else if cal.isDateInToday(s.updated) { today.append(s) }
            else if cal.isDateInYesterday(s.updated) { yesterday.append(s) }
            else if s.updated > Date().addingTimeInterval(-7 * 86_400) { week.append(s) }
            else { older.append(s) }
        }
        return [("Pinned", pinned), ("Today", today), ("Yesterday", yesterday), ("Previous 7 days", week), ("Older", older)]
            .filter { !$0.1.isEmpty }
    }
}
