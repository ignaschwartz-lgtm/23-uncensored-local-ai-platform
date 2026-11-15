import SwiftUI
import AppKit

/// One turn of the conversation. The user's words sit in a quiet bubble; 23's words are plain text on the glass.
struct MessageRow: View {
    let msg: ChatMessage
    /// True while this reply is still being written: its newest words fade in.
    var streaming = false
    @State private var showThinking = false
    @State private var shown: Double = 0

    var body: some View {
        VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 6) {
            if msg.role == .assistant && !msg.thinking.isEmpty {
                Button { withAnimation(DS.Motion.quick) { showThinking.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text("Reasoning")
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(showThinking ? 90 : 0))
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(QuietButtonStyle(radius: 6))
                .padding(.leading, -6)
                .accessibilityLabel(showThinking ? "Hide reasoning" : "Show reasoning")
                if showThinking {
                    Text(msg.thinking)
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Capsule().fill(.quaternary).frame(width: 2) }
                        .transition(.opacity)
                }
            }
            if let atts = msg.attachments, !atts.isEmpty {
                MessageAttachments(items: atts).padding(.leading, 60)
            }
            if !msg.text.isEmpty || (msg.role == .user && (msg.attachments ?? []).isEmpty) {
                words
                    .padding(.horizontal, msg.role == .user ? 13 : 0)
                    .padding(.vertical, msg.role == .user ? 8 : 0)
                    .background {
                        if msg.role == .user {
                            RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous).fill(.primary.opacity(0.07))
                        }
                    }
                    .padding(.leading, msg.role == .user ? 60 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
    }

    @ViewBuilder private var words: some View {
        let text = Text(LocalizedStringKey(msg.text)).font(DS.Text.reading).lineSpacing(4)
        if streaming && !DS.reduceMotion {
            text
                .textRenderer(StreamReveal(shown: shown, total: msg.text.count))
                .onAppear { shown = Double(msg.text.count) }
                .onChange(of: msg.text.count) { _, n in
                    withAnimation(.easeOut(duration: 0.32)) { shown = Double(n) }
                }
        } else {
            text.textSelection(.enabled)
        }
    }
}

/// The small mark in front of an action. Shape carries the meaning; only failure has a colour.
struct ActionGlyph: View {
    let status: ActionCard.Status
    var body: some View {
        Group {
            switch status {
            case .running: ProgressView().controlSize(.mini).scaleEffect(0.8)
            case .awaitingApproval: Circle().fill(DS.accent).frame(width: 7, height: 7)
            case .done: Image(systemName: "checkmark").foregroundStyle(.tertiary)
            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            case .declined: Image(systemName: "minus").foregroundStyle(.tertiary)
            case .undone: Image(systemName: "arrow.uturn.backward").foregroundStyle(.tertiary)
            }
        }
        .font(.caption.weight(.semibold))
        .frame(width: 14, height: 14)
        .accessibilityLabel(label)
    }
    private var label: String {
        switch status {
        case .running: return "Running"
        case .awaitingApproval: return "Waiting for approval"
        case .done: return "Done"
        case .failed: return "Failed"
        case .declined: return "Not allowed"
        case .undone: return "Undone"
        }
    }
}

/// Something 23 did, is doing, or wants to do.
/// Finished work is a single quiet line that opens on click. A request for approval is the one raised thing on screen.
struct ActionCardView: View {
    let id: UUID
    let card: ActionCard
    @ObservedObject var chat: ChatModel
    @State private var expanded = false

    var body: some View {
        Group {
            if card.status == .awaitingApproval { approval } else { line }
        }
        .animation(DS.reduceMotion ? .easeInOut(duration: 0.15) : DS.Motion.layout, value: card.status)
    }

    private var hasMore: Bool { !card.diff.isEmpty || !card.output.isEmpty || (!card.detail.isEmpty && card.tool != "list_folder") }
    private var open: Bool { hasMore && (expanded || card.status == .running || card.status == .failed) }

