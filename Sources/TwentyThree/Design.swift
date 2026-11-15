import SwiftUI
import AppKit

/// 23's design system: one place for spacing, shape, type and motion.
/// Colour rule: everything is neutral. The accent (the user's macOS accent colour) appears only where
/// 23 needs the user. Red appears only for errors. Green and red tints appear only inside a code diff.
enum DS {
    /// The system accent, read directly so it keeps its colour when the window is not in front (that is when "needs you" matters most).
    static let accent = Color(nsColor: .controlAccentColor)

    enum Radius {
        static let card: CGFloat = 18
        static let bubble: CGFloat = 16
        static let row: CGFloat = 8
        static let inset: CGFloat = 10
    }

    enum Space {
        static let gutter: CGFloat = 24      // conversation side margin
        static let column: CGFloat = 720     // widest comfortable line of text
    }

    enum Text {
        static let reading = SwiftUI.Font.system(size: 14)             // conversation text
        static let code = SwiftUI.Font.system(size: 12, design: .monospaced)
    }

    enum Motion {
        /// The presence changing shape.
        static let presence = Animation.spring(response: 0.3, dampingFraction: 0.74)
        /// Panels and layout.
        static let layout = Animation.spring(response: 0.4, dampingFraction: 0.86)
        /// Small acknowledgements: hover, press, a row opening.
        static let quick = Animation.snappy(duration: 0.22)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Light, dark, or whatever the Mac is set to. Chosen from the sidebar; remembered between launches.
@MainActor
enum AppAppearance: String, CaseIterable {
    case auto, light, dark

    static var current: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appearance"); apply() }
    }
    static func apply() {
        switch current {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    var title: String { self == .auto ? "Auto" : rawValue.capitalized }
    var symbol: String { self == .auto ? "circle.lefthalf.filled" : self == .light ? "sun.max" : "moon" }
    var next: AppAppearance { self == .auto ? .light : self == .light ? .dark : .auto }
}

// MARK: - Presence

/// What 23 is doing, as the presence shows it.
enum PresenceMood: Equatable {
    case idle, listening, thinking, writing, speaking, working, away, needsYou, error

    /// Only these draw frames. Every other state is completely still.
    var isLive: Bool {
        switch self {
        case .listening, .thinking, .writing, .speaking, .working: return true
        default: return false
        }
    }

    var spoken: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .writing: return "Answering"
        case .speaking: return "Speaking"
        case .working: return "Working"
        case .away: return "Working on your screen"
        case .needsYou: return "Waiting for your approval"
        case .error: return "Something went wrong"
        }
    }

    @MainActor
    static func of(_ chat: ChatModel) -> PresenceMood {
        if chat.messages.contains(where: { $0.action?.status == .awaitingApproval }) { return .needsYou }
        switch chat.state {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .writing
        case .talking: return .speaking
        case .acting: return Visualizer.shared.cursorIsOut ? .away : .working
        case .error: return .error
        }
    }
}

/// 23 itself: a drop of smoked system glass. Its state is how the drop behaves, never its colour.
struct PresenceView: View {
    @ObservedObject var chat: ChatModel
    var size: CGFloat = 26
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ease = LevelEase()

    var body: some View {
        let mood = PresenceMood.of(chat)
        // Every display frame while live (no frame-rate cap), and nothing at all while still.
        TimelineView(.animation(paused: !mood.isLive || reduceMotion)) { tl in
            // Re-read each frame while live, so the drop notices the cursor leaving and coming home.
            let now = PresenceMood.of(chat)
            let t = tl.date.timeIntervalSinceReferenceDate
            let raw = chat.pulseStrength * exp(-Date().timeIntervalSince(chat.lastPulse) * 5)
            LensDrop(mood: now, t: t, level: reduceMotion ? 0.4 : ease.step(to: raw, at: t), size: size)
        }
        .accessibilityElement()
        .accessibilityLabel("23")
        .accessibilityValue(mood.spoken)
    }
}

/// Voice and token levels arrive in bursts. This follows them quickly on the way up and lets them fall away
/// gently, so the drop moves like liquid instead of twitching.
final class LevelEase {
    private var value = 0.0
    private var last = 0.0
    func step(to target: Double, at t: Double) -> Double {
        let dt = min(0.05, max(0, t - last)); last = t
        value += (target - value) * (1 - exp(-dt * (target > value ? 22 : 9)))
        return value
    }
}

struct LensDrop: View {
    let mood: PresenceMood
    let t: Double
    let level: Double
    let size: CGFloat

