import AppKit

/// Plays the on-screen "AI cursor" choreography around each file action, then runs the real action
/// at the right moment (e.g. a move happens exactly when the file is dropped).
@MainActor
final class Visualizer {
    static let shared = Visualizer()
    private let overlay = OverlayController.shared
    private var cursor: GhostCursor { overlay.cursor }

    /// Where the orb is on screen (AX space). Set by the app delegate.
    var orbPoint: () -> CGPoint? = { nil }
    /// The panel's frame in AX space (nil when hidden) and a way to fade it, so it never hides what the cursor is touching.
    var panelRect: () -> CGRect? = { nil }
    var setPanelDimmed: (Bool) -> Void = { _ in }
    private var dimmed = false
    /// True while the cursor is away from its home, out on the screen (the presence dims to show it has left).
    private(set) var cursorIsOut = false

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "showActions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showActions") }
    }

    func perform(_ name: String, _ args: [String: Any], run: () throws -> FileTools.Result) async throws -> FileTools.Result {
        guard enabled, AX.isTrusted else { return try run() }
        let s = { (k: String) in args[k] as? String ?? "" }

        switch name {
        case "move_file", "copy_file", "trash_file":
            guard let src = try? FileTools.existing(name == "trash_file" ? s("path") : s("source")) else { return try run() }
            let srcRect = await locateItem(src)
            var destRect: CGRect?
            var destName = "Bin"
            if name == "trash_file" {
                destRect = AX.trashRect()
            } else if let dest = try? FileTools.existing(s("destination_folder")) {
                destName = dest.lastPathComponent
                destRect = await locateFolder(dest)
            }
            log("\(name) src=\(src.lastPathComponent) srcRect=\(String(describing: srcRect)) dest=\(destName) destRect=\(String(describing: destRect))")
            guard srcRect != nil || destRect != nil else { return try run() }

            await begin(around: [srcRect, destRect])
            if let r = srcRect {
                await cursor.fly(to: overlay.local(center(r)), frame: ring(r))
                await cursor.sleep(0.18)
                await cursor.press()
            }
            cursor.carried = (NSWorkspace.shared.icon(forFile: src.path), src.lastPathComponent)
            cursor.label = name == "copy_file" ? "Copying to \(destName)" : name == "trash_file" ? "To the Bin" : "Moving to \(destName)"
            if let r = destRect { await cursor.fly(to: overlay.local(center(r)), base: 0.7, frame: ring(r)) }
            return try await finish(run, big: true)

        case "rename_file":
            guard let src = try? FileTools.existing(s("path")) else { return try run() }
            guard let r = await locateItem(src) else { return try run() }
            await begin(around: [r])
            await cursor.fly(to: overlay.local(center(r)), frame: ring(r))
            await cursor.press()
            cursor.label = "Rename to \(s("new_name"))"
            await cursor.sleep(0.6)
            return try await finish(run, big: false)

        case "list_folder":
            guard let folder = try? FileTools.existing(s("folder")), let r = AX.folderRect(folder) else { return try run() }
            await begin(around: [r])
            await cursor.fly(to: overlay.local(center(r)), frame: ring(r))
            cursor.label = "Looking in \(folder.lastPathComponent)"
            cursor.ripple(true); await cursor.sleep(0.35); cursor.ripple(true)
            return try await finish(run, big: false)

        case "create_folder":
            // Make the folder first, then point at the real new icon (falling back to its parent folder).
            guard let url = try? FileTools.resolve(s("path")) else { return try run() }
            let parentRect = await locateFolder(url.deletingLastPathComponent())
            let result = try run()
            var r = AX.itemRect(url)
            for _ in 0..<8 where r == nil {
                try? await Task.sleep(nanoseconds: 120_000_000)
                r = AX.itemRect(url)
            }
            guard let target = r ?? parentRect else { return result }
            log("create_folder target=\(target) (new icon found: \(r != nil))")
            await begin(around: [target])
            await cursor.fly(to: overlay.local(center(target)), frame: ring(target))
            await cursor.press()
            cursor.label = "New folder: \(url.lastPathComponent)"
            cursor.ripple(true)
            await cursor.sleep(0.7)
            await end()
            return result

        default:
            return try run()
        }
    }

    /// For browser actions: fly to `rect`, press, run `work` there, then (optionally) sweep down `sweep`
    /// as if reading it, and return to the orb.
    func point<T>(at rect: CGRect?, label: String, sweep: CGRect? = nil, _ work: () async throws -> T) async throws -> T {
        guard enabled, AX.isTrusted, let r = rect else { return try await work() }
        await begin(around: [r, sweep], raiseFinder: false)
        await cursor.fly(to: overlay.local(CGPoint(x: r.midX, y: r.midY)), frame: ring(r))
        await cursor.press()
        cursor.ripple()
        cursor.label = label
        do {
            let result = try await work()
            if let a = sweep {
                await cursor.fly(to: overlay.local(CGPoint(x: a.minX + 60, y: a.maxY - 80)), base: 1.1)
            } else {
                cursor.ripple(true)
                await cursor.sleep(0.35)
            }
            await end()
            return result
        } catch {
            cursor.label = "Couldn't do that"
            cursor.ripple(true, color: [1.0, 0.35, 0.4])
            await cursor.sleep(0.8)
            await end()
            throw error
        }
    }

    /// While an action is showing: move the cursor somewhere else with a new label (e.g. to a found passage).
    func flyCursor(to point: CGPoint, label: String) async {
        guard enabled, AX.isTrusted else { return }
        cursor.label = label
        await cursor.fly(to: overlay.local(point))
        cursor.ripple()
        await cursor.sleep(0.4)
    }

    // MARK: Steps

    private func begin(around targets: [CGRect?], raiseFinder: Bool = true) async {
        // A target inside a Finder window may be covered by other windows: bring that window forward.
        if raiseFinder { for case let r? in targets { AX.raiseFinderWindow(containing: r) } }
        if let p = panelRect(), targets.contains(where: { $0?.intersects(p.insetBy(dx: -8, dy: -8)) == true }) {
            setPanelDimmed(true); dimmed = true
        }
        let start = orbPoint().map(overlay.local) ?? CGPoint(x: 200, y: 200)
        cursor.jump(to: start)
        cursor.carried = nil
        cursor.label = nil
        cursor.opacity = 0
        cursorIsOut = true
        overlay.show()
        cursor.ripple()
        await cursor.fade(to: 1, over: 0.2)
    }

    /// Run the real action at the current spot, show success/failure, then return to the orb.
    private func finish(_ run: () throws -> FileTools.Result, big: Bool) async throws -> FileTools.Result {
        do {
            let result = try run()
            await cursor.press()
            cursor.carried = nil
            cursor.ripple(big)
            await cursor.sleep(0.35)
            await end()
            return result
        } catch {
            cursor.carried = nil
            cursor.label = "Couldn't do that"
            cursor.ripple(true, color: [1.0, 0.35, 0.4])
            await cursor.sleep(0.8)
            await end()
            throw error
        }
    }

    private func end() async {
        cursor.label = nil
        if let o = orbPoint() {
            async let fly: () = cursor.fly(to: overlay.local(o), base: 0.45)
            async let fade: () = cursor.fade(to: 0, over: 0.6)
            _ = await (fly, fade)
        } else {
            await cursor.fade(to: 0, over: 0.3)
        }
        overlay.hide()
        cursorIsOut = false
        if dimmed { setPanelDimmed(false); dimmed = false }
    }

    // MARK: Finding things, opening Finder when needed

    /// Finds the item's icon; if it isn't visible, reveals it in a Finder window (selected) and looks again.
    private func locateItem(_ url: URL) async -> CGRect? {
        if let r = AX.itemRect(url) { return r }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let r = AX.itemRect(url) { return r }
        }
        return nil
    }

    private func locateFolder(_ url: URL) async -> CGRect? {
        if let r = AX.folderRect(url) { return r }
        return nil
    }

    private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    /// How large the ring opens to surround a thing on screen (snug, and never absurdly large).
    private func ring(_ r: CGRect) -> CGSize {
        CGSize(width: min(max(r.width + 12, 30), 300), height: min(max(r.height + 12, 30), 180))
    }

    func log(_ s: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/23.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
