import UniformTypeIdentifiers
import SwiftUI
import AppKit

/// The whole window: one sheet of glass holding the sidebar, the conversation (or settings) and the details panel.
struct RootView: View {
    @ObservedObject var store: ConversationStore
    @State private var showSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(store: store)
                    .frame(width: 232)
                    .background { SidebarGlass() }
                    .padding(8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Group {
                switch store.page {
                case .chat:
                    ChatView(chat: store.current, store: store, showSidebar: $showSidebar)
                        .id(store.currentID)
                        .transition(.opacity)
                case .settings:
                    SettingsView(store: store, showSidebar: $showSidebar)
                        .transition(.opacity)
                case .agents:
                    AgentsPage(store: store, showSidebar: $showSidebar)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.page == .chat && store.showInspector {
                ChatInspector(chat: store.current, store: store)
                    .id(store.currentID)
                    .frame(width: 272)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background { WindowGlass() }
        .ignoresSafeArea()
        .animation(DS.reduceMotion ? .easeInOut(duration: 0.15) : DS.Motion.layout, value: showSidebar)
        .animation(DS.reduceMotion ? .easeInOut(duration: 0.15) : DS.Motion.layout, value: store.showInspector)
        .animation(.easeInOut(duration: 0.18), value: store.currentID)
        .animation(.easeInOut(duration: 0.18), value: store.page)
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in showSidebar.toggle() }
    }
}

/// Where you read is solid, the way Finder and Notes are: crisp words, nothing showing through.
/// Glass is kept for the things that float over it: the sidebar, the message field, the cards.
struct WindowGlass: View {
    /// How much of the window is paint rather than glass. Developer aid: `--veil 0.5` to try another value.
    static let veil: Double = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--veil"), i + 1 < a.count, let v = Double(a[i + 1]) { return min(1, max(0, v)) }
        return 1
    }()
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency || Self.veil >= 0.999 {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Color(nsColor: .windowBackgroundColor).opacity(Self.veil)
                .glassEffect(.regular, in: Rectangle())
        }
    }
}

