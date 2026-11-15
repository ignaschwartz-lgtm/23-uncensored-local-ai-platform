import SwiftUI
import AppKit

// Developer aid: `--direction lens|five|ring [--dark|--light] [--freeze <mood>] [--clear]`
// A native study of three visual directions for 23. Nothing here is wired to the model or the tools;
// it only shows how the presence, the materials, the approval moment, the listener and the cursor would look and move.

enum StudyDirection: String, CaseIterable, Identifiable {
    case lens, five, ring
    var id: String { rawValue }
    var letter: String { ["A", "B", "C"][Self.allCases.firstIndex(of: self)!] }
    var title: String { rawValue.capitalized }
    var blurb: String {
        switch self {
        case .lens: return "A drop of glass. State is how the drop behaves. Accent: your macOS accent colour."
        case .five: return "Two dots and three dots. State is how they arrange. Accent: one vermilion."
        case .ring: return "A single line. State is what the line does. No accent at all; weight does the work."
        }
    }
    /// The one colour a direction may use, and only for "23 needs you" and "23 is touching your Mac".
    var accent: Color {
        switch self {
        case .lens: return .accentColor
        case .five: return Color(red: 0.92, green: 0.34, blue: 0.17)
        case .ring: return .primary
        }
    }
}

enum Mood: String, CaseIterable, Identifiable {
    case idle, listening, thinking, speaking, working, needsYou, error
    var id: String { rawValue }
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .error: return "Error"
        }
    }
    /// Only these states draw frames. Everything else is completely still.
    var isLive: Bool { self == .listening || self == .thinking || self == .speaking }
}

/// A stand-in for a microphone or speech level, 0…1, with syllables, phrases and pauses.
func studyVoiceLevel(_ t: Double) -> Double {
    let syllable = pow(abs(sin(t * 5.1)), 1.5)
    let phrase = 0.6 + 0.4 * sin(t * 1.3 + 0.7)
    let pause = sin(t * 0.61) > -0.8 ? 1.0 : 0.06
    return max(0.05, min(1, syllable * phrase * pause))
}

// MARK: - Presence

struct StudyPresence: View {
    let direction: StudyDirection
    let mood: Mood
    var size: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !mood.isLive || reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            switch direction {
            case .lens: LensMark(mood: mood, t: t, s: size, accent: direction.accent)
            case .five: FiveMark(mood: mood, t: t, s: size, accent: direction.accent)
            case .ring: RingMark(mood: mood, t: t, s: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("23")
        .accessibilityValue(mood.label)
    }
}

/// B. Two dots and three dots: the name, drawn.
struct FiveMark: View {
    let mood: Mood, t: Double, s: CGFloat, accent: Color

    var body: some View {
        let d = s * 0.17
        let pitch = d * 1.75
        let gap = d * 0.95
        let even = mood.isLive
        let color: Color = mood == .needsYou ? accent : mood == .error ? .red : .primary
        ZStack {
            ForEach(0..<5, id: \.self) { i in
                let fi = Double(i)
                let grouped = CGFloat(i) * pitch + (i >= 2 ? gap : 0) - (4 * pitch + gap) / 2
                let spread = (CGFloat(i) - 2) * pitch * 1.12
                let x = mood == .working ? 0 : even ? spread : grouped
                let level = studyVoiceLevel(t + fi * 0.37) * [0.62, 1, 0.8, 1, 0.55][i]
                let h = mood == .listening ? d * 1.5 + CGFloat(level) * s * 0.6 : d
                let lift = mood == .thinking ? -CGFloat(max(0, sin(t * 3.4 - fi * 0.75))) * d * 0.9 : 0
                let grow = mood == .speaking ? 1 + CGFloat(studyVoiceLevel(t - fi * 0.05)) * 0.75 : 1
                Capsule()
                    .fill(mood == .error ? Color.clear : color)
                    .overlay(Capsule().strokeBorder(color, lineWidth: mood == .error ? max(1, d * 0.22) : 0))
                    .frame(width: d * grow, height: h * grow)
                    .offset(x: x, y: lift)
                    .opacity(mood == .working ? (i == 2 ? 0.28 : 0) : mood == .thinking ? 0.45 + 0.55 * max(0, sin(t * 3.4 - fi * 0.75)) : 1)
            }
        }
        .frame(width: s * 1.55, height: s)
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: mood)
    }
}

/// C. One line.
struct RingMark: View {
    let mood: Mood, t: Double, s: CGFloat