    var body: some View {
        let D = size * 0.8
        let l = CGFloat(min(1, max(0, level)))
        // Two pieces of glass that are normally one. Thinking pulls them apart and lets them rejoin;
        // working sends a small one round the other.
        let a = shape(first: true, D: D, l: l)
        let b = shape(first: false, D: D, l: l)
        let glass: Glass = mood == .needsYou ? .regular.tint(DS.accent)
            : mood == .error ? .regular.tint(.red.opacity(0.8))
            : .regular.tint(.primary.opacity(0.55))
        GlassEffectContainer(spacing: D * 0.5) {
            ZStack {
                Color.clear.frame(width: a.size.width, height: a.size.height)
                    .glassEffect(glass, in: Capsule()).offset(a.offset)
                Color.clear.frame(width: b.size.width, height: b.size.height)
                    .glassEffect(glass, in: Capsule()).offset(b.offset)
            }
        }
        .frame(width: size * 1.5, height: size)
        .opacity(mood == .away ? 0.35 : 1)
        .animation(DS.Motion.presence, value: mood)
    }

    private func shape(first: Bool, D: CGFloat, l: CGFloat) -> (size: CGSize, offset: CGSize) {
        let side: CGFloat = first ? -1 : 1
        switch mood {
        case .listening:
            return (CGSize(width: D * (1.2 + 0.6 * l), height: D * 0.86), .zero)
        case .thinking:
            let split = D * 0.36 * CGFloat(0.5 + 0.5 * sin(t * 3.1))
            let angle = t * 1.9
            return (CGSize(width: D * 0.66, height: D * 0.66),
                    CGSize(width: CGFloat(cos(angle)) * side * split, height: CGFloat(sin(angle)) * side * split))
        case .writing:
            let s = D * (0.94 + 0.12 * l)
            return (CGSize(width: s, height: s), .zero)
        case .speaking:
            let s = D * (0.9 + 0.3 * l)
            return (CGSize(width: s, height: s), .zero)
        case .working:
            if first { return (CGSize(width: D * 0.82, height: D * 0.82), .zero) }
            let angle = t * 3.8
            return (CGSize(width: D * 0.36, height: D * 0.36),
                    CGSize(width: CGFloat(cos(angle)) * D * 0.56, height: CGFloat(sin(angle)) * D * 0.56))
        case .idle, .away, .needsYou, .error:
            return (CGSize(width: D, height: D), .zero)
        }
    }
}

/// Reports where the presence sits on screen, so the on-screen cursor can leave from it and come home to it.
@MainActor
enum PresenceHome {
    /// Centre of the presence in window coordinates (origin at the window's top-left).
    static var pointInWindow: CGPoint?
}

struct PresenceHomeReporter: View {
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear
                .onAppear { PresenceHome.pointInWindow = CGPoint(x: f.midX, y: f.midY) }
                .onChange(of: f) { _, f in PresenceHome.pointInWindow = CGPoint(x: f.midX, y: f.midY) }
        }
    }
}

// MARK: - Controls

