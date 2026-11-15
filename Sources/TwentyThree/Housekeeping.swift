import Foundation
import AppKit

// MARK: - Old chats go to the Bin (after a heads-up)

/// Chats not opened for a while go to the Bin, but only after the user was told a week before.
/// Pinned chats and chats that are working or waiting are never touched. Agent runs: each agent keeps its newest few.
@MainActor
final class Retention: ObservableObject {
    static let shared = Retention()

    /// Days without being opened before a chat goes to the Bin (0 = never). Default 30, the user's choice.
    static var days: Int {
        get { UserDefaults.standard.object(forKey: "retentionDays") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "retentionDays"); Task { @MainActor in Retention.shared.check() } }
    }
    /// Runs each agent keeps (0 = all). Default 20.
    static var agentRunsKept: Int {
        get { UserDefaults.standard.object(forKey: "agentRunsKept") as? Int ?? 20 }
        set { UserDefaults.standard.set(newValue, forKey: "agentRunsKept"); Task { @MainActor in Retention.shared.check() } }
    }
    static let headsUpDays = 7

    struct Upcoming: Identifiable { let id: UUID; let title: String; let binOn: Date }
    /// Chats that go to the Bin soon (the user was told; they can keep them).
    @Published private(set) var upcoming: [Upcoming] = []

    /// When each chat was first announced as going to the Bin.
    private var announced: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: "retentionAnnounced") as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "retentionAnnounced") }
    }

    private var timer: Timer?
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in Task { @MainActor in Retention.shared.check() } }
    }

    private func protected(_ s: ConversationStore.Summary, _ store: ConversationStore) -> Bool {
        if s.pinned || s.id == store.currentID { return true }
        if AgentRunner.shared.active[s.id] != nil { return true }
        if let c = store.openChat(s.id), c.isBusy || c.isPaused { return true }
        return false
    }

    func check(now: Date = Date()) {
        let store = ConversationStore.shared
        var told = announced
        var newlyTold: [ConversationStore.Summary] = []
        var binned = 0

        // 1. Ordinary chats (and runs of agents that no longer exist).
        let days = Self.days
        if days > 0 {
            let warnAfter = now.addingTimeInterval(-Double(days - Self.headsUpDays) * 86_400)
            for s in store.summaries where (s.agentID == nil || AgentStore.shared.agent(s.agentID!) == nil) && !protected(s, store) {
                let key = s.id.uuidString
                guard s.lastTouched < warnAfter else { told[key] = nil; continue }          // opened recently: not due
                if let when = told[key] {
                    // Binned once it is old enough AND the heads-up was at least a week ago.
                    let oldEnough = s.lastTouched < now.addingTimeInterval(-Double(days) * 86_400)
                    if oldEnough && when < now.addingTimeInterval(-Double(Self.headsUpDays) * 86_400) {
                        store.delete(s.id); told[key] = nil; binned += 1
                        ActivityLog.add("auto-bin chat", "“\(s.title)” (not opened for \(days)+ days)")
                    }
                } else {
                    told[key] = now; newlyTold.append(s)
                }
            }
        } else {
            told = [:]
        }

        // 2. Agent runs: each agent keeps its newest runs.
        let keep = Self.agentRunsKept
        if keep > 0 {
            for agent in AgentStore.shared.agents {
                let runs = store.summaries.filter { $0.agentID == agent.id }.sorted { $0.updated > $1.updated }
                for s in runs.dropFirst(keep) where !protected(s, store) {
                    store.delete(s.id); binned += 1
                    ActivityLog.add("auto-bin run", "“\(s.title)” (\(agent.name) keeps its newest \(keep))")
                }
            }
        }

        // Forget announcements for chats that are gone.
        let ids = Set(store.summaries.map { $0.id.uuidString })
        told = told.filter { ids.contains($0.key) }
        announced = told
        upcoming = store.summaries.compactMap { s in
            guard let when = told[s.id.uuidString] else { return nil }
            let byAge = s.lastTouched.addingTimeInterval(Double(days) * 86_400)
            return Upcoming(id: s.id, title: s.title, binOn: max(byAge, when.addingTimeInterval(Double(Self.headsUpDays) * 86_400)))
        }.sorted { $0.binOn < $1.binOn }

        if !newlyTold.isEmpty {
            let n = newlyTold.count
            AgentRunner.shared.notify(title: "\(n) old chat\(n == 1 ? "" : "s") will go to the Bin next week",
                                      body: "Not opened for \(days - Self.headsUpDays)+ days. Open 23 › Settings › Storage to keep any of them.",
                                      chat: nil, storage: true)
            ActivityLog.add("auto-bin heads-up", newlyTold.map { "“\($0.title)”" }.joined(separator: ", "))
        }
        if binned > 0 { Visualizer.shared.log("retention: binned \(binned) chat(s)") }
    }

    /// The user wants to keep it: counts as opened now, so the clock starts again.
    func keep(_ id: UUID) {
        ConversationStore.shared.touch(id)
        var told = announced; told[id.uuidString] = nil; announced = told
        upcoming.removeAll { $0.id == id }
        ActivityLog.add("keep chat", id.uuidString)
    }
}