    var body: some View {
        let D = s * 0.74
        let lw = max(1.5, s * 0.065)
        let color: Color = mood == .error ? .red : .primary
        let level = CGFloat(studyVoiceLevel(t))
        let inner: CGFloat = mood == .needsYou ? 1 : mood == .listening ? 0.16 + 0.62 * level : mood == .speaking ? 0.3 : 0
        ZStack {
            if mood == .speaking {      // sound leaving: rings travel outward
                ForEach(0..<2, id: \.self) { k in
                    let p = (t * 0.9 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(color, lineWidth: lw * 0.7)
                        .frame(width: D, height: D)
                        .scaleEffect(1 + CGFloat(p) * 0.55)
                        .opacity((1 - p) * 0.55)
                }
            }
            Circle()
                .trim(from: mood == .error ? 0.14 : 0, to: 1)
                .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: mood == .working ? [lw * 0.2, lw * 2.4] : []))
                .rotationEffect(.degrees(-90 - 25))
                .frame(width: D, height: D)
                .opacity(mood == .thinking ? 0.3 : mood == .working ? 0.45 : 1)
            Circle().fill(color)        // sound arriving fills the ring; a filled ring is holding something for you
                .frame(width: D - lw, height: D - lw)
                .scaleEffect(inner)
            if mood == .thinking {      // a single point going round
                Circle().fill(color)
                    .frame(width: lw * 2.6, height: lw * 2.6)
                    .offset(y: -D / 2)
                    .rotationEffect(.radians(t * 2.6))
            }
        }
        .frame(width: s, height: s)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: mood)
    }
}

/// A. A drop of system glass.
struct LensMark: View {
    let mood: Mood, t: Double, s: CGFloat, accent: Color

    var body: some View {
        let D = s * 0.8
        let level = CGFloat(studyVoiceLevel(t))
        let split = mood == .thinking ? D * 0.36 * CGFloat(0.5 + 0.5 * sin(t * 1.9)) : 0
        let angle = mood == .thinking ? t * 1.1 : 0
        let w: CGFloat = mood == .listening ? D * (1.25 + 0.55 * level) : mood == .thinking ? D * 0.66 : mood == .speaking ? D * (0.9 + 0.26 * level) : D
        let h: CGFloat = mood == .listening ? D * 0.86 : mood == .thinking ? D * 0.66 : mood == .speaking ? D * (0.9 + 0.26 * level) : D
        // Smoked rather than clear, so the drop reads on any surface, including other glass.
        let glass: Glass = mood == .needsYou ? .regular.tint(accent) : mood == .error ? .regular.tint(.red) : .regular.tint(.primary.opacity(0.55))
        GlassEffectContainer(spacing: D * 0.5) {
            ZStack {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Color.clear
                        .frame(width: w, height: h)
                        .glassEffect(glass, in: Capsule())
                        .offset(x: CGFloat(cos(angle) * side) * split, y: CGFloat(sin(angle) * side) * split)
                }
            }
        }
        .frame(width: s * 1.55, height: s)
        .opacity(mood == .working ? 0.35 : 1)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: mood)
    }
}

// MARK: - The story the board plays

@MainActor
final class StudyStory: ObservableObject {
    @Published var direction: StudyDirection
    @Published var mood: Mood = .idle
    @Published var words = 0
    // Cursor
    @Published var cursorAt = StudyStory.home
    @Published var cursorShown = false
    @Published var cursorResting = false
    @Published var pressed = false
    @Published var carrying = false
    @Published var dropped = false
    @Published var label: String?

    static let request = "Move the March invoice from the Desktop into Documents".split(separator: " ").map(String.init)
    static let home = CGPoint(x: 50, y: 52)
    static let file = CGPoint(x: 130, y: 232)
    static let folder = CGPoint(x: 400, y: 232)

    init(direction: StudyDirection, freeze: Mood?) {
        self.direction = direction
        if let freeze {
            mood = freeze
            words = Self.request.count
            if freeze == .working {
                cursorAt = CGPoint(x: 285, y: 205); cursorShown = true; carrying = true; label = "Moving to Documents"
            }
        } else {
            Task { await loop() }
        }
    }

    private func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    private let travel = Animation.spring(response: 0.62, dampingFraction: 0.84)

