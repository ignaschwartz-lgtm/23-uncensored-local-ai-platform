import SwiftUI
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    /// On a remote, only what belongs to this Mac (everything else lives on the Mac that runs 23).
    static var shown: [SettingsSection] { Remote.active ? [.general, .voice, .about] : allCases }
    case setup = "Setup", general = "General", model = "Model", memory = "Memory", storage = "Storage", addons = "Add-ons", voice = "Voice", web = "Web & Safety", logs = "Logs", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .model: return "cpu"
        case .setup: return "checklist"
        case .memory: return "brain"
        case .storage: return "internaldrive"
        case .addons: return "puzzlepiece.extension"
        case .voice: return "waveform"
        case .web: return "globe"
        case .logs: return "list.bullet.rectangle"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: ConversationStore
    @Binding var showSidebar: Bool

    static func jump(to s: SettingsSection) { ConversationStore.shared.settingsSection = s }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !showSidebar { Color.clear.frame(width: 70, height: 1) }
                IconButton(symbol: "sidebar.left", label: showSidebar ? "Hide sidebar" : "Show sidebar") { showSidebar.toggle() }
                Text(store.settingsSection.rawValue).font(.headline).padding(.leading, 4)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            Form {
                switch store.settingsSection {
                case .general: GeneralSettings()
                case .model: ModelSettings()
                case .memory: MemorySettings()
                case .storage: StorageSettings()
                case .setup: SetupSettings()
                case .addons: AddonsSettings()
                case .voice: VoiceSettings()
                case .web: WebSettings()
                case .logs: LogSettings()
                case .about: AboutSettings()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .id(store.settingsSection)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.15), value: store.settingsSection)
    }
}

// MARK: - Building blocks (thin wrappers over the system's grouped form)

struct SettingsGroup<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        Section {
            content()
        } header: {
            Text(title)
        } footer: {
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String
    let key: String
    var fallback = true
    var disabled = false
    @AppStorage private var value: Bool

    init(_ title: String, _ detail: String, key: String, fallback: Bool = true, disabled: Bool = false) {
        self.title = title; self.detail = detail; self.key = key; self.fallback = fallback; self.disabled = disabled
        _value = AppStorage(wrappedValue: fallback, key)
    }

    var body: some View {
        Toggle(isOn: $value) {
            Text(title)
            Text(detail)
        }
        .disabled(disabled)
        .onChange(of: value) { _, v in ActivityLog.add("setting", "\(key) → \(v ? "on" : "off")") }
    }
}

