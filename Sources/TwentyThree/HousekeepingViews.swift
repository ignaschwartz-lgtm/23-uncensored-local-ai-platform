import SwiftUI
import AppKit

// MARK: - Settings › Memory

struct MemorySettings: View {
    @State private var entries = Memory.entries
    @State private var selected = Set<String>()
    @State private var newFact = ""
    @State private var error: String?
    @State private var filter = ""
    @State private var tidying = false
    @State private var suggestions: [MemoryTidy.Suggestion]?
    @State private var chosen = Set<String>()

    private var shown: [(fact: String, meta: Memory.Meta?)] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? entries : entries.filter { $0.fact.lowercased().contains(q) }
    }

    var body: some View {
        SettingsGroup(title: "Remembered in every chat",
                      note: "23 reads these with every message, so they're kept short: \(Memory.usedChars.formatted()) of \(Memory.maxChars.formatted()) characters used. Each chat also keeps its own notes, in that chat's details panel.") {
            if entries.isEmpty {
                Text("Nothing yet. Say “remember that I … (for all chats)”, or add one below.").foregroundStyle(.secondary)
            } else {
                if entries.count > 6 {
                    TextField("Filter", text: $filter, prompt: Text("Filter memories")).labelsHidden().textFieldStyle(.roundedBorder)
                }
                ForEach(shown, id: \.fact) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: Binding(get: { selected.contains(e.fact) }, set: { on in if on { selected.insert(e.fact) } else { selected.remove(e.fact) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel("Select “\(e.fact)”")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.fact).textSelection(.enabled)
                            Text(origin(e.meta)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            HStack {
                TextField("Add", text: $newFact, prompt: Text("Add something 23 should always know…")).labelsHidden().textFieldStyle(.plain).onSubmit(add)
                Button("Add", action: add).disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if let error { Text(error).font(.callout).foregroundStyle(.red) }
        HStack {
            Button(selected.isEmpty ? "Forget selected" : "Forget \(selected.count) selected") { forget(Array(selected)) }
                .disabled(selected.isEmpty)
            if !entries.isEmpty {
                Button(selected.count == entries.count ? "Select none" : "Select all") {
                    selected = selected.count == entries.count ? [] : Set(entries.map(\.fact))
                }
            }
            Spacer()
            Button(tidying ? "Looking…" : "Tidy up…") { Task { await tidy() } }
                .disabled(tidying || entries.count < 2)
                .help("Your model suggests duplicates and things that look out of date. Nothing is removed until you choose.")
        }
        .controlSize(.small)

        if let s = suggestions {
            SettingsGroup(title: "Suggested to forget", note: s.isEmpty ? nil : "Suggested by your model. Untick anything you want to keep.") {
                if s.isEmpty {
                    Text("Nothing looks duplicated or out of date.").foregroundStyle(.secondary)
                } else {
                    ForEach(s) { sug in
                        Toggle(isOn: Binding(get: { chosen.contains(sug.fact) }, set: { on in if on { chosen.insert(sug.fact) } else { chosen.remove(sug.fact) } })) {
                            Text(sug.fact)
                            Text(sug.reason)
                        }
                        .toggleStyle(.checkbox)
                    }
                    HStack {
                        Button("Not now") { suggestions = nil }
                        Spacer()
                        Button("Forget \(chosen.count)") { forget(Array(chosen)); suggestions = nil }.disabled(chosen.isEmpty)
                    }
                }
            }
        }

        HStack {
            Button("Open memory file") {
                if !FileManager.default.fileExists(atPath: Memory.url.path) { try? Memory.restore([]) }
                NSWorkspace.shared.open([Memory.url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration())
            }
            Button("Reload") { reload() }
        }
        .controlSize(.small)
    }

    private func origin(_ m: Memory.Meta?) -> String {
        guard let m else { return "saved before dates were kept" }
        let when = m.added.formatted(date: .abbreviated, time: .omitted)
        return m.source.map { "\(when) · from “\($0)”" } ?? when
    }

    private func reload() { entries = Memory.entries; selected = selected.filter { f in entries.contains { $0.fact == f } } }

    private func add() {
        Memory.currentSource = "Settings"
        do { _ = try Memory.add(newFact); ActivityLog.add("remember (you)", newFact); newFact = ""; error = nil; reload() }
        catch { self.error = error.localizedDescription }
    }

    private func forget(_ facts: [String]) {
        do {
            try Memory.remove(exactly: facts)
            ActivityLog.add("forget (you)", facts.joined(separator: " | "))
            selected.subtract(facts)
            error = nil
        } catch { self.error = error.localizedDescription }
        reload()
    }

    private func tidy() async {
        tidying = true
        defer { tidying = false }
        do {
            let s = try await MemoryTidy.suggest()
            suggestions = s
            chosen = Set(s.map(\.fact))
            error = nil
        } catch { self.error = "Couldn't tidy up: \(error.localizedDescription)" }
    }
}

// MARK: - Settings › Storage

struct StorageSettings: View {
    @ObservedObject private var retention = Retention.shared
    @ObservedObject private var store = ConversationStore.shared
    @State private var items: [Storage.Item] = []
    @State private var days = Retention.days
    @State private var runsKept = Retention.agentRunsKept
    @State private var confirm: Pending?
    @State private var done: String?

    private struct Pending: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let action: () -> Void
    }

    var body: some View {
        SettingsGroup(title: "Old chats",
                      note: "Chats you haven't opened for a while go to the Bin, so you can still get them back. You're told a week before, and can keep any of them. Pinned chats are never touched.") {
            Picker("Move chats to the Bin after", selection: $days) {
                Text("Never").tag(0)
                ForEach([30, 60, 90, 180, 365], id: \.self) { d in Text(d == 365 ? "a year" : "\(d) days").tag(d) }
            }
            .onChange(of: days) { _, v in Retention.days = v; ActivityLog.add("setting", "move old chats to the Bin after → \(v == 0 ? "never" : "\(v) days")") }
            Picker("Agent runs kept per agent", selection: $runsKept) {
                ForEach([10, 20, 50, 100], id: \.self) { Text("\($0) newest").tag($0) }
                Text("All").tag(0)
            }
            .onChange(of: runsKept) { _, v in Retention.agentRunsKept = v; ActivityLog.add("setting", "agent runs kept → \(v == 0 ? "all" : "\(v)")") }
        }

        if !retention.upcoming.isEmpty {
            SettingsGroup(title: "Going to the Bin soon") {
                ForEach(retention.upcoming) { u in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(u.title).lineLimit(1)
                            Text("on \(u.binOn.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Keep") { retention.keep(u.id) }
                        Button("Pin") { store.togglePin(u.id); retention.keep(u.id) }
                    }
                }
            }
        }

        SettingsGroup(title: "Space used") {
            if items.isEmpty { HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) } }
            ForEach(items) { i in
                LabeledContent {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: i.bytes, countStyle: .file)).monospacedDigit()
                        if let f = i.folder, FileManager.default.fileExists(atPath: f.path) {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([f]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless).help("Show in Finder")
                        }
                    }
                } label: {
                    Text(i.title)
                    Text(i.detail)
                }
            }
        }

        SettingsGroup(title: "Clean up", note: "Chats, attachments and backups go to the Bin. Pinned chats and anything working or waiting are left alone.") {
            LabeledContent("Chats not opened in") {
                Menu("Choose…") {
                    ForEach([7, 30, 90, 365], id: \.self) { d in
                        let list = Storage.chats(olderThan: d)
                        Button("\(d == 365 ? "a year" : "\(d) days") (\(list.count))") {
                            ask("Move \(list.count) chat\(list.count == 1 ? "" : "s") to the Bin?", "Chats not opened in \(d) days. You can get them back from the Bin.") { Storage.bin(list) }
                        }
                        .disabled(list.isEmpty)
                    }
                }
                .fixedSize()
            }
            LabeledContent("Agent runs") {
                let runs = Storage.chats(olderThan: 0, agentRunsOnly: true)
                Button("Bin all \(runs.count)") { ask("Move all \(runs.count) agent runs to the Bin?", "Chats you started with an agent count as runs too. Pinned ones stay.") { Storage.bin(runs) } }
                    .disabled(runs.isEmpty)
            }
            LabeledContent("Edit backups older than 30 days") {
                Button("Bin them") { ask("Move old edit backups to the Bin?", "Edits older than 30 days can then no longer be undone from 23.") { done = "\(Storage.binSnapshots(olderThan: 30)) backups moved to the Bin." } }
            }
            LabeledContent("Attachment copies no chat uses") {
                Button("Bin them") { done = "\(Storage.binUnusedAttachments()) unused attachment copies moved to the Bin." ; Task { await measure() } }
            }
            LabeledContent("Logs") {
                Button("Keep only the newest") { Storage.trimLogs(); done = "Logs trimmed to the newest ~2 MB each."; Task { await measure() } }
            }
            if let done { Text(done).font(.callout).foregroundStyle(.secondary) }
        }
        .task { await measure(); retention.check() }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Move to Bin", role: .destructive) { confirm?.action(); confirm = nil; Task { await measure() } }
        } message: { Text(confirm?.message ?? "") }
    }

    private func ask(_ title: String, _ message: String, _ action: @escaping () -> Void) { confirm = Pending(title: title, message: message, action: action) }
    private func measure() async { items = await Storage.measure() }
}

/// A quiet line at the bottom of the sidebar while old chats are about to go to the Bin.
struct RetentionNotice: View {
    @ObservedObject private var retention = Retention.shared
    var body: some View {
        if !retention.upcoming.isEmpty {
            Button {
                ConversationStore.shared.page = .settings
                SettingsView.jump(to: .storage)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 16)
                    Text("\(retention.upcoming.count) old chat\(retention.upcoming.count == 1 ? "" : "s") going to the Bin")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .buttonStyle(QuietButtonStyle())
            .help("Review them in Settings › Storage, and keep any you want")
        }
    }
}
