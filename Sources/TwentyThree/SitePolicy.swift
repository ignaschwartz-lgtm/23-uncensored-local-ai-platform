import Foundation

/// How careful 23 must be on a website. Only the user can change this (with /trust, /protect, /normal
/// typed in the panel); the model has no tool for it, so a web page can never raise its own trust.
enum TrustLevel: String {
    case trusted     // the user vouched for it: form typing and send/submit-type clicks don't ask
    case normal      // default rules
    case protected   // banking, payments, email, accounts…: every click and every keystroke asks first
}

enum SitePolicy {
    /// Built-in sensitive sites. They are always protected, whatever the user sets.
    private static let builtInDomains = [
        // payments & money
        "paypal.com", "stripe.com", "wise.com", "revolut.com", "afterpay.com", "zip.co", "klarna.com",
        "americanexpress.com", "amex.com", "visa.com", "mastercard.com",
        "coinbase.com", "binance.com", "kraken.com", "crypto.com",
        // banks
        "commbank.com.au", "netbank.com.au", "westpac.com.au", "anz.com", "anz.com.au", "nab.com.au", "ing.com.au",
        "bankwest.com.au", "stgeorge.com.au", "macquarie.com.au", "ubank.com.au", "bendigobank.com.au", "suncorp.com.au",
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "hsbc.com", "barclays.co.uk",
        // email & accounts
        "mail.google.com", "accounts.google.com", "myaccount.google.com", "outlook.live.com", "outlook.office.com",
        "login.live.com", "login.microsoftonline.com", "account.microsoft.com", "mail.yahoo.com", "proton.me",
        "icloud.com", "appleid.apple.com", "account.apple.com",
        // government & tax
        "my.gov.au", "ato.gov.au", "servicesaustralia.gov.au", "irs.gov",
    ]
    private static let sensitivePath = try! NSRegularExpression(pattern:
        #"/(checkout|payment|payments|billing|pay|wallet|password|security|signin|sign-in|login|log-in|account/settings|settings/account)(/|$|\?)"#,
        options: .caseInsensitive)

    private static let key = "siteTrust"

