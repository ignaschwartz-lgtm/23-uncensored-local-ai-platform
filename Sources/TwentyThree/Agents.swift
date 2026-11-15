import Foundation
import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

// MARK: - What an agent is

/// A saved assistant: its own instructions, model, folder and abilities, and optionally a schedule or a folder to watch.
/// Its abilities can only narrow what Settings allows for all of 23, never widen it.
struct Agent: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New agent"
    var symbol = "sparkles"
    var instructions = ""               // how it works, in the user's words
    var task = ""                       // what to do when it runs by itself
    var model: String? = nil            // nil: the model in use
    var folder: String? = nil           // nil: the 23 workspace
    var abilities = Abilities()
    var schedule: Schedule? = nil
    var watchFolder: String? = nil
    var enabled = true                  // schedule and folder watching on
    var lastRun: Date? = nil
    var created = Date()

    struct Abilities: Codable, Equatable {
        var files = true
        var web = false                 // off for a new agent: turned on deliberately
        var webTyping = false
        var downloads = false
        var code = true
        var commands = false
        var memory = true
        var addons: Bool? = nil         // add-on tools (REA…); off unless turned on (nil in agents saved before add-ons)
    }

    struct Schedule: Codable, Equatable {
        enum Kind: String, Codable, CaseIterable { case daily, interval }
        var kind: Kind = .daily
        var hour = 8
        var minute = 0
        var weekdays: Set<Int> = Set(1...7)     // Calendar weekdays: 1 = Sunday … 7 = Saturday
        var everyMinutes = 60

        /// The first time this schedule fires after `date`.
        func next(after date: Date) -> Date? {
            let cal = Calendar.current
            switch kind {
            case .interval:
                return date.addingTimeInterval(Double(max(15, everyMinutes)) * 60)
            case .daily:
                guard !weekdays.isEmpty else { return nil }
                var day = cal.startOfDay(for: date)
                for _ in 0..<8 {
                    if weekdays.contains(cal.component(.weekday, from: day)),
                       let t = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day), t > date { return t }
                    day = cal.date(byAdding: .day, value: 1, to: day)!
                }
                return nil
            }
        }

        var summary: String {
            switch kind {
            case .interval:
                return everyMinutes % 60 == 0 ? "Every \(everyMinutes / 60 == 1 ? "hour" : "\(everyMinutes / 60) hours")" : "Every \(everyMinutes) minutes"
            case .daily:
                let time = String(format: "%d:%02d", hour, minute)
                let days: String
                if weekdays.count == 7 { days = "Every day" }
                else if weekdays == Set(2...6) { days = "Weekdays" }
                else if weekdays == [1, 7] { days = "Weekends" }
                else { days = weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ") }
                return "\(days) at \(time)"
            }
        }
    }

    var runsByItself: Bool { enabled && (schedule != nil || watchFolder != nil) && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var nextRun: Date? { guard enabled, let s = schedule else { return nil }; return s.next(after: lastRun ?? created) }

    /// May this agent use this tool? (Settings must allow it too; this only narrows.)
    @MainActor func allows(_ tool: String) -> Bool {
        let a = abilities
        if FileTools.names.contains(tool) { return a.files }
        if MemoryTools.names.contains(tool) { return a.memory }
        if BrowserTools.names.contains(tool) {
            guard a.web else { return false }
            if tool == "type_text" { return a.webTyping }
            if tool == "download_file" { return a.downloads }
            return true
        }
        if AddonTools.names.contains(tool) { return a.addons == true }
        if CodeTools.names.contains(tool) {
            guard a.code else { return false }
            if tool == "run_command" { return a.commands }
            if tool == "hand_off_to_claude" { return false }     // an agent never hands work to Claude
            return true
        }
        return false
    }

    var offSummary: String {
        var off: [String] = []
        let a = abilities
        if !a.files { off.append("file actions") }
        if !a.web { off.append("web browsing") } else {
            if !a.webTyping { off.append("typing into web pages") }
            if !a.downloads { off.append("downloads") }
        }
        if !a.code { off.append("code tools") } else if !a.commands { off.append("running commands") }
        if !a.memory { off.append("saving memories") }
        if a.addons != true { off.append("add-on tools") }
        return off.joined(separator: ", ")
    }

    static let symbols = ["sparkles", "folder", "doc.text", "envelope", "globe", "chevron.left.forwardslash.chevron.right",
                          "chart.bar", "calendar", "checklist", "magnifyingglass", "tray.and.arrow.down", "newspaper",
                          "paintbrush", "music.note", "cart", "house", "briefcase", "book"]
}

// MARK: - Keeping agents

@MainActor
final class AgentStore: ObservableObject {
    static let shared = AgentStore()
    @Published private(set) var agents: [Agent] = []
    /// Files already seen in each watched folder, so only new arrivals start a run.
    private var seen: [UUID: Set<String>] = [:]

