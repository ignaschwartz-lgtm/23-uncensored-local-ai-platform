import AppKit
import ApplicationServices

/// Finds where things are on screen (file icons, Finder windows, Dock items) using the Accessibility API.
/// All rects are in "AX space": global coordinates with the origin at the top-left of the main screen.
@MainActor
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Low-level helpers

    static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? []
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv: AXValue = attr(e, kAXPositionAttribute), let sv: AXValue = attr(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p)
        AXValueGetValue(sv, .cgSize, &s)
        guard s.width > 1, s.height > 1 else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func labels(_ e: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, "AXFilename"].compactMap { attr(e, $0) as String? }
    }

    static func app(_ bundleID: String) -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first.map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    /// Breadth-first search with limits so a huge folder can't freeze us.
    static func find(in root: AXUIElement, maxNodes: Int = 4000, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var seen = 0
        while !queue.isEmpty && seen < maxNodes {
            let e = queue.removeFirst()
            seen += 1
            if match(e) { return e }
            queue += children(e)
        }
        return nil
    }

    private static func named(_ name: String) -> (AXUIElement) -> Bool {
        let wanted = name.lowercased()
        return { e in labels(e).contains { $0.lowercased() == wanted } && frame(e) != nil }
    }

    private static func onScreen(_ r: CGRect) -> Bool {
        let total = NSScreen.screens.reduce(CGRect.null) { $0.union(axRect($1.frame)) }
        return total.intersects(r)
    }

    /// Converts an AppKit (bottom-left origin) rect into AX space.
    static func axRect(_ r: NSRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Finder / Dock queries

    static var finder: AXUIElement? { app("com.apple.finder") }
    static var dock: AXUIElement? { app("com.apple.dock") }

    /// Finder windows (not the desktop), front-most first.
    static func finderWindows() -> [AXUIElement] {
        guard let f = finder else { return [] }
        return (attr(f, kAXWindowsAttribute) as [AXUIElement]?) ?? []
    }

    /// A Finder window currently showing `folder`.
    static func finderWindow(showing folder: URL) -> AXUIElement? {
        finderWindows().first { w in
            if let doc: String = attr(w, kAXDocumentAttribute), let u = URL(string: doc) {
                return u.standardizedFileURL.path == folder.standardizedFileURL.path
            }
            return (attr(w, kAXTitleAttribute) as String?) == folder.lastPathComponent
        }
    }

    /// Where an item's icon is visible right now: on the desktop or inside a Finder window showing its folder.
    static func itemRect(_ url: URL) -> CGRect? {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        if let w = finderWindow(showing: parent), let e = find(in: w, named(name)), let r = frame(e), onScreen(r) { return r }
        if parent.path == FileTools.home.appendingPathComponent("Desktop").path, let f = finder {
            // Desktop icons live in Finder's desktop scroll area, not in its windows.
            for c in children(f) where (attr(c, kAXRoleAttribute) as String?) == "AXScrollArea" {
                if let e = find(in: c, named(name)), let r = frame(e) { return r }
            }
        }
        return nil
    }

    /// Somewhere sensible to "drop" into a folder: its open window, its sidebar entry, its Dock stack or its desktop icon.
    static func folderRect(_ folder: URL) -> CGRect? {
        if let w = finderWindow(showing: folder), let r = frame(w) {
            return CGRect(x: r.midX - 40, y: r.midY - 40, width: 80, height: 80)
        }
        if let r = itemRect(folder) { return r }
        if let d = dock, let e = find(in: d, named(folder.lastPathComponent)), let r = frame(e) { return r }
        for w in finderWindows() {
            if let e = find(in: w, maxNodes: 1500, named(folder.lastPathComponent)), let r = frame(e), onScreen(r) { return r }
        }
        if folder.path == FileTools.home.appendingPathComponent("Desktop").path, let s = NSScreen.main {
            let v = axRect(s.visibleFrame)
            return CGRect(x: v.maxX - 220, y: v.minY + 120, width: 80, height: 80)
        }
        return nil
    }

    /// Brings forward the Finder window that contains `rect` (if any), without activating Finder for the desktop.
    static func raiseFinderWindow(containing rect: CGRect) {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        guard let w = finderWindows().first(where: {
            (attr($0, kAXSubroleAttribute) as String?) == "AXStandardWindow" && frame($0)?.contains(mid) == true
        }) else { return }
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    }

    /// An app's icon in the Dock (the real app entry, not a Handoff copy).
    static func dockItemRect(named name: String) -> CGRect? {
        guard let d = dock else { return nil }
        let e = find(in: d) {
            (attr($0, kAXSubroleAttribute) as String?) == "AXApplicationDockItem" && (attr($0, kAXTitleAttribute) as String?) == name
        }
        return e.flatMap(frame)
    }

    /// The Trash/Bin in the Dock (its name is localised, so match on its subrole).
    static func trashRect() -> CGRect? {
        guard let d = dock else { return nil }
        let e = find(in: d) { (attr($0, kAXSubroleAttribute) as String?) == "AXTrashDockItem" }
        return e.flatMap(frame)
    }

    /// Developer aid: dump Finder's and the Dock's AX trees to a text file.
    static func dump(to path: String) {
        var out = "trusted: \(isTrusted)\n"
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 9, out.count < 400_000 else { return }
            let role: String = attr(e, kAXRoleAttribute) ?? "?"
            let sub: String = attr(e, kAXSubroleAttribute) ?? ""
            let f = frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
            out += String(repeating: "  ", count: depth) + "\(role) \(sub) [\(labels(e).joined(separator: " | "))] \(f)\n"
            for c in children(e) { walk(c, depth + 1) }
        }
        if let f = finder { out += "== Finder\n"; walk(f, 0) }
        if let d = dock { out += "== Dock\n"; walk(d, 0) }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