    static func domain(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func matches(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

    static func isBuiltInProtected(_ host: String) -> Bool {
        builtInDomains.contains { matches(host, $0) } || host.split(separator: ".").contains { $0.contains("bank") }
    }

    static var userLevels: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func level(for urlString: String) -> TrustLevel {
        guard let host = domain(of: urlString) else { return .normal }
        if isBuiltInProtected(host) { return .protected }
        if let url = URL(string: urlString) {
            let path = url.path + (url.query.map { "?" + $0 } ?? "")
            if sensitivePath.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil { return .protected }
        }
        // Most specific user rule wins (e.g. "docs.example.com" over "example.com").
        let rules = userLevels.filter { matches(host, $0.key) }.sorted { $0.key.count > $1.key.count }
        return rules.first.flatMap { TrustLevel(rawValue: $0.value) } ?? .normal
    }

    /// Handles /trust, /protect, /normal from the user. Returns the reply to show.
    static func set(_ raw: String, to level: TrustLevel) -> String {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let host = domain(of: d.contains("://") ? d : "https://" + d) { d = host }
        guard d.contains("."), !d.contains(" ") else { return "That doesn't look like a website name, e.g. wikipedia.org" }
        if level == .trusted && isBuiltInProtected(d) {
            return "\(d) is on my built-in sensitive list (banking, payments, email or accounts), so it always stays protected."
        }
        var all = userLevels
        if level == .normal { all.removeValue(forKey: d) } else { all[d] = level.rawValue }
        userLevels = all
        ActivityLog.add("site rule", "\(d) → \(level.rawValue)")
        switch level {
        case .trusted: return "✓ \(d) is now trusted: I can type into its forms and press send/submit-type buttons without asking. Payments, deletions and downloads still ask, and I never type passwords or card details."
        case .protected: return "✓ \(d) is now protected: I'll ask before every click and every keystroke there."
        case .normal: return "✓ \(d) is back to normal rules."
        }
    }

    static func summary() -> String {
        let rules = userLevels.sorted { $0.key < $1.key }.map { "• \($0.key): \($0.value)" }
        return (rules.isEmpty ? "No site rules yet." : "Your site rules:\n" + rules.joined(separator: "\n"))
            + "\nBanks, payments, email, accounts and government sites are always protected."
            + "\nCommands: /trust site · /protect site · /normal site"
    }
}

/// Everything 23 does, one line per action, in ~/Library/Logs/23-activity.log.
enum ActivityLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/23-activity.log")

    /// Off during the selftest, so test actions don't clutter the user's real log.
    nonisolated(unsafe) static var enabled = true

    static func add(_ what: String, _ detail: String) {
        guard enabled else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  \(what.padding(toLength: 14, withPad: " ", startingAt: 0))  \(detail.replacingOccurrences(of: "\n", with: " ").prefix(400))\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// Long-term memory: plain lines in a Markdown file the user can open and edit.
enum Memory {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/23")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.md")
    }()
    static let maxChars = 3000          // sent with every message, so it stays short (~750 tokens)

    /// When each fact was saved and in which chat (kept beside memory.md so that file stays plain and editable).
    struct Meta: Codable { var added: Date; var source: String? }
    static let metaURL = url.deletingLastPathComponent().appendingPathComponent("memory-meta.json")
    /// The chat a fact is being saved from (set by the chat before it runs a memory tool).
    @MainActor static var currentSource: String?

    static var meta: [String: Meta] {
        guard let d = try? Data(contentsOf: metaURL) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: Meta].self, from: d)) ?? [:]
    }
    private static func saveMeta(_ m: [String: Meta]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(m) { try? d.write(to: metaURL, options: .atomic) }
    }
    static func key(_ fact: String) -> String { fact.lowercased().trimmingCharacters(in: .whitespaces) }

    /// Facts with when and where they were saved (nil for facts from before dates were kept, or typed into the file).
    static var entries: [(fact: String, meta: Meta?)] { let m = meta; return facts.map { ($0, m[key($0)]) } }
    static var usedChars: Int { facts.joined(separator: "\n").count }

    /// Removes exactly these facts (from Settings).
    static func remove(exactly gone: [String]) throws {
        let keys = Set(gone.map(key))
        try save(facts.filter { !keys.contains(key($0)) })
    }

    static var facts: [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
    }

    private static func save(_ facts: [String]) throws {
        let body = "# What 23 remembers about you\n\nEdit freely: one fact per line, starting with \"- \".\n\n"
            + facts.map { "- " + $0 }.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor static func add(_ raw: String) throws -> String {
        let fact = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !fact.isEmpty else { throw FileTools.ToolError.invalid("There was nothing to remember.") }
        guard fact.count <= 300 else { throw FileTools.ToolError.invalid("That's too long to remember; keep it to one short fact.") }
        var all = facts
        if all.contains(where: { $0.lowercased() == fact.lowercased() }) { return fact }
        all.append(fact)
        guard all.joined(separator: "\n").count <= maxChars else {
            throw FileTools.ToolError.invalid("My memory is full. Ask the user to remove something first (menu bar → 23 → Edit Memory…).")
        }
        try save(all)
        var m = meta
        m[key(fact)] = Meta(added: Date(), source: currentSource)
        saveMeta(m)
        return fact
    }

    /// Removes facts containing `text`. Returns what was removed.
    static func remove(matching text: String) throws -> [String] {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        let all = facts
        let gone = all.filter { $0.lowercased().contains(t) }
        if !gone.isEmpty { try save(all.filter { !$0.lowercased().contains(t) }) }
        return gone
    }

    static func restore(_ lines: [String]) throws {
        try save(facts + lines.filter { l in !facts.contains(l) })
    }

    /// For the system prompt.
    static var promptBlock: String {
        let f = facts
        return f.isEmpty ? "" : "\n\nWhat you remember about the user (from earlier chats):\n" + f.map { "- " + $0 }.joined(separator: "\n")
    }
}