    private func loop() async {
        await pause(1.2)
        while true {
            withAnimation(.snappy) { mood = .listening; words = 0 }
            await pause(1.1)
            for n in 1...Self.request.count { withAnimation(.easeOut(duration: 0.18)) { words = n }; await pause(n % 4 == 0 ? 0.5 : 0.26) }
            await pause(0.9)
            withAnimation(.snappy) { mood = .thinking }
            await pause(2.2)
            withAnimation(.snappy) { mood = .working }
            // The presence leaves its home, does the work where the file really is, and comes back.
            cursorAt = Self.home; cursorResting = false
            withAnimation(.easeOut(duration: 0.15)) { cursorShown = true }
            withAnimation(travel) { cursorAt = Self.file }
            await pause(0.6)
            withAnimation(.snappy(duration: 0.25)) { cursorResting = true }
            await pause(0.35)
            withAnimation(.snappy(duration: 0.12)) { pressed = true }
            await pause(0.14)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pressed = false; carrying = true; label = "Moving to Documents" }
            await pause(0.4)
            withAnimation(travel) { cursorAt = Self.folder; cursorResting = false }
            await pause(0.7)
            withAnimation(.snappy(duration: 0.25)) { cursorResting = true }
            await pause(0.25)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dropped = true; carrying = false; label = nil }
            await pause(0.7)
            withAnimation(travel) { cursorAt = Self.home; cursorResting = false }
            await pause(0.45)
            withAnimation(.easeIn(duration: 0.2)) { cursorShown = false }
            withAnimation(.snappy) { mood = .speaking }
            await pause(3.0)
            withAnimation(.snappy) { mood = .idle }
            await pause(1.4)
            withAnimation(.easeInOut(duration: 0.4)) { dropped = false }
            await pause(0.8)
        }
    }
}

// MARK: - Board

struct StudyBoard: View {
    @ObservedObject var story: StudyStory
    let wallpaper: NSImage?

    var body: some View {
        ZStack {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
            }
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(alignment: .top, spacing: 44) {
                    StudyWindow(direction: story.direction, mood: story.mood)
                        .frame(width: 660, height: 560)
                    StudyDesk(story: story)
                        .frame(width: 520, height: 560)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Picker("Direction", selection: $story.direction) {
                ForEach(StudyDirection.allCases) { d in Text("\(d.letter)  \(d.title)").tag(d) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            Text(story.direction.blurb).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
    }
}

/// A slice of the main window: sidebar, a conversation with finished actions, one approval, the composer.
struct StudyWindow: View {
    let direction: StudyDirection
    let mood: Mood
    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 196)
            conversation
        }
        .background {
            switch direction {
            case .five: shape.fill(Color(nsColor: .windowBackgroundColor))      // the standard: opaque content, glass chrome
            case .lens: Color.clear.glassEffect(.regular, in: shape)            // the whole window is one sheet of glass
            case .ring: shape.fill(.ultraThinMaterial)                          // a thinner, quieter frost
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) { ForEach(0..<3, id: \.self) { _ in Circle().fill(.tertiary).frame(width: 12, height: 12) } }
                .padding(.leading, 6).padding(.top, 8).padding(.bottom, 18)
            row("New chat", symbol: "square.and.pencil")
            group("Today")
            row("Fibonacci script", selected: true)
            row("Invoices to Documents")
            row("Population of Melbourne")
            group("Yesterday")
            row("Tidy Downloads")
            row("Metric units, always")
            Spacer()
            row("Settings", symbol: "gearshape")
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background {
            if direction == .five {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).padding(8)
            }
        }
        .padding(direction == .five ? 6 : 0)
    }

    private func group(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
    }