    private static let url = Voice.support.appendingPathComponent("agents.json")
    private static let seenURL = Voice.support.appendingPathComponent("agents-seen.json")
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e }()

    private init() {
        if let d = try? Data(contentsOf: Self.url), let a = try? Self.decoder.decode([Agent].self, from: d) { agents = a }
        if let d = try? Data(contentsOf: Self.seenURL), let s = try? JSONDecoder().decode([UUID: Set<String>].self, from: d) { seen = s }
    }

    func agent(_ id: UUID) -> Agent? { agents.first { $0.id == id } }

    private func save() {
        if let d = try? Self.encoder.encode(agents) { try? d.write(to: Self.url, options: .atomic) }
        AgentRunner.shared.agentsChanged()
    }

    func add(_ a: Agent) { agents.append(a); save(); ActivityLog.add("agent created", a.name) }

    func update(_ a: Agent) {
        guard let i = agents.firstIndex(where: { $0.id == a.id }) else { return }
        let old = agents[i]
        agents[i] = a
        if old.watchFolder != a.watchFolder { seen[a.id] = nil; saveSeen() }      // a new folder starts fresh
        if old.abilities != a.abilities || old.schedule != a.schedule || old.watchFolder != a.watchFolder || old.enabled != a.enabled {
            ActivityLog.add("agent changed", "\(a.name): \(a.runsByItself ? (a.schedule?.summary ?? "watching a folder") : "runs only when asked"); off: \(a.offSummary.isEmpty ? "nothing" : a.offSummary)")
        }
        save()
    }

    func delete(_ id: UUID) {
        if let a = agent(id) { ActivityLog.add("agent deleted", a.name) }
        agents.removeAll { $0.id == id }
        seen[id] = nil; saveSeen()
        save()
    }

    func markRun(_ id: UUID, at date: Date) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[i].lastRun = date
        if let d = try? Self.encoder.encode(agents) { try? d.write(to: Self.url, options: .atomic) }
    }

    /// New files in an agent's watched folder since last time. The first look only learns what's there.
    func newFiles(for a: Agent) -> [URL] {
        guard let raw = a.watchFolder else { return [] }
        let dir = PathPolicy.resolve(raw)
        guard case .free = PathPolicy.check(dir, write: false) else { return [] }
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { !$0.lastPathComponent.hasSuffix(".download") && !$0.lastPathComponent.hasSuffix(".crdownload") && !$0.lastPathComponent.hasSuffix(".part") }
        let names = Set(items.map(\.lastPathComponent))
        guard let known = seen[a.id] else { seen[a.id] = names; saveSeen(); return [] }
        // Only files that have stopped changing for a few seconds (still-copying files wait for the next look).
        let settled = items.filter { u in
            !known.contains(u.lastPathComponent) &&
            ((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) > 5 } ?? true)
        }
        if !settled.isEmpty { seen[a.id] = known.union(settled.map(\.lastPathComponent)); saveSeen() }
        // Forget names that are gone, so a file put back counts as new again.
        if !known.subtracting(names).isEmpty { seen[a.id] = (seen[a.id] ?? []).intersection(names); saveSeen() }
        return settled
    }

    private func saveSeen() { if let d = try? JSONEncoder().encode(seen) { try? d.write(to: Self.seenURL, options: .atomic) } }
}

// MARK: - Running agents by themselves

