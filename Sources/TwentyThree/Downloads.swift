import Foundation

/// Downloads files for the user, safely:
///  • always approved by the user first (enforced by ChatModel);
///  • programs, installers, disk images and scripts are refused, by name AND by looking at the bytes;
///  • the file lands in ~/Downloads under a new name (never overwriting) with macOS's quarantine flag set;
///  • 23 has no tool to open or run anything, so a download can only ever be looked at by the user.
enum Downloads {
    static let maxBytes: Int64 = 500 * 1024 * 1024

    /// Extensions that run code or install things. Refused outright.
    static let blockedExtensions: Set<String> = [
        "app", "dmg", "pkg", "mpkg", "exe", "msi", "bat", "cmd", "com", "scr", "ps1", "vbs", "js", "jse", "wsf",
        "command", "tool", "sh", "bash", "zsh", "csh", "py", "pl", "rb", "php", "jar", "class", "scpt", "applescript",
        "workflow", "action", "terminal", "webloc", "inetloc", "fileloc", "dylib", "kext", "plugin", "bundle",
        "prefpane", "saver", "mobileconfig", "deb", "rpm", "apk", "iso", "img", "sparseimage", "sparsebundle", "dmgpart",
        "lnk", "reg", "hta", "cpl", "msc", "url", "desktop", "appimage", "run", "bin", "elf", "o", "so",
    ]

    enum DownloadError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    static func isBlockedName(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ ."))
        if n.contains(".app/") { return true }
        let ext = (n as NSString).pathExtension
        return !ext.isEmpty && blockedExtensions.contains(ext)
    }

    /// For zip files: refuse any that contain programs, installers or scripts.
    static func zipHidesProgram(_ file: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "something I couldn't inspect" }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return "something I couldn't inspect" }
        return out.split(separator: "\n").first { isBlockedName(String($0)) }.map { "\($0)" }
    }

    /// Looks at the first/last bytes for programs, scripts, installers and disk images.
    static func looksExecutable(_ file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 8)) ?? Data()
        let b = [UInt8](head)
        if b.count >= 2, b[0] == 0x23, b[1] == 0x21 { return "a script" }                          // #!
        if b.count >= 4 {
            let m = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
            if [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(m) { return "a Mac program" }
            if b[0] == 0x7F, b[1] == 0x45, b[2] == 0x4C, b[3] == 0x46 { return "a Linux program" }   // ELF
            if b[0] == 0x78, b[1] == 0x61, b[2] == 0x72, b[3] == 0x21 { return "an installer package" } // xar!
        }
        if b.count >= 2, b[0] == 0x4D, b[1] == 0x5A { return "a Windows program" }                   // MZ
        // Disk images end with a "koly" trailer.
        if let size = try? h.seekToEnd(), size >= 512 {
            try? h.seek(toOffset: size - 512)
            if let tail = try? h.read(upToCount: 4), tail == Data("koly".utf8) { return "a disk image" }
        }
        return nil
    }

    private static func uniqueDestination(for name: String) -> URL {
        let dir = FileTools.home.appendingPathComponent("Downloads")
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var url = dir.appendingPathComponent(clean)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Sets the same quarantine flag a browser sets, so Gatekeeper checks the file if it's ever opened.
    private static func quarantine(_ url: URL, from source: URL) {
        let value = String(format: "0081;%08x;23;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        // Finder's "Where from" expects a binary property list holding an array of strings.
        if let plist = try? PropertyListSerialization.data(fromPropertyList: [source.absoluteString], format: .binary, options: 0) {
            _ = plist.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0) }
        }
    }

    /// Downloads `url` into ~/Downloads. Returns where it went.
    @MainActor static func fetch(_ url: URL) async throws -> (file: URL, bytes: Int64) {
        if isBlockedName(url.lastPathComponent) {
            throw DownloadError.message("That's a program, installer or script (\(url.lastPathComponent)). I never download those.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        let (temp, response) = try await URLSession.shared.download(for: req)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.message("The website answered \(http.statusCode), so nothing was downloaded.")
        }
        // The server can rename the file (Content-Disposition), and can redirect elsewhere: check both again.
        if let final = response.url, final.host != url.host { _ = try BrowserTools.validate(final.absoluteString) }
        let name = response.suggestedFilename ?? url.lastPathComponent
        if isBlockedName(name) {
            throw DownloadError.message("The file turned out to be a program, installer or script (\(name)), so I deleted it.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
        guard size <= maxBytes else { throw DownloadError.message("That file is over 500 MB, so I didn't keep it.") }
        if let kind = looksExecutable(temp) {
            throw DownloadError.message("The file is really \(kind), even though it's named \(name). I deleted it.")
        }
        if (name as NSString).pathExtension.lowercased() == "zip", let bad = zipHidesProgram(temp) {
            throw DownloadError.message("That zip contains \(bad), which could run code, so I deleted it.")
        }
        let dest = uniqueDestination(for: name.isEmpty ? "download" : name)
        try FileManager.default.moveItem(at: temp, to: dest)
        // Downloaded files must never be runnable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        quarantine(dest, from: url)
        return (dest, size)
    }
}