    private func row(_ title: String, symbol: String? = nil, selected: Bool = false) -> some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16) }
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.body)
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Fibonacci script").font(.headline)
                Spacer()
                Image(systemName: "sidebar.right").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).frame(height: 50)

            VStack(alignment: .leading, spacing: 14) {
                Text("Make fib.py print 15 numbers and run it, then install requests.")
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("I changed the loop to 15 and ran it. The output ends at 377, which is right for the fifteenth number.")
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    done("Edited fib.py", "line 11", undo: true)
                    done("Ran python3 fib.py", "0.1 s")
                }
                approval
            }
            .font(.body)
            .padding(.horizontal, 22)
            Spacer(minLength: 0)
            composer.padding(14)
        }
    }

    /// Finished work is one quiet line. Nothing about it asks for attention.
    private func done(_ what: String, _ detail: String, undo: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 14)
            Text(what).foregroundStyle(.secondary)
            Text(detail).foregroundStyle(.tertiary)
            if undo { Text("Undo").foregroundStyle(.secondary).underline(color: .secondary.opacity(0.4)).padding(.leading, 4) }
        }
        .font(.callout)
    }

    /// The only raised thing in the conversation, and the only place the accent appears.
    private var approval: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StudyPresence(direction: direction, mood: .needsYou, size: 22)
                Text("Install requests?").font(.headline)
            }
            Text("This needs the internet and installs software in the sandbox.")
                .font(.callout).foregroundStyle(.secondary)
            Text("pip install requests")
                .font(.callout.monospaced())
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary))
            HStack(spacing: 8) {
                Spacer()
                Button("Don't allow") {}.buttonStyle(.glass)
                Button { } label: { Text("Allow").padding(.horizontal, 6) }
                    .buttonStyle(.glassProminent)
                    .tint(direction == .ring ? Color(nsColor: .labelColor) : direction.accent)
            }
            .controlSize(.large)
        }
        .padding(16)
        .background {
            let r = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if direction == .five { r.fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(0.14), radius: 14, y: 5) }
            else { r.fill(.background.opacity(0.55)) }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    private var composer: some View {
        HStack(spacing: 10) {
            StudyPresence(direction: direction, mood: mood == .needsYou ? .idle : mood, size: 26)
            Text("Message 23").foregroundStyle(.tertiary)
            Spacer()
            Image(systemName: "mic").foregroundStyle(.secondary)
            Image(systemName: "arrow.up").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
                .frame(width: 26, height: 26).background(Circle().fill(.quaternary))
        }
        .font(.body)
        .padding(.leading, 10).padding(.trailing, 9).frame(height: 44)
        .background {
            if direction == .lens { Capsule().fill(.background.opacity(0.5)) }
            else { Color.clear.glassEffect(.regular, in: Capsule()) }
        }
        .overlay(Capsule().strokeBorder(.separator.opacity(direction == .lens ? 0.5 : 0), lineWidth: 0.5))
    }
}

/// Right-hand side: the floating listener, a patch of desktop where the cursor works, and every state.
struct StudyDesk: View {
    @ObservedObject var story: StudyStory
    private var d: StudyDirection { story.direction }

    var body: some View {
        ZStack(alignment: .topLeading) {
            listener.frame(width: 440).offset(x: 0, y: 0)
            deskIcon(NSWorkspace.shared.icon(for: .folder), "Documents", bounce: story.dropped)
                .position(x: StudyStory.folder.x, y: StudyStory.folder.y + 14)
            deskIcon(NSWorkspace.shared.icon(for: .pdf), "Invoice March.pdf", bounce: false)
                .scaleEffect(story.dropped ? 0.25 : story.carrying ? 0.82 : 1)
                .opacity(story.dropped ? 0 : story.carrying ? 0.9 : 1)
                .position(story.carrying || story.dropped ? CGPoint(x: story.cursorAt.x + (d == .ring ? 0 : 26), y: story.cursorAt.y + (d == .ring ? 14 : 34))
                          : CGPoint(x: StudyStory.file.x, y: StudyStory.file.y + 14))
            cursor
            states.offset(y: 448)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // What appears when you click 23 in the menu bar.
    private var listener: some View {
        HStack(alignment: .top, spacing: 14) {
            StudyPresence(direction: d, mood: story.mood, size: 44)
                .frame(width: 68, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    switch story.mood {
                    case .listening where story.words == 0, .idle:
                        Text("What would you like to do?").foregroundStyle(.secondary)
                    case .listening:
                        // The newest word is still a guess, so it is lighter until the next one confirms it.
                        let w = StudyStory.request.prefix(story.words)
Text("\(Text(w.dropLast().joined(separator: " ")).foregroundStyle(.primary)) \(Text(w.last ?? "").foregroundStyle(.secondary))")
                    case .thinking:
                        Text(StudyStory.request.joined(separator: " ")).foregroundStyle(.secondary)
                    case .working:
                        Text("Moving the invoice to Documents")
                    case .speaking:
                        Text("Done. The March invoice is in Documents.")
                    case .needsYou:
                        Text("Can I install requests? It needs the internet.")
                    case .error:
                        Text("I couldn't reach the model. Ollama isn't running.")
                    }
                }
                .font(.title3)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.blurReplace)
                .id(story.mood == .listening ? "l\(min(story.words, 1))" : story.mood.rawValue)
                HStack(spacing: 6) {
                    Text(story.mood.label)
                    if story.mood == .working || story.mood == .speaking { Text("·"); Text("Undo") .underline(color: .secondary.opacity(0.4)) }
                    Spacer()
                    Text("esc").font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary, lineWidth: 0.5))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 18)
        .frame(minHeight: 104, alignment: .top)
        .background {
            Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        }
    }

