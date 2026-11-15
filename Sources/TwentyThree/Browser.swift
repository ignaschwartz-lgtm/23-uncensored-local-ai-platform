import AppKit
import ApplicationServices

/// Reads and drives the user's real Google Chrome through the Accessibility API.
/// Chrome builds its web accessibility tree once an accessibility client starts asking for it.
@MainActor
enum Chrome {
    static let bundleID = "com.google.Chrome"

    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }

    static var app: AXUIElement? {
        guard let r = running else { return nil }
        let e = AXUIElementCreateApplication(r.processIdentifier)
        AXUIElementSetAttributeValue(e, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return e
    }

    /// Waits (briefly) for Chrome to build the page's accessibility tree.
    static func waitForWebArea(timeout: Double = 3) async -> AXUIElement? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let a = webArea() { return a }
            try? await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < end
        return nil
    }

    /// The page currently showing in Chrome's front window.
    static func webArea() -> AXUIElement? {
        guard let a = app else { return nil }
        let win: AXUIElement? = AX.attr(a, kAXFocusedWindowAttribute) ?? AX.attr(a, kAXMainWindowAttribute)
            ?? (AX.attr(a, kAXWindowsAttribute) as [AXUIElement]?)?.first
        guard let w = win else { return nil }
        // The biggest web area in the window is the page (others are e.g. the omnibox popup).
        var best: (AXUIElement, CGFloat)?
        var queue = [w], seen = 0
        while !queue.isEmpty && seen < 600 {
            let e = queue.removeFirst(); seen += 1
            if (AX.attr(e, kAXRoleAttribute) as String?) == "AXWebArea" {
                let f = AX.frame(e) ?? .zero
                if f.width * f.height > (best?.1 ?? -1) { best = (e, f.width * f.height) }
                continue
            }
            queue += AX.children(e)
        }
        return best?.0
    }

    static func pageURL(_ area: AXUIElement) -> String? {
        if let u: URL = AX.attr(area, "AXURL") { return u.absoluteString }
        if let u: NSURL = AX.attr(area, "AXURL") { return u.absoluteString }
        return AX.attr(area, "AXURL")
    }

    static var currentURL: String { webArea().flatMap(pageURL) ?? "" }

    static func isLoaded(_ area: AXUIElement) -> Bool { (AX.attr(area, "AXLoaded") as Bool?) ?? true }

    // MARK: Page model

    struct Field {
        let isSearch: Bool
        let isSecret: Bool     // password, card, bank, ID or one-time-code field: 23 never types here
    }

    /// Something on the page 23 can act on.
    struct Target {
        let number: Int
        let kind: String        // "link", "button" or "field"
        let title: String
        let element: AXUIElement
        let offset: Int         // where it appears in the page text (Int.max = page menus/sidebars)
        let field: Field?
    }

    struct Page {
        var title: String
        var url: String
        var text: String                         // the whole readable text (capped)
        var targets: [Target]
        var anchors: [(offset: Int, element: AXUIElement)]   // text elements, for scrolling to a spot
    }

    private static let secretWords = try! NSRegularExpression(pattern:
        #"pass ?(word|code|phrase)|pwd|\bpin\b|\botp\b|one[- ]?time|verification|2fa|mfa|security (code|question|answer)|\bcvv|\bcvc|\bcsc\b|card ?(number|no)|cc-?(number|num|csc|exp)|credit|debit|expir|\biban\b|\bbsb\b|routing|account ?(number|no)|sort ?code|\bswift\b|\bssn\b|social security|tax file|\btfn\b|passport|licen[cs]e ?(number|no)|medicare|date of birth|\bdob\b|birthday"#,
        options: .caseInsensitive)
    private static let searchWords = try! NSRegularExpression(pattern: #"search|query|\bq\b|\bfind\b|look ?up"#, options: .caseInsensitive)

    static func looksSecret(_ s: String) -> Bool { secretWords.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// Reads the whole page: text (main content first; headings marked with #) and numbered links, buttons and fields.
    static func readPage(maxChars: Int = 40_000, maxTargets: Int = 300) -> Page? {
        guard let area = webArea() else { return nil }
        var text = ""
        var targets: [Target] = []
        var anchors: [(Int, AXUIElement)] = []
        var seenTitles = Set<String>()
        var nodes = 0
        var chromePass = false   // second pass over menus/sidebars: collect targets only

        func innerText(_ e: AXUIElement) -> String {
            var parts: [String] = []
            var q = AX.children(e), n = 0
            while !q.isEmpty && n < 40 {
                let c = q.removeFirst(); n += 1
                if (AX.attr(c, kAXRoleAttribute) as String?) == "AXStaticText", let v: String = AX.attr(c, kAXValueAttribute) { parts.append(v) }
                q += AX.children(c)
            }
            return parts.joined(separator: " ")
        }

        func label(_ e: AXUIElement) -> String {
            for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let s: String = AX.attr(e, k), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            }
            return innerText(e)
        }

        func fieldLabel(_ e: AXUIElement) -> String {
            var parts: [String] = []
            if let t: AXUIElement = AX.attr(e, "AXTitleUIElement"), let s: String = AX.attr(t, kAXValueAttribute) ?? AX.attr(t, kAXTitleAttribute) { parts.append(s) }
            for k in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
                if let s: String = AX.attr(e, k), !s.isEmpty { parts.append(s) }
            }
            var seen = Set<String>()
            let unique = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            return unique.joined(separator: " · ")
        }

        func add(_ kind: String, _ title: String, _ e: AXUIElement, _ field: Field? = nil) {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            guard targets.count < maxTargets, AX.frame(e) != nil else { return }
            let key = kind + ":" + t.lowercased()
            guard kind == "field" || (!t.isEmpty && !seenTitles.contains(key)) else { return }
            seenTitles.insert(key)
            targets.append(Target(number: targets.count + 1, kind: kind, title: String((t.isEmpty ? "(unlabelled)" : t).prefix(80)),
                                  element: e, offset: chromePass ? Int.max : text.count, field: field))
        }

        func walk(_ e: AXUIElement, _ depth: Int, inSearch: Bool) {
            guard nodes < 15_000, depth < 70 else { return }
            nodes += 1
            let role: String = AX.attr(e, kAXRoleAttribute) ?? ""
            let sub: String = AX.attr(e, kAXSubroleAttribute) ?? ""
            let searchHere = inSearch || sub == "AXLandmarkSearch"
            switch role {
            case "AXStaticText":
                if !chromePass, text.count < maxChars, let v: String = AX.attr(e, kAXValueAttribute) {
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        if anchors.last.map({ text.count - $0.0 > 300 }) ?? true { anchors.append((text.count, e)) }
                        text += (text.last == "\n" || text.isEmpty ? "" : " ") + t
                    }
                }
                return
            case "AXHeading":
                if !chromePass { text += "\n# " }
            case "AXLink":
                add("link", label(e), e)
            case "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuButton":
                add("button", label(e), e)
            case "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXSearchField":
                let l = fieldLabel(e)
                let dom: String = AX.attr(e, "AXDOMIdentifier") ?? ""
                let all = l + " " + dom
                let secret = role == "AXSecureTextField" || sub == "AXSecureTextField" || looksSecret(all)
                let search = !secret && (sub == "AXSearchField" || searchHere || searchWords.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)) != nil)
                add("field", l, e, Field(isSearch: search, isSecret: secret))
                return
            case "AXParagraph", "AXGroup", "AXList", "AXListItem", "AXRow", "AXCell":
                if !chromePass && text.last != "\n" && !text.isEmpty { text += "\n" }
            case "AXImage":
                return
            default: break
            }
            for c in AX.children(e) { walk(c, depth + 1, inSearch: searchHere) }
        }

        let main = AX.find(in: area, maxNodes: 3000) { (AX.attr($0, kAXSubroleAttribute) as String?) == "AXLandmarkMain" }
        if let m = main {
            walk(m, 0, inSearch: false)
            chromePass = true
            nodes = 0
            walk(area, 0, inSearch: false)   // menus, header search box, sidebars: targets only
        } else {
            walk(area, 0, inSearch: false)
        }

        let cleaned = text
            .replacingOccurrences(of: #"\s*\[\s*(\d+|[a-z]|citation needed|note \d+)\s*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return Page(title: AX.attr(area, kAXTitleAttribute) ?? "", url: pageURL(area) ?? "",
                    text: cleaned, targets: targets, anchors: anchors)
    }

    /// Developer aid: write what 23 can read from the current Chrome page.
    static func dump(to path: String) async {
        let found = await waitForWebArea(timeout: 4)
        var out = "trusted: \(AX.isTrusted) chrome running: \(running != nil)\n"
        if found != nil, let p = readPage() {
            out += "title: \(p.title)\nurl: \(p.url)\n--- text (\(p.text.count) chars)\n\(p.text.prefix(3000))\n--- targets\n"
            for t in p.targets {
                let f = t.field.map { $0.isSecret ? " [SECRET]" : $0.isSearch ? " [search]" : "" } ?? ""
                out += "[\(t.number)] \(t.kind)\(f) \(t.title) @\(t.offset == Int.max ? "menu" : String(t.offset))\n"
            }
        } else { out += "no web page found\n" }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Tabs (Chrome's AppleScript interface; macOS asks once for permission)

@MainActor
enum ChromeTabs {
    struct Tab { let index: Int; let id: Int; let title: String; let url: String }

    enum TabError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Tab ids 23 opened itself. Only these may be closed or navigated back.
    static var owned: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "ownedTabs") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: "ownedTabs") }
    }

    @discardableResult
    static func run(_ source: String) throws -> String {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let e = err {
            let code = e[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw TabError.message("I'm not allowed to control Chrome yet. Turn on System Settings → Privacy & Security → Automation → 23 → Google Chrome.")
            }
            throw TabError.message("Chrome didn't do that (\(e[NSAppleScript.errorMessage] as? String ?? "error \(code)")).")
        }
        return result?.stringValue ?? ""
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Opens `url` in a new tab of the front window (making a window if needed); remembers it as 23's.
    static func open(_ url: URL) throws {
        let id = try run("""
        tell application "Google Chrome"
            if (count of windows) = 0 then make new window
            tell front window to set t to make new tab with properties {URL:\(quoted(url.absoluteString))}
            activate
            return (id of t) as text
        end tell
        """)
        if let n = Int(id) { owned.insert(n) }
    }

    static func list() throws -> (active: Int, tabs: [Tab]) {
        let out = try run("""
        tell application "Google Chrome"
            if (count of windows) = 0 then return "0"
            set w to front window
            set s to (active tab index of w) as text
            set sep to character id 9
            set i to 0
            repeat with t in tabs of w
                set i to i + 1
                set s to s & linefeed & (i as text) & sep & ((id of t) as text) & sep & (title of t) & sep & (URL of t)
            end repeat
            return s
        end tell
        """)
        var lines = out.components(separatedBy: "\n")
        let active = Int(lines.removeFirst()) ?? 0
        let tabs = lines.compactMap { l -> Tab? in
            let p = l.components(separatedBy: "\t")
            guard p.count >= 4, let i = Int(p[0]), let id = Int(p[1]) else { return nil }
            return Tab(index: i, id: id, title: p[2], url: p[3...].joined(separator: "\t"))
        }
        return (active, tabs)
    }

    static func activate(index: Int) throws {
        try run("tell application \"Google Chrome\" to set active tab index of front window to \(index)\ntell application \"Google Chrome\" to activate")
    }

    static func close(id: Int) throws {
        guard owned.contains(id) else { throw TabError.message("That tab is yours, not one I opened, so I won't close it.") }
        try run("tell application \"Google Chrome\" to close (every tab of front window whose id is \(id))")
        owned.remove(id)
    }

    static func goBack(id: Int) throws {
        guard owned.contains(id) else { throw TabError.message("That tab is yours, not one I opened, so I won't navigate it back.") }
        try run("tell application \"Google Chrome\" to go back (first tab of front window whose id is \(id))")
    }
}