/// A quiet row or text button: it acknowledges the pointer on hover and gives a little on press.
struct QuietButtonStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = DS.Radius.row
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.primary.opacity(selected ? 0.09 : configuration.isPressed ? 0.1 : hovering ? 0.05 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(DS.Motion.quick, value: configuration.isPressed)
            .animation(DS.Motion.quick, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Spoken replies on or off, drawn as five bars. Off, they rest as a row of dots; on, they stand up like a voice.
/// They move when the pointer is over them, and while 23 is actually speaking.
struct VoiceBarsButton: View {
    let on: Bool
    let speaking: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let rest: [CGFloat] = [5, 11, 15, 9, 6]

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: !(hovering || speaking) || reduceMotion)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<5, id: \.self) { i in
                        let moving = (hovering || speaking) && !reduceMotion
                        let wave = 4 + 12 * CGFloat(pow(abs(sin(t * 4.2 + Double(i) * 0.85)), 1.4))
                        Capsule()
                            .fill(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .frame(width: 2.5, height: moving ? wave : on ? Self.rest[i] : 2.5)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .background(Circle().fill(.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Circle())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .help(on ? "23 speaks every reply. Click to speak only when you talk to it." : "Speak every reply aloud, even when you type")
        .accessibilityLabel("Spoken replies")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// A symbol-only button with a round hover target.
struct IconButton: View {
    let symbol: String
    let label: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? .primary : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: active)       // one small bounce when it turns on or off
                .frame(width: 30, height: 30)
                .background(Circle().fill(.primary.opacity(hovering ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.quick, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(DS.Motion.quick, value: configuration.isPressed)
    }
}

/// A text link in the neutral palette (used for Undo and similar).
struct QuietLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title).underline(hovering, color: .secondary).foregroundStyle(hovering ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Old colour names, now mapped onto the neutral system palette (Settings still uses them until its own pass).
enum Theme {
    /// The system accent, read directly so it keeps its colour when the window is not in front (that is when "needs you" matters most).
    static let accent = Color(nsColor: .controlAccentColor)
    static let background = Color.clear
    static let sidebar = Color.clear
    static let panel = Color.clear
    static let line = Color.primary.opacity(0.08)
    static let text = Color.primary
    static let dim = Color.secondary
}

// MARK: - Small motion

/// Words arriving: the newest few characters of a reply come up out of nothing instead of snapping in.
/// `shown` is animated towards `total` each time more text arrives; whatever is still on its way is drawn faint.
/// Lines that have fully arrived are drawn in one go, so a long reply costs no more than a short one.
struct StreamReveal: TextRenderer, Animatable {
    var shown: Double
    var total: Int
    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let pending = max(0, Double(total) - shown)
        guard pending > 0.01 else {
            for line in layout { ctx.draw(line) }
            return
        }
        let fade = 7.0
        var n = 0
        for line in layout { for run in line { n += run.count } }
        var i = 0
        for line in layout {
            let count = line.reduce(0) { $0 + $1.count }
            if Double(n - i - count) >= pending {          // the whole line has arrived
                ctx.draw(line)
                i += count
                continue
            }
            for run in line {
                for glyph in run {
                    let age = Double(n - 1 - i)             // how far this glyph is from the end of the text
                    let o = min(1, max(0, (age - pending) / fade + 1))
                    if o >= 1 { ctx.draw(glyph) } else if o > 0 {
                        var c = ctx
                        c.opacity = o
                        c.draw(glyph)
                    }
                    i += 1
                }
            }
        }
    }
}

/// Something growing out of a point and folding back into it: the approval card from the drop, the listener from the menu bar.
struct Unfold: Transition {
    var anchor: UnitPoint = .bottomLeading
    var from: CGFloat = 0.4
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : from, anchor: anchor)
            .blur(radius: phase.isIdentity ? 0 : 6)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

extension AnyTransition {
    /// Arrives by rising a little; `unfold` when motion is welcome, a plain fade when it isn't.
    /// What you just sent: it comes up from the message field and settles into the conversation.
    static var sent: AnyTransition {
        DS.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 34)).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing))
    }
    static var rise: AnyTransition { DS.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)) }
    static func unfold(from anchor: UnitPoint = .bottomLeading) -> AnyTransition {
        DS.reduceMotion ? .opacity : AnyTransition(Unfold(anchor: anchor))
    }
}
