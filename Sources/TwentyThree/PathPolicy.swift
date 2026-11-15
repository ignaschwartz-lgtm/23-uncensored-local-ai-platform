import Foundation

/// Where the code tools may read and write. The user's rule: freedom everywhere, ask before anything dangerous,
/// and NEVER anything to do with the iCloud / Apple Account — that is refused in code and also written into
/// the OS sandbox of every command 23 runs, so not even a script can reach it.
enum PathPolicy {
    enum Verdict: Equatable {
        case free
        case ask(String)
        case deny(String)
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    /// Folders that belong to the iCloud / Apple Account or hold iCloud-synced data. Never read, never written.
    static let iCloudRoots: [String] = [
        "Library/Mobile Documents", "Library/Application Support/CloudDocs", "Library/Application Support/iCloud",
        "Library/Accounts", "Library/Keychains", "Library/IdentityServices", "Library/Messages", "Library/Mail",
        "Library/Calendars", "Library/Reminders", "Library/Photos", "Library/Application Support/AddressBook",
        "Library/Group Containers/group.com.apple.notes", "Library/Containers/com.apple.Notes",
        "Library/Group Containers/group.com.apple.reminders", "Library/Containers/com.apple.reminders",
        "Library/Containers/com.apple.CloudDocs.MobileDocumentsFileProvider",
        "Pictures/Photos Library.photoslibrary",
    ].map { home + "/" + $0 } + ["/Library/Keychains", "/private/var/db/accountsd"]

    /// Names that mark iCloud / Apple Account things wherever they are.
    static let iCloudWords = ["icloud", "clouddocs", "mobile documents", "mobileme", "cloudkit", "com.apple.bird",
                              "cloudd", "findmy", "searchparty", "com.apple.akd", "appleaccount", "apple account",
                              "appleid", "keychain", "identityservices", "accountsd"]

    static func isICloud(_ path: String) -> Bool {
        let p = path.lowercased()
        if iCloudRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return iCloudWords.contains { p.contains($0) }
    }

    /// Secrets: reading them asks.
    private static let secretPatterns = try! NSRegularExpression(pattern:
        #"(^|/)(\.ssh|\.gnupg|\.aws|\.azure|\.kube|\.docker)(/|$)|(^|/)\.env(\.[^/]*)?$|(^|/)\.(netrc|npmrc|pypirc)$|\.(pem|key|p12|pfx|keystore|jks)$|(^|/)id_(rsa|ed25519|ecdsa|dsa)|credentials|secrets?\.(json|ya?ml|toml)$|(^|/)\.config/gh/"#,
        options: .caseInsensitive)

    static func isSecret(_ path: String) -> Bool {
        secretPatterns.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// 23's own code, app, settings, memory and logs: changing them asks (so 23 can't quietly loosen its own rules).
    static let ownPaths = [home + "/Developer/23", "/Applications/23.app", home + "/Library/Application Support/23",
                           home + "/Library/Logs/23.log", home + "/Library/Logs/23-activity.log",
                           home + "/Library/Preferences/local.twentythree.plist"]

    static func isOwn(_ path: String) -> Bool { ownPaths.contains { path == $0 || path.hasPrefix($0 + "/") } }

    /// Turns "~/x", "Developer/x" (relative to home) or "/abs/x" into a clean absolute path.
    static func resolve(_ raw: String) -> URL {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + "/" + p.dropFirst(2) }
        else if !p.hasPrefix("/") { p = home + "/" + p }
        return URL(fileURLWithPath: p).standardizedFileURL
    }

    /// The decision for reading or writing `url`. Symlinks are followed, so a link can't sneak around a rule.
    /// Follows symlinks even when the last parts don't exist yet: resolves the deepest existing folder,
    /// then puts the rest back on.
    static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in rest { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL.path
    }

