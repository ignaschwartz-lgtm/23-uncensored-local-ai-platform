import AppKit
import SwiftUI

/// 23's cursor on your screen: a ring that travels to the real thing and frames it.
/// Read by the overlay every frame.
@MainActor
final class GhostCursor {
    static let travelSize = CGSize(width: 22, height: 22)

    var pos = CGPoint.zero
    var opacity = 0.0
    var scale = 1.0
    var size = GhostCursor.travelSize
    var carried: (icon: NSImage, name: String)?
    var label: String?
    var failed = false
    /// Where the ring has just been, newest last: drawn as a short fading wake on long moves.
    private(set) var wake: [(t: Double, p: CGPoint)] = []

    // Current flight
    private var from = CGPoint.zero, to = CGPoint.zero, ctrl = CGPoint.zero
    private var start = 0.0, duration = 0.0
    private var fadeFrom = 0.0, fadeTo = 0.0, fadeStart = 0.0, fadeDur = 0.0
    private var sizeGoal = GhostCursor.travelSize, restSize = GhostCursor.travelSize
    private var scaleGoal = 1.0
    private var lastTick = 0.0

    static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    /// Advance animations to time `t` (called by the overlay's render loop).
    func tick(_ t: Double) {
        let dt = min(0.05, max(0, t - lastTick)); lastTick = t
        if duration > 0 {
            let u = min(1, max(0, (t - start) / duration))
            // A spring just short of critically damped: leaves gently, covers ground quickly,
            // runs a hair past the target (about 1.5% of the trip) and settles back onto it.
            let e = 1 - exp(-7.2 * u) * (cos(5.4 * u) + 1.3333 * sin(5.4 * u))
            let a = 1 - e
            pos = CGPoint(x: a * a * from.x + 2 * a * e * ctrl.x + e * e * to.x,
                          y: a * a * from.y + 2 * a * e * ctrl.y + e * e * to.y)
            sizeGoal = e > 0.86 ? restSize : (carried != nil ? CGSize(width: 68, height: 68) : Self.travelSize)
        }
        if fadeDur > 0 {
            let u = min(1, max(0, (t - fadeStart) / fadeDur))
            opacity = fadeFrom + (fadeTo - fadeFrom) * u
        }
        wake.append((t, pos))
        while let first = wake.first, t - first.t > 0.14 { wake.removeFirst() }
        let k = 1 - exp(-dt * 16)
        size.width += (sizeGoal.width - size.width) * k
        size.height += (sizeGoal.height - size.height) * k
        scale += (scaleGoal - scale) * (1 - exp(-dt * 26))
    }

    func jump(to p: CGPoint) {
        pos = p; from = p; to = p; duration = 0; wake.removeAll()
        size = Self.travelSize; sizeGoal = Self.travelSize; restSize = Self.travelSize; failed = false
    }

    /// Travel to `target` and, on arrival, open up to `frame` so the ring surrounds what it has reached.
    func fly(to target: CGPoint, base: Double = 0.55, frame: CGSize? = nil) async {
        restSize = frame ?? (carried != nil ? CGSize(width: 68, height: 68) : Self.travelSize)
        if DS.reduceMotion {             // no travel: fade out, reappear at the target
            await fade(to: 0, over: 0.12)
            pos = target; size = restSize; sizeGoal = restSize; wake.removeAll()
            await fade(to: 1, over: 0.15)
            return
        }
        let d = hypot(target.x - pos.x, target.y - pos.y)
        from = pos; to = target
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let lift = min(70, d * 0.12)
        ctrl = CGPoint(x: mid.x + (to.y - from.y) / max(d, 1) * lift * 0.5, y: mid.y - lift)
        start = Self.now(); duration = base + min(0.55, d / 2600)
        await sleep(duration)
        duration = 0; pos = target; sizeGoal = restSize
    }

    func fade(to value: Double, over seconds: Double) async {
        fadeFrom = opacity; fadeTo = value; fadeStart = Self.now(); fadeDur = seconds
        await sleep(seconds)
        fadeDur = 0; opacity = value
    }

    /// Kept for the choreography's call sites: a coloured ripple now means "that failed".
    func ripple(_ big: Bool = false, color: SIMD3<Double>? = nil) {
        if color != nil { failed = true }
    }

    /// The ring tightens on what it holds, then lets go.
    func press() async {
        scaleGoal = 0.86; await sleep(0.13); scaleGoal = 1.0
    }

    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
}

