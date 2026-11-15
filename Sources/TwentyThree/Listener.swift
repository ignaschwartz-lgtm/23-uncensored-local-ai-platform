import SwiftUI
import AppKit

/// The small floating presence that opens from the menu bar: it starts listening at once,
/// shows your words as you say them, then shows what 23 is doing and what it answers.
@MainActor
final class ListenerModel: ObservableObject {
    @Published var chat: ChatModel
    @Published var shown = false
    /// Where the menu bar mark is, across the card (0 left … 1 right): the card grows out of that point.
    @Published var anchorX: CGFloat = 0.86
    @Published var hovering = false
    init(chat: ChatModel) { self.chat = chat }
}

@MainActor
final class ListenerController {
    static let shared = ListenerController()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { ListenerController.shared.hide() }
    }

    private var panel: Panel?
    private var model: ListenerModel?
    private var idleSince: Date?
    private var timer: Timer?
    var openMainWindow: () -> Void = {}

    static let size = NSSize(width: 460, height: 300)

    var isVisible: Bool { panel?.isVisible == true && model?.shown == true }

    /// Where the presence sits on screen (AX space), so the cursor leaves from here while the listener is up.
    var presencePoint: CGPoint? {
        guard isVisible, let p = panel else { return nil }
        let f = AX.axRect(p.frame)
        return CGPoint(x: f.minX + 10 + 16 + 33, y: f.minY + 6 + 18 + 22)
    }

    func toggle(below button: NSView?) { isVisible ? hide() : show(below: button) }

    func show(below button: NSView?, demo: String? = nil) {
        let store = ConversationStore.shared
        // One chat runs at a time. If one is working, show that instead of starting another.
        let busy = ChatModel.running.flatMap { $0.isBusy ? $0 : nil }
        let chat = busy ?? (store.current.messages.isEmpty ? store.current : store.newChat())
        self.model?.chat.alwaysSpeak = false
        chat.alwaysSpeak = true              // the listener is a voice conversation: 23 answers aloud even if you type
        let model = ListenerModel(chat: chat)
        self.model = model

        let panel = self.panel ?? {
            let p = Panel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false                 // the glass card draws its own
            p.level = .statusBar
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.isMovableByWindowBackground = true
            return p
        }()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ListenerView(model: model, close: { [weak self] in self?.hide() },
                                                                 open: { [weak self] in self?.openInApp() }))
        // Hang it under the menu bar mark, kept on screen.
        let screen = button?.window?.screen ?? NSScreen.main!
        var x = screen.visibleFrame.maxX - Self.size.width - 8
        if let b = button, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            x = min(max(screen.visibleFrame.minX + 8, r.midX - Self.size.width + 60), screen.visibleFrame.maxX - Self.size.width - 8)
            model.anchorX = min(1, max(0, (r.midX - x - 10) / (Self.size.width - 20)))
        }
        panel.setFrame(NSRect(x: x, y: screen.visibleFrame.maxY - Self.size.height, width: Self.size.width, height: Self.size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        withAnimation(DS.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.78)) { model.shown = true }

        if let demo { Task { await playDemo(demo, chat) } }
        else if busy == nil {
            // No microphone is a circumstance, not a failure: say so calmly and offer the keyboard.
            if Voice.hasMicrophone { chat.startListening(autoStop: true) }
            else { chat.statusLine = "No microphone is connected." }
        }

        idleSince = nil
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }

    /// Once 23 has answered and gone quiet, the listener leaves by itself (unless the pointer is resting on it).
    private func tick() {
        guard let m = model, isVisible else { return }
        let resting = PresenceMood.of(m.chat) == .idle && !m.chat.messages.isEmpty && !m.hovering
        if !resting { idleSince = nil; return }
        if idleSince == nil { idleSince = Date() }
        if Date().timeIntervalSince(idleSince!) > 9 { hide() }
    }

    func hide() {
        guard let m = model, let p = panel else { return }
        if m.chat.state == .listening { m.chat.stop() }        // closing the listener turns the microphone off
        if !m.chat.isBusy { m.chat.alwaysSpeak = false }       // a reply already on its way is still spoken
        timer?.invalidate(); timer = nil
        withAnimation(.easeIn(duration: 0.2)) { m.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            if self?.model?.shown == false { p.orderOut(nil) }
        }
    }

    private func openInApp() {
        guard let m = model else { return }
        if !m.chat.messages.isEmpty { ConversationStore.shared.select(m.chat.id) }
        ConversationStore.shared.page = .chat
        hide()
        openMainWindow()
    }

    private func playDemo(_ text: String, _ chat: ChatModel) async {
        let words = text.split(separator: " ").map(String.init)
        chat.state = .listening; chat.statusLine = "Listening…"
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        for n in 1...max(1, words.count) {
            Voice.shared.partial = words.prefix(n).joined(separator: " ")
            chat.pulse(0.4 + Double(n % 3) * 0.25)
            try? await Task.sleep(nanoseconds: n % 4 == 0 ? 450_000_000 : 240_000_000)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        Voice.shared.partial = ""
        chat.state = .idle
        chat.autoApprove = false
        chat.send(text, spoken: false)
    }
}

struct ListenerView: View {
    @ObservedObject var model: ListenerModel
    let close: () -> Void
    let open: () -> Void