// MARK: - Typing (real keystrokes, only into a field 23 has verified has focus in Chrome)

@MainActor
enum Keyboard {
    enum KeyError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private static func focused() -> AXUIElement? {
        guard let a = Chrome.app else { return nil }
        return AX.attr(a, kAXFocusedUIElementAttribute)
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Puts the caret in `field` and returns the element that really has focus in the frontmost Chrome.
    /// Many sites swap a field for a fancier one when it's focused (Wikipedia's search does), so the focused
    /// element is accepted if it is a text field at the same spot — and it must pass the private-field check too.
    static func focus(_ field: AXUIElement) async throws -> AXUIElement {
        Chrome.running?.activate()
        let original = AX.frame(field)
        for attempt in 0..<3 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if attempt == 0 { AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
            else { AXUIElementPerformAction(field, kAXPressAction as CFString) }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard Chrome.isFrontmost, let f = focused() else { continue }
            if CFEqual(f, field) { return f }
            let role: String = AX.attr(f, kAXRoleAttribute) ?? ""
            let sub: String = AX.attr(f, kAXSubroleAttribute) ?? ""
            guard textRoles.contains(role), sub != "AXSecureTextField", let now = AX.frame(f), let was = original else { continue }
            let overlap = now.intersection(was.insetBy(dx: -40, dy: -20))
            guard !overlap.isNull, overlap.width * overlap.height > 0.3 * min(now.width * now.height, was.width * was.height) else { continue }
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", "AXDOMIdentifier"]
                .compactMap { AX.attr(f, $0) as String? }.joined(separator: " ")
            if Chrome.looksSecret(label) { throw KeyError.message("The field turned into a private field, so I didn't type anything.") }
            return f
        }
        throw KeyError.message("I couldn't put the cursor in that field, so I didn't type anything.")
    }