    static func check(_ url: URL, write: Bool) -> Verdict {
        let path = url.standardizedFileURL.path
        let real = realPath(url)
        for p in [path, real] where isICloud(p) {
            return .deny("That's part of your iCloud / Apple Account data, which I never touch.")
        }
        if [path, real].contains(where: isSecret) { return .ask(write ? "it changes a file holding secrets or keys" : "it reads a file that may hold secrets or keys") }
        guard write else { return .free }
        if [path, real].contains(where: isOwn) { return .ask("it changes 23's own code or settings") }
        let inHome = { (p: String) in p == home || p.hasPrefix(home + "/") }
        if !inHome(real) || !inHome(path) { return .ask("it writes outside your home folder") }
        let rel = String(real.dropFirst(home.count))
        if rel.hasPrefix("/Library/") || rel == "/Library" { return .ask("it writes inside ~/Library (app and system settings)") }
        if rel.hasPrefix("/.ollama") { return .ask("it changes Ollama's models or settings") }
        if rel.range(of: #"^/\.[^/]+$"#, options: .regularExpression) != nil { return .ask("it changes a hidden settings file in your home folder") }
        if rel.hasPrefix("/.config") || rel.hasPrefix("/.local/bin") { return .ask("it changes app settings or command-line tools") }
        return .free
    }

    // MARK: Sandbox for running commands

    /// A POSIX-regex alternative matching `word` in any letter case (Seatbelt regexes have no "ignore case").
    private static func anyCase(_ word: String) -> String {
        word.map { ch -> String in
            let l = String(ch).lowercased(), u = String(ch).uppercased()
            if l == u { return NSRegularExpression.escapedPattern(for: String(ch)).replacingOccurrences(of: " ", with: "[ ]") }
            return "[\(l)\(u)]"
        }.joined()
    }

    private static func sbString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The Seatbelt profile for one command: writes only in `writeRoot` (plus temp and caches), network only if
    /// approved, no Apple Events / app launching (ways to escape a sandbox), and iCloud always unreachable.
    static func sandboxProfile(writeRoot: String, internet: Bool, allowSecrets: Bool, allowAppControl: Bool) -> String {
        var p = "(version 1)\n(allow default)\n"
        if !internet {
            p += "(deny network*)\n"
            p += "(allow network* (remote unix-socket))\n"     // local IPC some tools need; no internet, no localhost TCP
        }
        p += "(deny file-write*)\n"
        let writable = [writeRoot, "/private/tmp", "/private/var/folders", home + "/Library/Caches", home + "/.cache", home + "/.npm"]
        p += "(allow file-write* " + writable.map { "(subpath \(sbString($0)))" }.joined(separator: " ")
            + " (literal \"/dev/null\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/fd/\"))\n"
        if !allowAppControl {
            p += "(deny appleevent-send)\n(deny lsopen)\n"
            p += "(deny process-exec (literal \"/usr/bin/osascript\") (literal \"/usr/bin/open\") (literal \"/usr/bin/sudo\") (literal \"/usr/bin/su\"))\n"
        }
        if !allowSecrets {
            let secretDirs = [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config/gh"].map { home + "/" + $0 }
            p += "(deny file-read* " + secretDirs.map { "(subpath \(sbString($0)))" }.joined(separator: " ") + ")\n"
        }
        // Last, so nothing above can re-allow it: iCloud / Apple Account, by folder and by name, read and write.
        p += "(deny file-read* file-write* " + iCloudRoots.map { "(subpath \(sbString($0)))" }.joined(separator: " ") + ")\n"
        // Name rules apply to the user's data, not to macOS's own frameworks (e.g. CloudKit.framework), which
        // ordinary programs load.
        let dataRoots = "^(" + NSRegularExpression.escapedPattern(for: home) + "|/private/var/db)/.*"
        p += "(deny file-read* file-write* " + iCloudWords.map { "(regex #\"\(dataRoots)\(anyCase($0))\")" }.joined(separator: " ") + ")\n"
        p += "(deny process-exec (literal \"/usr/bin/security\") (literal \"/usr/bin/brctl\") (literal \"/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Support/bird\"))\n"
        return p
    }
}