struct InfoRow: View {
    let key: String
    let value: String
    var ok: Bool? = nil
    var body: some View {
        LabeledContent(key) {
            HStack(spacing: 6) {
                if ok == false {     // only a problem gets a mark; things that are fine stay quiet
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red).accessibilityLabel("Problem")
                }
                Text(value).textSelection(.enabled)
            }
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @AppStorage(Prefs.Key.allowWeb) private var allowWeb = true
    @AppStorage(Prefs.Key.allowCode) private var allowCode = true
    @AppStorage(Prefs.Key.customInstructions) private var custom = ""

    var body: some View {
        RemoteSettings()
        if !Remote.active { localGeneral }
    }

    @ViewBuilder private var localGeneral: some View {
        SettingsGroup(title: "What 23 may do",
                      note: "Switched-off abilities aren't offered to the model at all, and are refused if it asks anyway. Safety rules (approvals, iCloud, private fields, the sandbox) always apply.") {
            ToggleRow("Files", "Look in, move, copy, rename and create folders. Deleting always asks first.", key: Prefs.Key.allowFiles)
            ToggleRow("Web browsing", "Open pages, search, read and click in your Chrome.", key: Prefs.Key.allowWeb)
            ToggleRow("Typing on websites", "Fill in search boxes and forms (never passwords or card details).", key: Prefs.Key.allowWebTyping, disabled: !allowWeb)
            ToggleRow("Downloads", "Save files to Downloads, always with your OK. Programs are never allowed.", key: Prefs.Key.allowDownloads, disabled: !allowWeb)
            ToggleRow("Code", "Read, search, edit and create code files.", key: Prefs.Key.allowCode)
            ToggleRow("Run commands", "Run scripts and tests in a sandbox (internet only with your OK).", key: Prefs.Key.allowCommands, disabled: !allowCode)
            ToggleRow("Hand off to Claude", "Pass a coding task to Claude Code, only when you ask for Claude by name.", key: Prefs.Key.allowHandOff, disabled: !allowCode)
            ToggleRow("Save memories", "Remember notes for a chat or facts for all chats when you ask.", key: Prefs.Key.allowMemory)
            ToggleRow("Add-on tools", "Use installed add-ons such as REA. Risky add-on tools still ask first. Manage them in Settings › Add-ons.", key: Prefs.Key.allowAddons)
        }
        SettingsGroup(title: "How it behaves") {
            ToggleRow("Start new chats on High effort", "23 thinks things through before answering: slower, but better for hard questions. You can change it per chat in the message field.", key: Prefs.Key.thinkByDefault, fallback: false)
            ToggleRow("Show actions on screen", "A ring travels to the files, links and fields 23 is working on.", key: Prefs.Key.showActions)
            ToggleRow("Open edited files in VS Code", "Jump to the changed line after 23 edits code.", key: Prefs.Key.showEditsInEditor)
        }
        SettingsGroup(title: "Custom instructions", note: "Anything 23 should always keep in mind, e.g. “Answer in Spanish”, “Use metric units”, “Be brief”.") {
            TextEditor(text: $custom)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
        }
    }
}

// MARK: - Model


// MARK: - Memory


// MARK: - Voice

struct VoiceSettings: View {
    @ObservedObject private var voice = Voice.shared
    @State private var mode = Voice.shared.mode
    @State private var kokoroVoice = Voice.shared.kokoroVoice
    @State private var quality = Voice.shared.kokoroQuality
    @State private var mic = Voice.hasMicrophone

    var body: some View {
        SettingsGroup(title: "Spoken replies") {
            pickerRow("Speak replies", selection: $mode, options: [("When I talk to 23", Voice.Mode.auto), ("Always", .always), ("Never", .off)])
                .onChange(of: mode) { _, v in voice.mode = v; if v == .off { voice.stopSpeaking() } }
            pickerRow("Voice", selection: $kokoroVoice, options: [("Heart (US)", "af_heart"), ("Emma (British)", "bf_emma"),
                                                                  ("Michael (US)", "am_michael"), ("George (British)", "bm_george")])
                .onChange(of: kokoroVoice) { _, v in voice.kokoroVoice = v; voice.say("Hi, this is how I sound now.") }
            pickerRow("Quality", selection: $quality, options: [("Compact (less memory)", "int8"), ("Full quality", "full")])
                .onChange(of: quality) { _, v in voice.kokoroQuality = v; voice.restartKokoro() }
            HStack {
                Spacer()
                Button("Preview voice") { voice.say("Hi, I'm twenty-three. This is how I sound.") }.controlSize(.small)
            }
            
        }
        SettingsGroup(title: "Listening", note: "Press ⌥3 to open the floating listener and just talk. Or hold ⌃⌥Space, or click the mic in the chat. The microphone is only on while you do.") {
            InfoRow(key: "Microphone", value: mic ? "connected" : "none connected (plug in a USB mic, headset or AirPods)", ok: mic)
            InfoRow(key: "Speech to text", value: voice.whisperInstalled ? "whisper.cpp · small English model · on this Mac" : "not installed", ok: voice.whisperInstalled)
            InfoRow(key: "Voice engine", value: voice.kokoroInstalled ? "Kokoro · on this Mac, sleeps when idle" : "macOS voice (Kokoro not installed)", ok: voice.kokoroInstalled)
            HStack { Spacer(); Button("Check again") { mic = Voice.hasMicrophone }.controlSize(.small) }
        }
    }

    private func pickerRow<T: Hashable>(_ title: String, selection: Binding<T>, options: [(String, T)]) -> some View {
        // A plain form picker: the form puts the title on the left and the menu against the right edge, like every other row.
        Picker(title, selection: selection) { ForEach(options, id: \.1) { Text($0.0).tag($0.1) } }
    }
}

// MARK: - Web & Safety

struct WebSettings: View {
    @State private var rules = SitePolicy.userLevels.sorted { $0.key < $1.key }
    @State private var site = ""
    @State private var level = TrustLevel.trusted
    @State private var message: String?