@MainActor
final class AgentRunner: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AgentRunner()

    enum Reason: Equatable { case schedule, files([URL]), manual
        var text: String {
            switch self {
            case .schedule: return "its schedule"
            case .manual: return "you pressed Run now"
            case .files(let f): return "\(f.count) new file\(f.count == 1 ? "" : "s") in its folder"
            }
        }
    }
    struct Job: Equatable { let agentID: UUID; let reason: Reason }

    @Published private(set) var queue: [Job] = []
    /// Agent chats that ran by themselves and are still going (working or waiting for the user).
    @Published private(set) var active: [UUID: UUID] = [:]      // chat id → agent id
    @Published private(set) var keepingAwake = false
    @Published private(set) var loginItem: SMAppService.Status = .notRegistered

    /// Developer tests: no login item, no keeping awake, notifications only logged.
    var testMode = false
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    var openChat: (UUID) -> Void = { _ in }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        loginItem = SMAppService.mainApp.status
        agentsChanged()
        // Every 30 seconds: anything due, any new files, anything waiting for a free turn.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in Task { @MainActor in AgentRunner.shared.tick() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AgentRunner.shared.tick() }      // catch up on anything missed while asleep
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.tick() }   // and at launch
    }

    /// Something about the agents changed: keep the Mac awake and open at login only while an agent runs by itself.
    func agentsChanged() {
        guard !testMode, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let needed = AgentStore.shared.agents.contains { $0.runsByItself }
        setAwake(needed)
        if needed && SMAppService.mainApp.status == .notRegistered {
            do { try SMAppService.mainApp.register(); ActivityLog.add("setting", "open 23 at login → on (an agent runs by itself)") }
            catch { Visualizer.shared.log("login item: \(error.localizedDescription)") }
        }
        loginItem = SMAppService.mainApp.status
        if needed { requestNotifications() }
    }

    func setLoginItem(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { Visualizer.shared.log("login item: \(error.localizedDescription)") }
        loginItem = SMAppService.mainApp.status
        ActivityLog.add("setting", "open 23 at login → \(on ? "on" : "off")")
    }

    /// Stops idle sleep (the display may still sleep) while any agent runs by itself.
    private func setAwake(_ on: Bool) {
        guard on != keepingAwake else { return }
        if on {
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "23: an agent runs on a schedule or watches a folder" as CFString, &sleepAssertion)
            keepingAwake = r == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(sleepAssertion)
            keepingAwake = false
        }
    }

    func runNow(_ id: UUID) { enqueue(Job(agentID: id, reason: .manual)); tick() }

    private func enqueue(_ job: Job) {
        // One waiting run per agent is enough (a burst of new files becomes one run).
        if let i = queue.firstIndex(where: { $0.agentID == job.agentID }) {
            if case .files(let a) = queue[i].reason, case .files(let b) = job.reason { queue[i] = Job(agentID: job.agentID, reason: .files(a + b)) }
            return
        }
        guard !active.values.contains(job.agentID) else { return }      // already running: the next look picks up anything new
        queue.append(job)
    }

    func tick() {
        let store = AgentStore.shared
        let now = Date()
        for a in store.agents where a.runsByItself {
            // Due (including a time missed while the Mac was off or 23 was closed: it runs once, now).
            if let next = a.nextRun, next <= now { enqueue(Job(agentID: a.id, reason: .schedule)) }
            let files = store.newFiles(for: a)
            if !files.isEmpty { enqueue(Job(agentID: a.id, reason: .files(files))) }
        }
        // Finished runs: tell the user.
        for (chatID, agentID) in active {
            guard let c = ConversationStore.shared.chat(chatID), !c.isBusy else { continue }
            active[chatID] = nil
            let name = store.agent(agentID)?.name ?? "An agent"
            let answer = c.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text ?? c.statusLine
            notify(title: "\(name) finished", body: String(answer.prefix(180)), chat: chatID)
        }
        startNextIfFree()
    }

    /// Starts the next waiting run when no chat is working (a chat that is only waiting for the user's OK doesn't count).
    private func startNextIfFree() {
        guard !queue.isEmpty else { return }
        if let r = ChatModel.running, r.isBusy, !r.isPaused { return }
        let job = queue.removeFirst()
        guard let agent = AgentStore.shared.agent(job.agentID) else { return startNextIfFree() }
        if job.reason == .schedule || job.reason == .manual { AgentStore.shared.markRun(agent.id, at: Date()) }
        let chat = ConversationStore.shared.newRunChat(for: agent)
        chat.unattended = true
        var prompt = agent.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { prompt = "Do your usual task." }
        if case .files(let files) = job.reason {
            prompt += "\n\nNew in the folder you watch (\(FileTools.display(PathPolicy.resolve(agent.watchFolder ?? "")))):\n"
                + files.prefix(40).map { "- " + FileTools.display($0) }.joined(separator: "\n")
        }
        active[chat.id] = agent.id
        ActivityLog.add("agent run", "\(agent.name) (because of \(job.reason.text))")
        chat.send(prompt)
    }

    /// A run by itself reached something that needs the user: it waits, and they get a notification.
    func needsApproval(_ chat: ChatModel, _ what: String) {
        let name = chat.agent?.name ?? "An agent"
        notify(title: "\(name) needs your OK", body: what, chat: chat.id)
        ActivityLog.add("agent waiting", "\(name): \(what)")
    }

    // MARK: Notifications

    private var asked = false
    private func requestNotifications() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in Visualizer.shared.log("notifications allowed: \(ok)") }
        }
    }

    var openStorage: () -> Void = {}

    func notify(title: String, body: String, chat: UUID?, storage: Bool = false) {
        Visualizer.shared.log("notify: \(title) — \(body.prefix(120))")
        guard !testMode, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.userInfo = storage ? ["storage": true] : ["chat": chat?.uuidString ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = (info["chat"] as? String).flatMap(UUID.init(uuidString:))
        let storage = info["storage"] as? Bool == true
        await MainActor.run {
            if storage { AgentRunner.shared.openStorage() } else if let id { AgentRunner.shared.openChat(id) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]       // show it even while 23 is in front
    }
}
