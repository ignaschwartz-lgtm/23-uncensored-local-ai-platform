import SwiftUI
import AppKit
import ServiceManagement

/// The Agents page: your saved assistants, and the one being edited.
struct AgentsPage: View {
    @ObservedObject var store: ConversationStore
    @Binding var showSidebar: Bool
    @ObservedObject private var agents = AgentStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !showSidebar { Color.clear.frame(width: 70, height: 1) }
                IconButton(symbol: "sidebar.left", label: showSidebar ? "Hide sidebar" : "Show sidebar") { showSidebar.toggle() }
                if let id = store.agentSelection, let a = agents.agent(id) {
                    Button { store.agentSelection = nil } label: {
                        HStack(spacing: 3) { Image(systemName: "chevron.left").font(.caption.weight(.semibold)); Text("Agents") }
                    }
                    .buttonStyle(QuietButtonStyle(radius: 6)).foregroundStyle(.secondary)
                    Text("/").foregroundStyle(.tertiary)
                    Text(a.name).font(.headline).lineLimit(1)
                } else {
                    Text("Agents").font(.headline).padding(.leading, 4)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 50)

            Group {
                if let id = store.agentSelection, agents.agent(id) != nil {
                    AgentEditor(id: id, store: store).id(id)
                } else {
                    AgentList(store: store)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeInOut(duration: 0.15), value: store.agentSelection)
    }
}

// MARK: - The list