/// The sidebar is a separate pane of glass with a faint blue cast, floating inside the window.
struct SidebarGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    static let tint = Color(red: 0.26, green: 0.47, blue: 0.86)
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .controlBackgroundColor)).overlay(shape.fill(Self.tint.opacity(0.08)))
        } else {
            Color.clear.glassEffect(.regular.tint(Self.tint.opacity(0.16)), in: shape)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: ConversationStore
    @State private var query = ""
    @State private var renaming: ConversationStore.Summary?
    @State private var newTitle = ""
    @State private var deleting: ConversationStore.Summary?
    @FocusState private var searching: Bool
    @State private var appearance = AppAppearance.current
    @Namespace private var highlight

    /// The selection is one highlight that slides from row to row, rather than one that blinks off here and on there.
    @ViewBuilder private func selection(_ on: Bool, id: String) -> some View {
        if on {
            RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(.primary.opacity(0.09))
                .matchedGeometryEffect(id: id, in: highlight)
        }
    }
    private var slide: Animation { DS.reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.84) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
          if store.page == .settings {
            Button { store.page = .chat } label: { rowLabel("Back to chats", symbol: "chevron.left", hint: "") }
                .buttonStyle(QuietButtonStyle())
            Text("Settings").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
            ForEach(SettingsSection.shown) { sec in
                Button { store.settingsSection = sec } label: {
                    HStack(spacing: 7) {
                        Image(systemName: sec.icon).foregroundStyle(.secondary).frame(width: 16)
                        Text(sec.rawValue)
                        Spacer(minLength: 0)
                    }
                    .font(.body).padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(QuietButtonStyle())
                .background { selection(store.settingsSection == sec, id: "section") }
            }
            .animation(slide, value: store.settingsSection)
            Spacer(minLength: 0)
          } else {
            Button { store.newChat() } label: { rowLabel("New chat", symbol: "square.and.pencil", hint: "⌘N") }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("n", modifiers: .command)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 16)
                TextField("Search", text: $query).textFieldStyle(.plain).focused($searching)
            }
            .font(.body)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(.primary.opacity(searching ? 0.06 : 0)))

            if !Remote.active {
            Button { store.agentSelection = nil; store.page = .agents } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.2").foregroundStyle(.secondary).frame(width: 16)
                    Text("Agents")
                    Spacer(minLength: 0)
                    AgentsWaitingDot()
                }
                .font(.body).padding(.horizontal, 8).padding(.vertical, 6)
            }
            .buttonStyle(QuietButtonStyle(selected: store.page == .agents))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let groups = store.groups(matching: query)
                    if groups.isEmpty {
                        Text(query.isEmpty ? "Chats you start will be kept here." : "No chats match “\(query)”.")
                            .font(.callout).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.top, 14)
                    }
                    ForEach(groups, id: \.0) { title, items in
                        Text(title)
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(items) { s in row(s) }
                    }
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
          }

            RetentionNotice()
            Button { withAnimation(DS.Motion.quick) { appearance = appearance.next }; AppAppearance.current = appearance } label: {
                rowLabel("Appearance", symbol: appearance.symbol, hint: appearance.title)
            }
            .buttonStyle(QuietButtonStyle())
            .help("Switch between Auto (follows your Mac), Light and Dark")
            .accessibilityValue(appearance.title)
            Button { store.page = store.page == .settings ? .chat : .settings } label: { rowLabel("Settings", symbol: "gearshape", hint: "⌘,") }
                .buttonStyle(QuietButtonStyle(selected: store.page == .settings))
        }
        .padding(.horizontal, 8)
        .padding(.top, 44)        // clear of the window controls
        .padding(.bottom, 10)
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") { if let r = renaming { store.rename(r.id, to: newTitle) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) { if let d = deleting { store.delete(d.id) }; deleting = nil }
        } message: { Text("The chat and its notes go to the Trash, so you can still get them back from Finder.") }
    }

    private func rowLabel(_ title: String, symbol: String, hint: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
            Spacer(minLength: 0)
            Text(hint).font(.caption).foregroundStyle(.tertiary).contentTransition(.opacity)
        }
        .font(.body)
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func row(_ s: ConversationStore.Summary) -> some View {
        let selected = s.id == store.currentID && store.page == .chat
        let working = ChatModel.running?.id == s.id && ChatModel.running?.isBusy == true
        return Button { store.select(s.id) } label: {
            HStack(spacing: 6) {
                if let aid = s.agentID, let a = AgentStore.shared.agent(aid) {
                    Image(systemName: a.symbol).font(.caption).foregroundStyle(.tertiary).frame(width: 14)
                        .help(a.name).accessibilityLabel("Agent \(a.name)")
                }
                Text(s.title).lineLimit(1).truncationMode(.tail)
                    .id(s.title)        // a chat being named: the new title comes into focus over the old one
                    .transition(DS.reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                Spacer(minLength: 0)
                if AgentRunner.shared.active[s.id] != nil, store.chat(s.id)?.isPaused == true {
                    Circle().fill(DS.accent).frame(width: 7, height: 7).accessibilityLabel("Needs your OK")
                } else if working, !selected, let c = ChatModel.running {     // the open chat already shows its own drop
                    PresenceView(chat: c, size: 13).frame(width: 20)
                } else if s.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .accessibilityLabel("Pinned")
                }
            }
            .font(.body)
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(QuietButtonStyle())
        .background { selection(selected, id: "chat") }
        .animation(slide, value: selected)
        .animation(DS.Motion.layout, value: s.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Rename…") { newTitle = s.title; renaming = s }
            Button(s.pinned ? "Unpin" : "Pin") { store.togglePin(s.id) }
            Divider()
            Button("Delete…", role: .destructive) { deleting = s }
        }
    }
}

// MARK: - Chat