// MARK: - Space used, and bulk clean-up

@MainActor
enum Storage {
    struct Item: Identifiable { let id: String; let title: String; let detail: String; let bytes: Int64; let folder: URL? }

    nonisolated static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: [], errorHandler: nil) else {
            return (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(Int64.init) ?? 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Int64(v.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func measure() async -> [Item] {
        let sup = Voice.support
        let chats = ConversationStore.folder
        let count = ConversationStore.shared.summaries.count
        let places: [(String, String, String, URL)] = [
            ("chats", "Chats", "\(count) chat\(count == 1 ? "" : "s")", chats),
            ("attachments", "Attachments", "23's copies of files you attached", AttachmentStore.root),
            ("snapshots", "Edit backups", "copies kept so code edits can be undone", sup.appendingPathComponent("snapshots")),
            ("logs", "Logs", "what 23 did, and technical notes", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")),
            ("voice", "Voice", "speech models (whisper and Kokoro)", sup.appendingPathComponent("models")),
            ("ai", "AI models", "Ollama's models (manage them in Settings › Model)", URL(fileURLWithPath: ProcessInfo.processInfo.environment["OLLAMA_MODELS"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models.noindex").path)),
        ]
        return await Task.detached {
            places.map { p in
                let bytes: Int64
                if p.0 == "logs" {
                    bytes = ["23.log", "23-activity.log"].reduce(0) { $0 + ((try? p.3.appendingPathComponent($1).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(Int64.init) ?? 0) }
                } else { bytes = size(of: p.3) }
                return Item(id: p.0, title: p.1, detail: p.2, bytes: bytes, folder: p.3)
            }
        }.value
    }

    /// Chats not opened for `days` (pinned ones and the open one excluded).
    static func chats(olderThan days: Int, agentRunsOnly: Bool = false) -> [ConversationStore.Summary] {
        let store = ConversationStore.shared
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return store.summaries.filter { s in
            !s.pinned && s.id != store.currentID && AgentRunner.shared.active[s.id] == nil && s.lastTouched < cutoff
                && (!agentRunsOnly || s.agentID != nil)
        }
    }

    static func bin(_ chats: [ConversationStore.Summary]) {
        for s in chats { ConversationStore.shared.delete(s.id) }
        ActivityLog.add("bin chats (you)", "\(chats.count) chat(s)")
    }

    /// Edit backups older than `days` go to the Bin (those edits can then no longer be undone).
    static func binSnapshots(olderThan days: Int) -> Int {
        let dir = Voice.support.appendingPathComponent("snapshots")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var n = 0
        for f in items where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < cutoff {
            if (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) != nil { n += 1 }
        }
        ActivityLog.add("bin edit backups (you)", "\(n) older than \(days) days")
        return n
    }

    /// Attachment copies no chat refers to any more (e.g. taken off before sending).
    static func binUnusedAttachments() -> Int {
        let store = ConversationStore.shared
        var used = Set<String>()
        for s in store.summaries {
            if let f = store.file(s.id) { for a in f.messages.flatMap({ $0.attachments ?? [] }) { used.insert(a.storedURL.deletingLastPathComponent().lastPathComponent) } }
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: AttachmentStore.root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var n = 0
        for d in dirs where !used.contains(d.lastPathComponent) {
            // Leave anything from the last hour alone: it may be waiting in the message field.
            if let m = try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(m) < 3600 { continue }
            if (try? FileManager.default.trashItem(at: d, resultingItemURL: nil)) != nil { n += 1 }
        }
        ActivityLog.add("bin unused attachments (you)", "\(n)")
        return n
    }

    /// Keeps the newest part of the logs (about the last 2 MB each).
    static func trimLogs() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        for name in ["23.log", "23-activity.log"] {
            let f = dir.appendingPathComponent(name)
            guard let d = try? Data(contentsOf: f), d.count > 2_000_000 else { continue }
            var tail = d.suffix(2_000_000)
            if let nl = tail.firstIndex(of: 0x0A) { tail = tail[(nl + 1)...] }
            try? Data(tail).write(to: f, options: .atomic)
        }
        ActivityLog.add("trim logs (you)", "kept the newest ~2 MB of each")
    }
}

// MARK: - Tidying long-term memory

@MainActor
enum MemoryTidy {
    struct Suggestion: Identifiable, Hashable { var id: String { fact }; let fact: String; let reason: String }

    /// Near-identical facts found by their words (a small model often misses these): the shorter or older copy is suggested.
    static func duplicates(_ facts: [String]) -> [Suggestion] {
        let filler: Set<String> = ["i", "me", "my", "the", "a", "an", "to", "for", "of", "in", "on", "and", "is", "are", "user", "user's", "everything", "always", "really", "very"]
        func words(_ f: String) -> Set<String> {
            Set(f.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map { w -> String in
                var w = String(w); if w.count > 3, w.hasSuffix("s") { w.removeLast() }; return w     // prefers → prefer
            }.filter { !filler.contains($0) })
        }
        var out: [Suggestion] = []
        for i in facts.indices {
            for j in facts.indices where j > i {
                let a = words(facts[i]), b = words(facts[j])
                guard min(a.count, b.count) >= 2 else { continue }
                let shared = Double(a.intersection(b).count) / Double(min(a.count, b.count))
                guard shared >= 0.8 else { continue }
                // Keep the fuller one (or the newer, if they're as full): suggest the other.
                let drop = facts[i].count < facts[j].count ? i : j
                let keep = drop == i ? j : i
                if !out.contains(where: { $0.fact == facts[drop] }) { out.append(Suggestion(fact: facts[drop], reason: "Same as “\(facts[keep])”")) }
            }
        }
        return out
    }

    /// Asks the local model which remembered facts look duplicated, contradicted by a newer one, or no longer true.
    /// Nothing is removed here: the user picks from the suggestions.
    static func suggest() async throws -> [Suggestion] {
        let entries = Memory.entries
        guard entries.count >= 2 else { return [] }
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        let list = entries.enumerated().map { i, e in "\(i + 1). \(e.fact)\(e.meta.map { " (saved \(f.string(from: $0.added)))" } ?? "")" }.joined(separator: "\n")
        let ask = """
        Today is \(f.string(from: Date())). These are facts an assistant remembers about its user, used in every chat:
        \(list)

        Which ones should be removed? Only suggest a fact if it is clearly: a duplicate of another one (suggest the older or vaguer copy), \
        contradicted by a newer fact, about something temporary that is likely over (a date that has passed, a one-off task), or not about the user at all. \
        When unsure, keep it. Answer with JSON only: {"remove": [{"number": 3, "reason": "short reason"}]}. An empty list is fine.
        """
        var req = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Prefs.model, "stream": false, "think": false, "format": "json", "keep_alive": -1,
            "options": ["num_ctx": FitCheck.context, "temperature": 0.2],
            "messages": [["role": "user", "content": ask]]] as [String: Any])
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let e = obj?["error"] as? String { throw NSError(domain: "23", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
        let content = (obj?["message"] as? [String: Any])?["content"] as? String ?? "{}"
        let parsed = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any]
        var out = duplicates(entries.map(\.fact))
        for r in parsed?["remove"] as? [[String: Any]] ?? [] {
            guard let n = (r["number"] as? Int) ?? (r["number"] as? String).flatMap(Int.init), n >= 1, n <= entries.count else { continue }
            let fact = entries[n - 1].fact
            if !out.contains(where: { $0.fact == fact }) { out.append(Suggestion(fact: fact, reason: (r["reason"] as? String) ?? "")) }
        }
        return out
    }
}