    private func deskIcon(_ icon: NSImage, _ name: String, bounce: Bool) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                .scaleEffect(bounce ? 1.08 : 1)
            Text(name).font(.caption.weight(.medium)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        }
    }

    /// The same object as the presence, out on the desktop.
    private var cursor: some View {
        ZStack {
            switch d {
            case .lens:
                Color.clear.frame(width: story.cursorResting ? 84 : 40, height: story.cursorResting ? 84 : 40)
                    .glassEffect(.clear.tint(d.accent.opacity(0.18)), in: Circle())
            case .five:
                Circle().fill(d.accent).frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            case .ring:
                RoundedRectangle(cornerRadius: story.cursorResting ? 18 : 11, style: .continuous)
                    .strokeBorder(.white, lineWidth: 2)
                    .frame(width: story.cursorResting ? 86 : 22, height: story.cursorResting ? 86 : 22)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            }
            if let label = story.label {
                Text(label).font(.caption.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .glassEffect(.regular, in: Capsule())
                    .fixedSize()
                    .offset(y: d == .five ? -30 : -62)
                    .transition(.blurReplace)
            }
        }
        .scaleEffect(story.pressed ? 0.86 : 1)
        .opacity(story.cursorShown ? 1 : 0)
        .position(story.cursorAt)
    }

    private var states: some View {
        HStack(spacing: 0) {
            ForEach(Mood.allCases) { m in
                VStack(spacing: 10) {
                    StudyPresence(direction: d, mood: m, size: 34).frame(height: 40)
                    Text(m.label).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .frame(width: 520)
    }
}

// MARK: - Launch

@MainActor
enum DirectionStudy {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { NSApp.terminate(nil) }
    }
    private static var window: NSWindow?
    private static var statusItem: NSStatusItem?
    private static var story: StudyStory?

    static func run(_ args: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if args.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { app.appearance = NSAppearance(named: .aqua) }
        let name = args.firstIndex(of: "--direction").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "lens"
        let freeze = args.firstIndex(of: "--freeze").flatMap { $0 + 1 < args.count ? Mood(rawValue: args[$0 + 1]) : nil }
        let story = StudyStory(direction: StudyDirection(rawValue: name) ?? .lens, freeze: freeze)
        self.story = story

        let screen = NSScreen.main!
        let clear = args.contains("--clear")
        let wallpaper = clear ? nil : NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = !clear
        w.backgroundColor = clear ? .clear : .windowBackgroundColor
        w.hasShadow = false
        w.contentView = NSHostingView(rootView: StudyBoard(story: story, wallpaper: wallpaper))
        w.setFrame(screen.frame, display: true)
        w.makeKeyAndOrderFront(nil)
        window = w

        // The menu bar mark for this direction.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarMark(story.direction)
        statusItem = item

        let menu = NSMenu(); let sub = NSMenu()
        sub.addItem(withTitle: "Quit Study", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let top = NSMenuItem(); top.submenu = sub; menu.addItem(top)
        app.mainMenu = menu
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    static func menuBarMark(_ d: StudyDirection) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { r in
            NSColor.black.set()
            switch d {
            case .five:
                let dia: CGFloat = 3.2, pitch: CGFloat = 4.3, gap: CGFloat = 2.2
                let total = 4 * pitch + gap + dia
                for i in 0..<5 {
                    let x = (r.width - total) / 2 + CGFloat(i) * pitch + (i >= 2 ? gap : 0)
                    NSBezierPath(ovalIn: NSRect(x: x, y: r.midY - dia / 2, width: dia, height: dia)).fill()
                }
            case .ring:
                let p = NSBezierPath(ovalIn: NSRect(x: r.midX - 6, y: r.midY - 6, width: 12, height: 12)); p.lineWidth = 1.6; p.stroke()
            case .lens:
                NSBezierPath(ovalIn: NSRect(x: r.midX - 6.5, y: r.midY - 6.5, width: 13, height: 13)).fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                let hi = NSBezierPath(); hi.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: 4, startAngle: 100, endAngle: 170)
                hi.lineWidth = 1.6; hi.lineCapStyle = .round; hi.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