struct ChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var store: ConversationStore
    @Binding var showSidebar: Bool
    @ObservedObject private var voice = Voice.shared
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var attachments: [Attachment] = []
    @State private var attachProblem: String?
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    private var isEmpty: Bool { chat.messages.isEmpty }

    // Talking to 23 by clicking the drop: it wakes, asks out loud what you'd like to work on, then listens.
    private enum VoicePhase { case off, greeting, listening }
    @State private var voicePhase = VoicePhase.off
    @State private var greeting = ""
    @State private var wake = false
    @State private var dropHover = false
    @State private var dropLean = CGSize.zero
    @State private var dropBounds = CGSize.zero
    @Namespace private var dropSpace
    private static let greetings = ["What would you like to work on today?", "What shall we work on today?",
                                    "What are we working on today?", "What can I help you with today?",
                                    "Where would you like to start today?", "What's on your list today?"]

    /// The presence as a button. One drop, wherever it is: in the composer, or out in the middle of an empty page.
    private func drop(size: CGFloat) -> some View {
        Button(action: dropClicked) {
            PresenceView(chat: chat, size: size)
                .background { PresenceHomeReporter() }
                .scaleEffect(wake ? 1.3 : dropHover ? 1.07 : 1)
                .offset(dropLean)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .matchedGeometryEffect(id: "drop", in: dropSpace)
        .onHover { h in withAnimation(DS.Motion.quick) { dropHover = h } }
        // It leans a little towards the pointer, the way something aware of you would.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { dropBounds = $0 }
        .onContinuousHover { phase in
            guard !DS.reduceMotion else { return }
            var lean = CGSize.zero
            if case .active(let p) = phase, dropBounds.width > 0 {
                let dx = (p.x - dropBounds.width / 2) / (dropBounds.width / 2), dy = (p.y - dropBounds.height / 2) / (dropBounds.height / 2)
                let reach = min(4, max(1.5, dropBounds.height * 0.07))
                lean = CGSize(width: max(-1, min(1, dx)) * reach, height: max(-1, min(1, dy)) * reach)
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dropLean = lean }
        }
        .help(chat.state == .listening ? "Finish and send" : "Talk to 23")
        .accessibilityLabel(chat.state == .listening ? "Finish and send" : "Talk to 23")
    }

    private func dropClicked() {
        if chat.state == .listening { chat.finishListening(); return }
        guard !chat.isBusy, voicePhase == .off else { return }
        chat.connectHooks()
        greeting = Self.greetings.filter { $0 != greeting }.randomElement()!
        // The wake: a quick swell that springs back, and the question starts with it.
        if !DS.reduceMotion {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) { wake = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.5)) { wake = false }
            }
        }
        withAnimation(DS.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.8)) { voicePhase = .greeting }
        Voice.shared.say(greeting)
        Task {
            await Voice.shared.waitUntilQuiet()
            guard voicePhase == .greeting else { return }
            if Voice.hasMicrophone {
                voicePhase = .listening
                chat.startListening(autoStop: true)
            } else {        // nothing to listen with: say so quietly and hand over to the keyboard
                chat.statusLine = "No microphone is connected. You can type instead."
                endVoice()
                inputFocused = true
            }
        }
    }

    private func endVoice() {
        withAnimation(DS.reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.82)) { voicePhase = .off }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isEmpty {
                Spacer(minLength: 0)
                if voicePhase != .off {      // woken by a click: the drop comes out to the middle of the page
                    drop(size: 92)
                        .frame(height: 96)
                        .padding(.bottom, 20)
                }
                Text(voicePhase != .off ? greeting : "What would you like to do?")
                    .font(.title2).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .padding(.bottom, 18)
                    .transition(.opacity)
            } else {
                transcript
            }
            VStack(spacing: 8) {
                PermissionBanner()
                composer
                if isEmpty { suggestions.transition(.opacity) } else { footer }
            }
            .frame(maxWidth: isEmpty ? 600 : DS.Space.column)
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, 12)
            if isEmpty {
                Spacer(minLength: 0)
                footer.frame(maxWidth: DS.Space.column).padding(.horizontal, DS.Space.gutter).padding(.bottom, 12)
            }
        }
        // The composer starts in the middle and settles to the bottom when the conversation begins.
        .animation(DS.reduceMotion ? nil : DS.Motion.layout, value: isEmpty)
        .onAppear { inputFocused = true }
        .onChange(of: chat.state) { _, new in
            if voicePhase == .listening && new != .listening { endVoice() }     // sent, stopped or failed: the drop goes home
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusInput)) { _ in inputFocused = true }
        // Drop files anywhere on the conversation to attach them.
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(.primary.opacity(0.03)))
                    .overlay { Label("Drop to attach", systemImage: "paperclip").font(.title3).foregroundStyle(.secondary) }
                    .padding(14)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(DS.Motion.quick, value: dropTargeted)
        .onAppear(perform: installPasteMonitor)
        .onAppear {
            // Developer aid: `--demo-attach a.png,b.pdf [--demo-send "text"]` attaches files (and sends) on launch.
            let args = CommandLine.arguments
            guard let k = args.firstIndex(of: "--demo-attach"), k + 1 < args.count, attachments.isEmpty else { return }
            attach(args[k + 1].split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            if let t = args.firstIndex(of: "--demo-send"), t + 1 < args.count {
                input = args[t + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { send() }
            }
        }
        .onDisappear { if let m = pasteMonitor { NSEvent.removeMonitor(m); pasteMonitor = nil } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !showSidebar { Color.clear.frame(width: 70, height: 1) }   // room for the window controls
            IconButton(symbol: "sidebar.left", label: showSidebar ? "Hide sidebar" : "Show sidebar") { showSidebar.toggle() }
            if let a = chat.agent {
                Button { store.agentSelection = a.id; store.page = .agents } label: {
                    Label(a.name, systemImage: a.symbol).font(.callout).foregroundStyle(.secondary)
                }
                .buttonStyle(QuietButtonStyle(radius: 6))
                .help("Open the agent \(a.name)")
                if !isEmpty { Text("/").foregroundStyle(.tertiary) }
            }
            Text(isEmpty ? "" : chat.title)
                .font(.headline).lineLimit(1)
                .padding(.leading, 4)
                .contentTransition(.opacity)
            Spacer()
            IconButton(symbol: "sidebar.right", label: store.showInspector ? "Hide details" : "Show details", active: store.showInspector) {
                store.showInspector.toggle()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    private var suggestions: some View {
        HStack(spacing: 4) {
            ForEach(["Search the web for…", "Tidy my Downloads folder", "Write a script that…", "Remember that I…"], id: \.self) { s in
                Button { input = s.hasSuffix("…") ? String(s.dropLast()) + " " : s; inputFocused = true } label: {
                    Text(s).font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(QuietButtonStyle(radius: 14))
            }
        }
        .padding(.top, 4)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(chat.messages) { msg in
                        Group {
                            if msg.role == .action, let a = msg.action {
                                ActionCardView(id: msg.id, card: a, chat: chat)
                            } else {
                                MessageRow(msg: msg, streaming: chat.isBusy && msg.role == .assistant && msg.id == chat.messages.last?.id)
                                    .padding(.vertical, 7)
                            }
                        }
                        .id(msg.id)
                        // A request for approval grows out of the drop's corner; what you sent lifts out of the message field;
                        // everything else rises into place.
                        .transition(msg.action?.status == .awaitingApproval ? .unfold() : msg.role == .user ? .sent : .rise)
                    }
                    if chat.isBusy && chat.state != .speaking && PresenceMood.of(chat) != .needsYou {
                        WorkingLine(chat: chat)
                            .padding(.top, 6)
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: DS.Space.column)
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .animation(DS.Motion.layout, value: chat.messages.count)
            }
            .scrollIndicators(.automatic)
            .mask { ScrollEdgeFade() }       // words soften as they pass under the header and the message field
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in withAnimation(DS.Motion.layout) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private var composer: some View {
        let listening = chat.state == .listening
        return VStack(alignment: .leading, spacing: 6) {
        if !attachments.isEmpty {
            PendingAttachments(items: attachments) { a in
                withAnimation(DS.Motion.quick) { attachments.removeAll { $0.id == a.id } }
                AttachmentStore.remove(a)
            }
            .padding(.top, 2)
        }
        if let p = attachProblem {
            Text(p).font(.caption).foregroundStyle(.red).padding(.leading, 6).transition(.opacity)
        }
        HStack(alignment: .bottom, spacing: 8) {
            if isEmpty && voicePhase != .off {
                Color.clear.frame(width: 39, height: 30)       // its place is kept while it is out in the middle
            } else {
                drop(size: 26).frame(height: 30)
            }

            TextField(listening ? (voice.partial.isEmpty ? "Listening…" : voice.partial) : "Message 23", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Text.reading)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.vertical, 6)
                .accessibilityLabel("Message")

            effortMenu

            IconButton(symbol: "paperclip", label: "Attach files or pictures (or drop them here, or paste a screenshot)") { pickFiles() }

            IconButton(symbol: listening ? "mic.fill" : "mic",
                       label: listening ? "Stop listening and send" : "Talk to 23 (or hold ⌃⌥Space)", active: listening) { chat.toggleListening() }

            VoiceBarsButton(on: voice.mode == .always, speaking: chat.state == .talking) {
                voice.mode = voice.mode == .always ? .auto : .always
                if voice.mode != .always { Voice.shared.stopSpeaking() }
            }

            if chat.state == .talking {
                IconButton(symbol: "speaker.slash", label: "Stop speaking") { Voice.shared.stopSpeaking() }
                    .transition(.scale.combined(with: .opacity))
            }

            Button(action: chat.isBusy ? chat.stop : send) {
                Image(systemName: chat.isBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: chat.isBusy ? 11 : 13, weight: .bold))
                    .foregroundStyle(chat.isBusy || canSend ? AnyShapeStyle(.background) : AnyShapeStyle(.tertiary))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(chat.isBusy || canSend ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!chat.isBusy && !canSend)
            .help(chat.isBusy ? "Stop" : "Send")
            .accessibilityLabel(chat.isBusy ? "Stop" : "Send")
        }
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.primary.opacity(inputFocused ? 0.16 : 0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .animation(DS.Motion.quick, value: inputFocused)
        .animation(DS.Motion.quick, value: chat.state)
    }

    /// How hard 23 thinks before answering, chosen per chat from inside the message field.
    private var effortMenu: some View {
        Menu {
            Picker("Effort", selection: $chat.thinkEnabled) {
                Text("Fast — answers straight away").tag(false)
                Text("High — thinks it through first, slower").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(chat.thinkEnabled ? "High" : "Fast")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.callout)
            .foregroundStyle(chat.thinkEnabled ? .primary : .secondary)
            .padding(.horizontal, 8).frame(height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Thinking effort for this chat")
        .accessibilityLabel("Thinking effort")
        .accessibilityValue(chat.thinkEnabled ? "High" : "Fast")
    }

    /// Under the composer: what 23 is doing right now, then model · thinking · voice.
    private var footer: some View {
        let showsStatus = chat.state == .error || chat.isBusy || chat.state == .listening || chat.state == .talking
            || (chat.statusLine != "Ready" && !isEmpty) || chat.statusLine.hasPrefix("No microphone")
        return HStack(spacing: 4) {
            if showsStatus {
                Text(chat.statusLine)
                    .foregroundStyle(chat.state == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            if Remote.active {
                footerButton("on \(Remote.host.split(separator: ".").first.map(String.init) ?? Remote.host)", "This Mac is a remote for 23 on \(Remote.host)") { store.page = .settings; SettingsView.jump(to: .general) }
            } else {
                footerButton(chat.model.replacingOccurrences(of: ":latest", with: ""), "Change the model") { store.page = .settings; SettingsView.jump(to: .model) }
            }
            if !isEmpty { ContextMeter(chat: chat) }
        }
        .font(.caption)
        .animation(.easeInOut(duration: 0.2), value: chat.statusLine)
    }

    private func footerButton(_ title: String, _ help: String, strong: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(strong ? .primary : .tertiary)
                .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .buttonStyle(QuietButtonStyle(radius: 6))
        .help(help)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    private func send() {
        let text = input
        guard canSend, !chat.isBusy else { return }
        input = ""
        let atts = attachments
        attachments = []
        attachProblem = nil
        chat.send(text, attachments: atts)
    }

    // MARK: Attaching

    static let maxAttachments = 10

    private func attach(_ urls: [URL]) {
        var problems: [String] = []
        for url in urls {
            guard attachments.count < Self.maxAttachments else { problems.append("Up to \(Self.maxAttachments) attachments per message."); break }
            do {
                let a = try AttachmentStore.add(url)
                withAnimation(DS.Motion.quick) { attachments.append(a) }
            } catch { problems.append(error.localizedDescription) }
        }
        showProblem(problems.first)
        inputFocused = true
    }

    private func showProblem(_ p: String?) {
        withAnimation(DS.Motion.quick) { attachProblem = p }
        guard let p else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if attachProblem == p { withAnimation(DS.Motion.quick) { attachProblem = nil } } }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Pictures and videos can be shown to Claude (23 asks first). Text, documents and PDFs are read on this Mac."
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let found = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !found.isEmpty else { return false }
        for p in found {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { attach([url]) }
            }
        }
        return true
    }

    /// ⌘V with a picture or copied files on the clipboard attaches them (text still pastes normally).
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  event.window?.isKeyWindow == true, event.window is MainWindow else { return event }
            let pb = NSPasteboard.general
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                attach(urls); return nil
            }
            if pb.string(forType: .string) == nil, let img = NSImage(pasteboard: pb) {
                do { let a = try AttachmentStore.addPasted(img); withAnimation(DS.Motion.quick) { attachments.append(a) } }
                catch { showProblem(error.localizedDescription) }
                return nil
            }
            return event
        }
    }
}

/// The top and bottom edges of the conversation fade out instead of being cut off.
struct ScrollEdgeFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
        }
    }
}

/// Shown at the end of the conversation while 23 is busy: what it is doing right now, for how long,
/// and the line it is currently reasoning through.
struct WorkingLine: View {
    @ObservedObject var chat: ChatModel
    @State private var started = Date()

    private var reasoning: String {
        guard let m = chat.messages.last, m.role == .assistant, m.text.isEmpty else { return "" }
        return m.thinking.split(whereSeparator: \.isNewline).last.map { String($0.suffix(140)) } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                PresenceView(chat: chat, size: 15).frame(width: 22, height: 16)
                Text(chat.statusLine).foregroundStyle(.primary).contentTransition(.opacity)
                TimelineView(.periodic(from: started, by: 1)) { tl in
                    let s = Int(tl.date.timeIntervalSince(started))
                    Text(s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s").foregroundStyle(.tertiary).monospacedDigit()
                        .contentTransition(.numericText(value: Double(s)))
                        .animation(DS.reduceMotion ? nil : DS.Motion.quick, value: s)
                }
                QuietLink(title: "Stop") { chat.stop() }
            }
            .font(.callout)
            if !reasoning.isEmpty {
                Text(reasoning)
                    .font(.callout).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
                    .padding(.leading, 30)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chat.statusLine)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Details panel (right)

struct ChatInspector: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var store: ConversationStore
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("Notes for this chat") {
                    if chat.chatMemory.isEmpty {
                        Text("Ask 23 to “remember …” and it is kept here, for this chat only.")
                            .font(.callout).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(chat.chatMemory, id: \.self) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(fact).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { chat.chatMemory.removeAll { $0 == fact }; chat.persist() } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(QuietButtonStyle(radius: 9)).help("Remove this note").accessibilityLabel("Remove note")
                        }
                    }
                    HStack {
                        TextField("Add a note", text: $note).textFieldStyle(.plain).font(.callout).onSubmit(addNote)
                        if !note.trimmingCharacters(in: .whitespaces).isEmpty { QuietLink(title: "Add", action: addNote).font(.callout) }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(.primary.opacity(0.05)))
                }

                section("Remembered in every chat") {
                    let n = Memory.facts.count
                    Text(n == 0 ? "Nothing yet." : "\(n) fact\(n == 1 ? "" : "s") about you.")
                        .font(.callout).foregroundStyle(n == 0 ? .tertiary : .primary)
                    QuietLink(title: "Manage in Settings") { store.page = .settings; SettingsView.jump(to: .memory) }.font(.callout)
                }

                section("Details") {
                    detail("Model", Prefs.model)
                    detail("Started", chat.created.formatted(date: .abbreviated, time: .shortened))
                    detail("Messages", "\(chat.messages.filter { $0.role != .action }.count)")
                    detail("Actions", "\(chat.messages.filter { $0.role == .action }.count)")
                }

                let actions = chat.messages.compactMap { $0.action }.suffix(8)
                if !actions.isEmpty {
                    section("Recent actions") {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                ActionGlyph(status: a.status)
                                Text(a.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 58)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.never)
    }

    private func addNote() {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !chat.chatMemory.contains(n) else { return }
        chat.chatMemory.append(String(n.prefix(300)))
        note = ""
        if !chat.messages.isEmpty { chat.persist() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func detail(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
            .font(.callout)
            .accessibilityElement(children: .combine)
    }
}

extension Notification.Name {
    static let toggleSidebar = Notification.Name("TwentyThreeToggleSidebar")
}


/// An accent dot beside "Agents" while a run by itself is waiting for the user's OK.
struct AgentsWaitingDot: View {
    @ObservedObject private var runner = AgentRunner.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let waiting = runner.active.keys.contains { ConversationStore.shared.chat($0)?.isPaused == true }
            if waiting {
                Circle().fill(DS.accent).frame(width: 7, height: 7).accessibilityLabel("An agent needs your OK")
            }
        }
    }
}


/// How full the model's working memory is for this chat, bottom right. At 80% it turns to the accent colour and
/// offers to compact (the user decides); a click shows the details and "Compact now".
struct ContextMeter: View {
    @ObservedObject var chat: ChatModel
    @State private var showing = false

    private var fraction: Double { min(1, chat.contextFraction) }
    private var full: Bool { fraction >= ChatModel.compactAt || chat.droppedOldMessages }
    private static func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(.primary.opacity(0.12), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.02, fraction))
                        .stroke(full ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.secondary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                if full {
                    Text("Compact?").foregroundStyle(DS.accent)
                } else if fraction >= 0.5 {
                    Text("\(Int(fraction * 100))%").foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .animation(DS.Motion.quick, value: full)
        }
        .buttonStyle(QuietButtonStyle(radius: 6))
        .help("Context: \(Self.k(chat.contextTokens)) of \(Self.k(FitCheck.context)) tokens used")
        .accessibilityLabel("Context \(Int(fraction * 100)) percent full")
        .popover(isPresented: $showing, arrowEdge: .top) { details.padding(16).frame(width: 300) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context").font(.headline)
            ProgressView(value: fraction).tint(full ? DS.accent : .secondary)
            Text("\(Self.k(chat.contextTokens)) of \(Self.k(FitCheck.context)) tokens (\(Int(fraction * 100))%)").font(.callout).monospacedDigit()
            Text("Everything the model reads on each reply: 23's instructions and tools, your memory, this chat, and attachments. ")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if chat.droppedOldMessages {
                Text("Older messages no longer fit, so the model can't see them now. Compacting keeps a summary of them instead.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if full {
                Text("It's nearly full. Compacting turns the older messages into a summary so the chat can keep going.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !chat.contextSummary.isEmpty {
                Text("This chat has been compacted before; the model works from that summary plus the recent messages.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Compact now") { showing = false; chat.compactNow() }
                    .buttonStyle(.glassProminent).tint(full ? DS.accent : .gray)
                    .disabled(chat.isBusy || !chat.canCompact)
            }
            if !chat.canCompact { Text("Not enough conversation to compact yet.").font(.caption).foregroundStyle(.tertiary) }
        }
    }
}