    private static func post(_ key: CGKeyCode, flags: CGEventFlags = [], unicode: [UniChar]? = nil) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            ev.flags = flags
            if let u = unicode { ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Types `text` into the focused field, replacing what was there. Stops if the user switches away.
    /// Keys still reach `field` when focus is on the field itself, or on a suggestion it shows (comboboxes
    /// report the highlighted suggestion as focused). Any other text field, a password field or another app = stop.
    private static func stillTyping(into field: AXUIElement) -> Bool {
        guard Chrome.isFrontmost, let f = focused() else { return false }
        if CFEqual(f, field) { return true }
        let role: String = AX.attr(f, kAXRoleAttribute) ?? ""
        let sub: String = AX.attr(f, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || sub == "AXSecureTextField" { return false }
        if textRoles.contains(role) {
            // The same field reported again under a new element is fine only if it sits in the same place.
            guard let a = AX.frame(f), let b = AX.frame(field) else { return false }
            return a.intersects(b)
        }
        if role == "AXWebArea" || role == "AXWindow" { return false }   // focus left the field entirely
        Visualizer.shared.log("typing: focus is on a \(role) (suggestion?), keys still go to the field")
        return true
    }

    /// Returns the element that was typed into (it may be the page's replacement for `field`).
    @discardableResult
    static func type(_ text: String, into target: AXUIElement) async throws -> AXUIElement {
        let field = try await focus(target)
        post(0, flags: .maskCommand)                       // ⌘A: replace the current contents
        try? await Task.sleep(nanoseconds: 60_000_000)
        let units = Array(text.utf16)
        let step = units.count > 160 ? 12 : 1               // short texts type visibly, letter by letter
        var i = 0
        while i < units.count {
            guard stillTyping(into: field) else {
                let role: String = focused().flatMap { AX.attr($0, kAXRoleAttribute) } ?? "nothing"
                Visualizer.shared.log("typing stopped: frontmost=\(Chrome.isFrontmost) focus on \(role)")
                throw KeyError.message("You switched away (or the field lost focus), so I stopped typing.")
            }
            var end = min(i + step, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end += 1 }   // keep emoji intact
            post(0, unicode: Array(units[i..<end]))
            i = end
            try? await Task.sleep(nanoseconds: step == 1 ? 28_000_000 : 15_000_000)
        }
        return field
    }

    static func pressReturn(in field: AXUIElement) async throws {
        guard stillTyping(into: field) else {
            throw KeyError.message("The field lost focus, so I didn't press Enter.")
        }
        post(36)
    }
}