private struct AgentList: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var runner = AgentRunner.shared

    var body: some View {
        Form {
            Section {
                if agents.agents.isEmpty {
                    Text("An agent is a saved assistant with its own instructions, folder and abilities. Chat with it, run it with one click, or let it run by itself on a schedule or when new files arrive in a folder.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(agents.agents) { a in
                    Button { store.agentSelection = a.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: a.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).foregroundStyle(.primary)
                                AgentStatusLine(agent: a).font(.caption)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Button("New agent") { create(Agent()) }
                    Menu("Start from an example") {
                        ForEach(AgentExamples.all, id: \.name) { ex in Button(ex.name) { create(ex) } }
                    }
                    .fixedSize()
                }
            } header: { Text("Your agents") }

            Section {
                LabeledContent("Keeping this Mac awake") {
                    Text(runner.keepingAwake ? "yes, while agents run by themselves" : "no (no agent runs by itself)")
                }
                LabeledContent("Open 23 at login") {
                    switch runner.loginItem {
                    case .enabled: Toggle("", isOn: Binding(get: { true }, set: { runner.setLoginItem($0) })).labelsHidden()
                    case .requiresApproval: Button("Allow in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    default: Toggle("", isOn: Binding(get: { false }, set: { runner.setLoginItem($0) })).labelsHidden()
                    }
                }
            } header: { Text("Running by themselves") } footer: {
                Text("Agents on a schedule or watching a folder need 23 open and the Mac awake: 23 keeps it from sleeping (the display still can) and opens at login. A run missed while the Mac was off happens as soon as it's back. Anything that needs your OK waits and sends you a notification.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func create(_ a: Agent) {
        var a = a
        a.id = UUID(); a.created = Date(); a.lastRun = nil
        agents.add(a)
        store.agentSelection = a.id
    }
}

/// One line about what an agent is up to.
struct AgentStatusLine: View {
    let agent: Agent
    @ObservedObject private var runner = AgentRunner.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let chats = runner.active.filter { $0.value == agent.id }.keys.compactMap { ConversationStore.shared.chat($0) }
            if chats.contains(where: \.isPaused) {
                Label("Needs your OK", systemImage: "circle.fill").labelStyle(DotLabel()).foregroundStyle(DS.accent)
            } else if !chats.isEmpty {
                Text("Working now…").foregroundStyle(.secondary)
            } else if runner.queue.contains(where: { $0.agentID == agent.id }) {
                Text("Waiting for its turn").foregroundStyle(.secondary)
            } else {
                Text(summary).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if agent.runsByItself {
            if let s = agent.schedule { parts.append(s.summary) }
            if let w = agent.watchFolder { parts.append("watches \(FileTools.display(PathPolicy.resolve(w)))") }
            if let n = agent.nextRun { parts.append("next \(n.formatted(.relative(presentation: .named)))") }
        } else if agent.enabled == false && (agent.schedule != nil || agent.watchFolder != nil) {
            parts.append("Paused")
        } else {
            parts.append("Runs when you ask")
        }
        if let l = agent.lastRun { parts.append("last ran \(l.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 6)); configuration.title }
    }
}

// MARK: - Editing one agent

private struct AgentEditor: View {
    let id: UUID
    @ObservedObject var store: ConversationStore
    @ObservedObject private var agents = AgentStore.shared
    @ObservedObject private var models = ModelStore.shared
    @ObservedObject private var runner = AgentRunner.shared
    @State private var confirmDelete = false

    private var agent: Binding<Agent> {
        Binding(get: { agents.agent(id) ?? Agent() }, set: { agents.update($0) })
    }

    var body: some View {
        let a = agent.wrappedValue
        Form {
            Section {
                TextField("Name", text: agent.name)
                Picker("Icon", selection: agent.symbol) {
                    ForEach(Agent.symbols, id: \.self) { s in Label(s, systemImage: s).labelStyle(.iconOnly).tag(s) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions")
                    TextEditor(text: agent.instructions)
                        .font(.body).frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.04)))
                }
            } header: { Text("Agent") } footer: {
                Text("How it should work: its job, tone, rules, what to focus on. It also gets your custom instructions and memory.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Works with") {
                Picker("Model", selection: Binding(get: { a.model ?? "" }, set: { agent.wrappedValue.model = $0.isEmpty ? nil : $0 })) {
                    Text("Same as 23 (\(Prefs.model))").tag("")
                    ForEach(models.installed) { m in Text(m.displayName).tag(m.shortName) }
                }
                LabeledContent("Home folder") {
                    HStack {
                        Text(FileTools.display(PathPolicy.resolve(a.folder ?? CodeTools.workspace.path))).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { if let p = pickFolder() { agent.wrappedValue.folder = p } }
                    }
                }
            }

            abilities(a)
            runsByItself(a)

            Section("Chats and runs") {
                Button("Chat with \(a.name)") { store.newChat(with: a) }
                let runs = store.summaries.filter { $0.agentID == id }.prefix(12)
                ForEach(Array(runs)) { s in
                    Button { store.select(s.id) } label: {
                        HStack {
                            Text(s.title).foregroundStyle(.primary).lineLimit(1)
                            Spacer()
                            if let c = runner.active.keys.contains(s.id) ? store.chat(s.id) : nil, c.isPaused {
                                Text("needs your OK").font(.caption).foregroundStyle(DS.accent)
                            }
                            Text(s.updated.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if runs.isEmpty { Text("No chats or runs yet.").foregroundStyle(.secondary) }
            }

            Section {
                Button("Delete agent…", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Its chats stay in your chat list.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { if models.installed.isEmpty { await models.refresh() } }
        .confirmationDialog("Delete “\(a.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.agentSelection = nil; agents.delete(id) }
        } message: { Text("It stops running. Its chats stay in your chat list.") }
    }

    // MARK: Abilities

    @ViewBuilder private func abilities(_ a: Agent) -> some View {
        Section {
            ability("Files", "Move, copy, rename and create folders", \.files, global: Prefs.allowFiles)
            ability("Web in your Chrome", "Search, open and read pages", \.web, global: Prefs.allowWeb)
            ability("Type on websites", "Fill in fields (never passwords or cards)", \.webTyping, global: Prefs.allowWeb && Prefs.allowWebTyping, needs: a.abilities.web)
            ability("Downloads", "Save files from websites", \.downloads, global: Prefs.allowWeb && Prefs.allowDownloads, needs: a.abilities.web)
            ability("Code", "Read, search and edit code files", \.code, global: Prefs.allowCode)
            ability("Run commands", "In the sandbox; risky ones ask", \.commands, global: Prefs.allowCode && Prefs.allowCommands, needs: a.abilities.code)
            ability("Memory", "Save and forget facts", \.memory, global: Prefs.allowMemory)
            Toggle(isOn: Binding(get: { Prefs.allowAddons && agent.wrappedValue.abilities.addons == true },
                                 set: { agent.wrappedValue.abilities.addons = $0 })) {
                Text("Add-on tools")
                Text(Prefs.allowAddons ? "REA and other installed add-ons; risky tools still ask" : "Off in Settings for all of 23")
            }
            .disabled(!Prefs.allowAddons)
        } header: { Text("Abilities") } footer: {
            Text("These can only narrow what Settings allows for all of 23. Approvals, the iCloud block, private-field protection and the sandbox always apply.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ability(_ title: String, _ detail: String, _ key: WritableKeyPath<Agent.Abilities, Bool>, global: Bool, needs: Bool = true) -> some View {
        Toggle(isOn: Binding(get: { global && needs && agent.wrappedValue.abilities[keyPath: key] },
                             set: { agent.wrappedValue.abilities[keyPath: key] = $0 })) {
            Text(title)
            Text(global ? detail : "Off in Settings for all of 23")
        }
        .disabled(!global || !needs)
    }

    // MARK: Running by itself

    @ViewBuilder private func runsByItself(_ a: Agent) -> some View {
        Section {
            Toggle("Runs by itself", isOn: agent.enabled)
            VStack(alignment: .leading, spacing: 6) {
                Text("What to do each time")
                TextEditor(text: agent.task)
                    .font(.body).frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.04)))
            }
            Picker("Schedule", selection: Binding(get: { a.schedule?.kind.rawValue ?? "none" }, set: { v in
                if v == "none" { agent.wrappedValue.schedule = nil }
                else { var s = a.schedule ?? Agent.Schedule(); s.kind = Agent.Schedule.Kind(rawValue: v)!; agent.wrappedValue.schedule = s }
            })) {
                Text("None").tag("none")
                Text("At a time of day").tag("daily")
                Text("Every few hours").tag("interval")
            }
            if let s = a.schedule {
                if s.kind == .daily {
                    DatePicker("Time", selection: Binding(get: {
                        Calendar.current.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: Date()) ?? Date()
                    }, set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        agent.wrappedValue.schedule?.hour = c.hour ?? 8; agent.wrappedValue.schedule?.minute = c.minute ?? 0
                    }), displayedComponents: .hourAndMinute)
                    LabeledContent("Days") {
                        HStack(spacing: 4) {
                            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { d in
                                let on = s.weekdays.contains(d)
                                Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                                    if on { agent.wrappedValue.schedule?.weekdays.remove(d) } else { agent.wrappedValue.schedule?.weekdays.insert(d) }
                                }
                                .buttonStyle(.plain)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(on ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.primary.opacity(0.06))))
                                .foregroundStyle(on ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                                .accessibilityLabel(Calendar.current.weekdaySymbols[d - 1])
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                } else {
                    Picker("Every", selection: Binding(get: { s.everyMinutes }, set: { agent.wrappedValue.schedule?.everyMinutes = $0 })) {
                        ForEach([15, 30, 60, 120, 180, 240, 360, 720], id: \.self) { m in Text(m < 60 ? "\(m) minutes" : m == 60 ? "hour" : "\(m / 60) hours").tag(m) }
                    }
                }
            }
            LabeledContent("Watch a folder") {
                HStack {
                    if let w = a.watchFolder {
                        Text(FileTools.display(PathPolicy.resolve(w))).lineLimit(1).truncationMode(.middle)
                        Button("Stop") { agent.wrappedValue.watchFolder = nil }
                    } else {
                        Text("Off").foregroundStyle(.secondary)
                    }
                    Button(a.watchFolder == nil ? "Choose…" : "Change…") { if let p = pickFolder() { agent.wrappedValue.watchFolder = p } }
                }
            }
            HStack {
                Button("Run now") { runner.runNow(id) }
                    .disabled(a.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                AgentStatusLine(agent: a).font(.callout)
            }
        } header: { Text("Running by itself") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if a.enabled && (a.schedule != nil || a.watchFolder != nil) && a.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Write what it should do each time, or it won't run by itself.").foregroundStyle(.red)
                }
                if a.abilities.web && Prefs.allowWeb && a.runsByItself {
                    Text("It will use your Chrome. If you're using the Mac when it runs, it may get in your way.")
                }
                Text("Each run is a chat in your list. Anything that needs your OK waits there and notifies you; your other chats keep working meanwhile.")
            }
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickFolder() -> String? {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Choose"
        guard p.runModal() == .OK, let url = p.url else { return nil }
        if case .deny(let why) = PathPolicy.check(url, write: false) {
            let alert = NSAlert(); alert.messageText = "That folder can't be used"; alert.informativeText = why; alert.runModal()
            return nil
        }
        return FileTools.display(url)
    }
}

// MARK: - Examples to start from

enum AgentExamples {
    static var all: [Agent] {
        var tidy = Agent(name: "Downloads tidier", symbol: "tray.and.arrow.down",
                         instructions: "You keep the Downloads folder tidy. Sort files into subfolders by kind: Documents, Images, Installers, Archives, Other. Never delete anything.",
                         task: "Sort the new files in Downloads into the right subfolders (create them if needed). Then list what you moved where.")
        tidy.folder = "~/Downloads"; tidy.watchFolder = "~/Downloads"
        tidy.abilities = .init(files: true, web: false, webTyping: false, downloads: false, code: false, commands: false, memory: false)

        var brief = Agent(name: "Morning briefing", symbol: "newspaper",
                          instructions: "You write a short, calm morning briefing. Plain language, no hype, a few bullet points.",
                          task: "Search the web for today's top news and the weather where I live, then write my briefing.")
        brief.schedule = Agent.Schedule(kind: .daily, hour: 8, minute: 0, weekdays: Set(2...6))
        brief.abilities = .init(files: false, web: true, webTyping: false, downloads: false, code: false, commands: false, memory: true)

        var coder = Agent(name: "Code helper", symbol: "chevron.left.forwardslash.chevron.right",
                          instructions: "You help with the code in the home folder. Read before editing, keep changes small, run the tests after.")
        coder.folder = "~/Developer"
        coder.abilities = .init(files: true, web: false, webTyping: false, downloads: false, code: true, commands: true, memory: true)
        return [tidy, brief, coder]
    }
}