/// A click-through window covering every screen, drawn above everything (including the Dock).
@MainActor
final class OverlayController {
    static let shared = OverlayController()
    let cursor = GhostCursor()
    private var window: NSWindow?
    /// AX-space origin of the overlay (top-left of the union of all screens).
    private(set) var axOrigin = CGPoint.zero

    private func ensureWindow() -> NSWindow {
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        if let w = window, w.frame == union { return w }
        let w = NSWindow(contentRect: union, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: OverlayView(cursor: cursor))
        w.setFrame(union, display: false)
        window = w
        axOrigin = AX.axRect(union).origin
        return w
    }

    func show() { ensureWindow().orderFrontRegardless() }
    func hide() { window?.orderOut(nil) }

    /// AX-space point → overlay view point.
    func local(_ p: CGPoint) -> CGPoint {
        _ = ensureWindow()
        return CGPoint(x: p.x - axOrigin.x, y: p.y - axOrigin.y)
    }
}

struct OverlayView: View {
    let cursor: GhostCursor

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, canvas in
                cursor.tick(tl.date.timeIntervalSinceReferenceDate)
                guard cursor.opacity > 0.01 else { return }
                ctx.opacity = cursor.opacity
                let w = cursor.size.width * cursor.scale, h = cursor.size.height * cursor.scale
                let rect = CGRect(x: cursor.pos.x - w / 2, y: cursor.pos.y - h / 2, width: w, height: h)
                drawWake(&ctx, now: tl.date.timeIntervalSinceReferenceDate, size: CGSize(width: w, height: h))
                if let c = cursor.carried {
                    let side = min(52, min(w, h) - 14)
                    if side > 12 {
                        var g = ctx; g.opacity = cursor.opacity * 0.95
                        g.draw(Image(nsImage: c.icon), in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
                    }
                }
                drawRing(&ctx, rect)
                if let l = cursor.label { drawLabel(&ctx, l, above: rect, canvas: canvas) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Three fainter rings where it was a moment ago. Only shows when it is covering ground; at rest they sit under the ring.
    private func drawWake(_ ctx: inout GraphicsContext, now: Double, size: CGSize) {
        guard cursor.carried == nil, min(size.width, size.height) <= 30 else { return }
        for (age, strength) in [(0.035, 0.22), (0.07, 0.13), (0.105, 0.06)] {
            guard let s = cursor.wake.last(where: { now - $0.t >= age }),
                  hypot(s.p.x - cursor.pos.x, s.p.y - cursor.pos.y) > 7 else { continue }
            var g = ctx
            g.opacity = cursor.opacity * strength
            let r = CGRect(x: s.p.x - size.width / 2, y: s.p.y - size.height / 2, width: size.width, height: size.height)
            g.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 2)
        }
    }

    /// White with a soft dark edge, so it holds on a white Finder window and on a dark photo alike.
    private func drawRing(_ ctx: inout GraphicsContext, _ rect: CGRect) {
        let m = min(rect.width, rect.height)
        let radius = m <= 30 ? m / 2 : min(18, m * 0.24)
        let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        var g = ctx
        g.addFilter(.shadow(color: .black.opacity(0.5), radius: 3.5, y: 1))
        g.stroke(path, with: .color(cursor.failed ? Color(red: 1, green: 0.27, blue: 0.23) : .white), lineWidth: 2.25)
    }

    private func drawLabel(_ ctx: inout GraphicsContext, _ s: String, above ring: CGRect, canvas: CGSize) {
        let text = ctx.resolve(Text(s).font(.system(size: 12, weight: .medium)).foregroundColor(.white))
        let size = text.measure(in: CGSize(width: 340, height: 20))
        let w = size.width + 20, h = size.height + 9
        var y = ring.minY - h - 9
        if y < 30 { y = ring.maxY + 9 }
        let r = CGRect(x: max(6, min(ring.midX - w / 2, canvas.width - w - 6)), y: y, width: w, height: h)
        var g = ctx
        g.addFilter(.shadow(color: .black.opacity(0.25), radius: 6, y: 2))
        g.fill(Path(roundedRect: r, cornerRadius: h / 2), with: .color(Color(white: 0.13).opacity(0.86)))
        ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: h / 2), with: .color(.white.opacity(0.14)), lineWidth: 1)
        ctx.draw(text, in: r.insetBy(dx: 10, dy: 4.5))
    }
}