    var body: some View {
        ListenerCard(chat: model.chat, close: close, open: open)
            .onHover { model.hovering = $0 }
            // Out of the menu bar mark, and back into it.
            .scaleEffect(model.shown || DS.reduceMotion ? 1 : 0.3, anchor: UnitPoint(x: model.anchorX, y: 0))
            .blur(radius: model.shown || DS.reduceMotion ? 0 : 6)
            .opacity(model.shown ? 1 : 0)
            .padding(.horizontal, 10).padding(.top, 6)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ListenerCard: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject private var voice = Voice.shared
    let close: () -> Void
    let open: () -> Void
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var mood: PresenceMood { PresenceMood.of(chat) }
    private var pending: (id: UUID, card: ActionCard)? {
        chat.messages.last { $0.action?.status == .awaitingApproval }.map { ($0.id, $0.action!) }
    }
    private var lastUndo: UUID? {
        chat.messages.last { $0.action?.status == .done && $0.action?.undo != nil }?.id
    }
    private var answer: String { chat.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text ?? "" }
    private var heard: String { chat.messages.last { $0.role == .user }?.text ?? "" }
    /// Listening couldn't start (no microphone, no permission) or nothing was heard: offer the keyboard instead.
    private var offersTyping: Bool { (mood == .error || mood == .idle) && answer.isEmpty && heard.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PresenceView(chat: chat, size: 44).frame(width: 66, height: 44)
            VStack(alignment: .leading, spacing: 8) {
                main
                    .font(.title3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(DS.reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                    .id(stage)
                if let p = pending { approval(p.id, p.card) }
                if offersTyping {
                    TextField("Type what you would like to do", text: $typed)
                        .textFieldStyle(.plain).font(.body).focused($typing)
                        .onSubmit {
                            let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            typed = ""; chat.send(t)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(.primary.opacity(0.06)))
                        .onAppear { typing = true }
                }
                footer
            }
        }
        .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 18)
        .background {
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.2), radius: 20, y: 9)
        }
        .animation(DS.reduceMotion ? .easeInOut(duration: 0.15) : DS.Motion.layout, value: stage)
        .animation(DS.Motion.layout, value: pending?.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("23 listener")
    }

    /// What kind of thing the card is showing; the text cross-fades when this changes, not on every word.
    private var stage: String {
        switch mood {
        case .listening: return voice.partial.isEmpty ? "ask" : "words"
        case .needsYou: return "approval"
        case .idle: return answer.isEmpty ? "ask" : "answer"
        default: return "\(mood)"
        }
    }

    @ViewBuilder private var main: some View {
        switch mood {
        case .listening:
            if voice.partial.isEmpty {
                Text("What would you like to do?").foregroundStyle(.secondary)
            } else {
                // The newest word is still a guess, so it stays lighter until the next pass confirms it.
                let words = voice.partial.split(separator: " ")
                Text("\(Text(words.dropLast().joined(separator: " ")).foregroundStyle(.primary)) \(Text(words.last.map(String.init) ?? "").foregroundStyle(.secondary))")
            }
        case .thinking:
            Text(heard.isEmpty ? chat.statusLine : heard).foregroundStyle(.secondary).lineLimit(3)
        case .working, .away:
            Text(chat.messages.last { $0.action?.status == .running }?.action?.title ?? chat.statusLine).lineLimit(2).truncationMode(.middle)
        case .needsYou:
            Text("Can I go ahead?")
        case .error:
            Text(chat.statusLine).lineLimit(4)
        case .writing, .speaking, .idle:
            if answer.isEmpty {
                Text(chat.statusLine == "Ready" || chat.statusLine == "Stopped" ? "What would you like to do?" : chat.statusLine).foregroundStyle(.secondary)
            } else {
                Text(LocalizedStringKey(answer)).lineLimit(6)
            }
        }
    }

    private func approval(_ id: UUID, _ card: ActionCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !card.detail.isEmpty { Text(card.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
            Text(card.title).font(DS.Text.code).lineLimit(3)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(.primary.opacity(0.06)))
            HStack(spacing: 8) {
                Spacer()
                Button("Don't allow") { chat.answerApproval(id, approved: false) }.buttonStyle(.glass)
                Button { chat.answerApproval(id, approved: true) } label: { Text("Allow").padding(.horizontal, 6) }
                    .buttonStyle(.glassProminent).tint(DS.accent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .transition(.opacity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(mood.spoken)
            if mood == .listening {
                Text("·").foregroundStyle(.tertiary)
                QuietLink(title: "Done") { chat.finishListening() }
            }
            if chat.isBusy && mood != .needsYou {
                Text("·").foregroundStyle(.tertiary)
                QuietLink(title: "Stop") { chat.stop() }
            }
            if !chat.isBusy, let id = lastUndo {
                Text("·").foregroundStyle(.tertiary)
                QuietLink(title: "Undo") { chat.undoAction(id) }
            }
            Spacer()
            if !chat.messages.isEmpty { QuietLink(title: "Open in 23", action: open) }
            Button(action: close) {
                Text("esc").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary, lineWidth: 0.5))
            }
            .buttonStyle(PressScaleStyle())
            .help("Close (Esc)")
            .accessibilityLabel("Close")
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