    var body: some View {
        SettingsGroup(title: "Site rules",
                      note: "Trusted: 23 may type into forms and press send-type buttons without asking (payments, deletions and downloads still ask). Protected: 23 asks before every click and keystroke. Banks, payments, email, accounts and government sites are always protected.") {
            if rules.isEmpty { Text("No rules yet.").font(.callout).foregroundStyle(Theme.dim) }
            ForEach(rules, id: \.key) { r in
                HStack {
                    Text(r.key).font(.body.monospaced()).foregroundStyle(Theme.text)
                    Spacer()
                    Text(r.value.capitalized).font(.callout).foregroundStyle(.secondary)
                    Button { message = SitePolicy.set(r.key, to: .normal); reload() } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Remove rule")
                }
                
            }
            HStack {
                TextField("website, e.g. wikipedia.org", text: $site).textFieldStyle(.plain).font(.body).onSubmit(add)
                Picker("", selection: $level) { Text("Trusted").tag(TrustLevel.trusted); Text("Protected").tag(TrustLevel.protected) }
                    .labelsHidden().frame(width: 120)
                Button("Add", action: add).disabled(site.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            
        }
        if let message { Text(message).font(.callout).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true) }
        SettingsGroup(title: "Always on", note: "These can't be switched off.") {
            ForEach(["iCloud and Apple Account data are never touched", "Passwords, card numbers, bank details and one-time codes are never typed",
                     "Text from web pages can't be typed elsewhere without your OK", "Downloaded programs and installers are refused; files stay quarantined",
                     "Commands run in a macOS sandbox; internet only with your OK", "Deleting, buying, sending and installing always ask first"], id: \.self) { t in
                HStack(spacing: 8) { Image(systemName: "lock.fill").foregroundStyle(.tertiary).font(.caption); Text(t).font(.callout).foregroundStyle(Theme.text) }
                    
            }
        }
    }

    private func add() { message = SitePolicy.set(site, to: level); site = ""; reload() }
    private func reload() { rules = SitePolicy.userLevels.sorted { $0.key < $1.key } }
}

// MARK: - Logs

struct LogSettings: View {
    enum Which: String, CaseIterable { case activity = "Activity", debug = "Technical" }
    @State private var which = Which.activity
    @State private var filter = ""
    @State private var lines: [String] = []

    var body: some View {
        SettingsGroup(title: "Logs", note: "Everything 23 has done (Activity), or its technical log for troubleshooting. Newest first.") {
            HStack {
                Picker("", selection: $which) { ForEach(Which.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                TextField("Filter…", text: $filter).textFieldStyle(.roundedBorder).font(.callout)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            
            .onChange(of: which) { _, _ in load() }
            ScrollView {
                let shown = filter.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(filter) }
                VStack(alignment: .leading, spacing: 3) {
                    if shown.isEmpty { Text("Nothing here yet.").foregroundStyle(Theme.dim) }
                    ForEach(Array(shown.prefix(400).enumerated()), id: \.offset) { _, l in
                        Text(l).foregroundStyle(Theme.text.opacity(0.85)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                
            }
            .frame(height: 380)
            
        }
        HStack {
            Button("Open in Console") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .controlSize(.small)
        .task { load() }
    }

    private var url: URL {
        which == .activity ? ActivityLog.url : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/23.log")
    }

    private func load() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lines = Array(text.split(separator: "\n").map(String.init).suffix(2000).reversed())
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        SettingsGroup(title: "23") {
            InfoRow(key: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
            InfoRow(key: "Chats saved in", value: "~/Library/Application Support/23/conversations")
            InfoRow(key: "Memory file", value: "~/Library/Application Support/23/memory.md")
            InfoRow(key: "Activity log", value: "~/Library/Logs/23-activity.log")
            InfoRow(key: "Talk to 23 (floating listener)", value: "⌥3")
            InfoRow(key: "Show / hide", value: "⌥Space")
            InfoRow(key: "Push to talk", value: "hold ⌃⌥Space")
        }
    }
}