    private var line: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { withAnimation(DS.Motion.quick) { expanded.toggle() } } label: {
                    HStack(spacing: 8) {
                        ActionGlyph(status: card.status)
                        Text(card.title)
                            .font(card.title.hasPrefix("$") ? DS.Text.code : .callout)
                            .foregroundStyle(card.status == .running ? .primary : card.status == .declined || card.status == .undone ? .tertiary : .secondary)
                            .strikethrough(card.status == .undone, color: .secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if !card.diff.isEmpty {      // lines added and removed, as in a code review
                            let lines = card.diff.split(separator: "\n")
                            let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                            let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                            HStack(spacing: 5) {
                                Text("+\(added)").foregroundStyle(.green).contentTransition(.numericText(value: Double(added)))
                                Text("−\(removed)").foregroundStyle(.red).contentTransition(.numericText(value: Double(removed)))
                            }
                            .animation(DS.Motion.quick, value: added + removed * 100_000)
                            .font(.caption.monospacedDigit().weight(.medium))
                            .accessibilityLabel("\(added) lines added, \(removed) removed")
                        }
                        if hasMore && card.status != .running && card.status != .failed {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .buttonStyle(QuietButtonStyle(radius: 6))
                .disabled(!hasMore || card.status == .running || card.status == .failed)
                .accessibilityHint(hasMore ? "Shows the details" : "")
                if card.status == .declined { Text("Not allowed").foregroundStyle(.tertiary) }
                if card.status == .done && card.undo != nil {
                    QuietLink(title: "Undo") { chat.undoAction(id) }
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.leading, -6)

            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if !card.detail.isEmpty && card.tool != "list_folder" || card.status == .failed {
                        Text(card.detail)
                            .font(.callout)
                            .foregroundStyle(card.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .lineLimit(4).textSelection(.enabled)
                    }
                    if !card.diff.isEmpty { DiffView(diff: card.diff) }
                    if !card.output.isEmpty {
                        if card.tool == "attachment" || card.tool == "compact" {     // readable text, not a terminal
                            ScrollView {
                                Text(LocalizedStringKey(card.output)).font(.callout).foregroundStyle(.secondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 260)
                        } else {
                            TerminalView(text: card.output)
                        }
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity)
            }
        }
    }

    private var question: String {
        switch card.tool {
        case "run_command": return "Run this command?"
        case "attachment": return "Show this to Claude?"
        case "trash_file": return "Move this to the Bin?"
        case "hand_off_to_claude": return "Hand this over to Claude?"
        case "edit_file", "write_file": return "Make this change?"
        case "remember", "forget": return "Change what I remember?"
        case let t where t.contains("download"): return "Download this file?"
        case let t where t.contains("type"): return "Type this on the page?"
        case let t where t.contains("click"): return "Click this on the page?"
        default: return "Can I go ahead?"
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LensDrop(mood: .needsYou, t: 0, level: 0, size: 20).frame(width: 22)
                    .accessibilityHidden(true)
                Text(question).font(.headline)
            }
            if !card.detail.isEmpty {
                Text(card.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(card.title)
                .font(card.tool == "attachment" ? .body : DS.Text.code)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(.primary.opacity(0.05)))
            if !card.diff.isEmpty { DiffView(diff: card.diff) }
            HStack(spacing: 8) {
                Spacer()
                Button(card.tool == "attachment" ? "Keep on this Mac" : "Don't allow") { chat.answerApproval(id, approved: false) }
                    .buttonStyle(.glass)
                Button { chat.answerApproval(id, approved: true) } label: { Text(card.tool == "attachment" ? "Send to Claude" : "Allow").padding(.horizontal, 8) }
                    .buttonStyle(.glassProminent).tint(DS.accent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Allow (⌘↩)")
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
        .padding(.vertical, 4)
        .transition(.unfold())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("23 is asking: \(question)")
    }
}

/// A code change. The only place green and red tints appear, because here they are the content.
struct DiffView: View {
    let diff: String
    var body: some View {
        let lines = diff.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(18).enumerated()), id: \.offset) { _, line in
                let added = line.hasPrefix("+"), removed = line.hasPrefix("-")
                Text(line.isEmpty ? " " : line)
                    .font(DS.Text.code)
                    .foregroundStyle(added || removed ? .primary : line.hasPrefix("@@") ? .tertiary : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 1)
                    .background(added ? Color.green.opacity(0.14) : removed ? Color.red.opacity(0.12) : .clear)
            }
            if lines.count > 18 { Text("…").font(DS.Text.code).foregroundStyle(.tertiary).padding(.horizontal, 10) }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        .accessibilityLabel("Code change")
    }
}

/// Live output of a command; follows the newest lines.
struct TerminalView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.count > 6000 ? "…" + String(text.suffix(6000)) : text)
                    .font(DS.Text.code)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .id("end")
            }
            .frame(maxHeight: 150)
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous).fill(.primary.opacity(0.05)))
        .accessibilityLabel("Command output")
    }
}

/// Asks for Accessibility access (needed to find things on screen for the cursor). Hides itself once granted.
struct PermissionBanner: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if !Remote.active && !AX.isTrusted && Visualizer.shared.enabled {      // a remote doesn't act on its own screen
                HStack(spacing: 10) {
                    Text("To show you what it is doing on screen, 23 needs Accessibility access.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Allow…") { AX.requestPermission() }.buttonStyle(.glass)
                }
                .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(.primary.opacity(0.05)))
            }
        }
    }
}
