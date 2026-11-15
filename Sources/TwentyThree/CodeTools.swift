import AppKit

/// Code tools: read, search, edit and write files anywhere (by PathPolicy), run commands in a macOS sandbox,
/// and hand a task to Claude Code — only when the user explicitly asks for it.
@MainActor
enum CodeTools {
    static let names: Set<String> = ["list_files", "read_file", "search_code", "edit_file", "write_file", "run_command", "hand_off_to_claude"]
    static let readOnly: Set<String> = ["list_files", "read_file", "search_code"]

    static let workspace: URL = {
        let u = FileTools.home.appendingPathComponent("Developer/23-workspace")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static let definitions: [[String: Any]] = [
        FileTools.tool("list_files", "List the files in a project folder (skips .git, node_modules and build folders).",
                       ["folder": "Folder, e.g. '~/Developer/myproject' (default: the 23 workspace)",
                        "depth": "Optional: how many levels deep, 1–4 (default 2)"], required: []),
        FileTools.tool("read_file", "Read a text file with line numbers. Long files: ask for a line range.",
                       ["path": "File path, e.g. '~/Developer/myproject/main.py'",
                        "start_line": "Optional first line (default 1)", "end_line": "Optional last line"], required: ["path"]),
        FileTools.tool("search_code", "Find exact text in the files of a folder. Returns file:line matches.",
                       ["text": "The exact text to find", "folder": "Folder to search (default: the 23 workspace)"], required: ["text"]),
        FileTools.tool("edit_file", "Change part of a file: old_text must appear exactly once and is replaced by new_text. Read the file first.",
                       ["path": "File path", "old_text": "The exact current text (include enough lines to be unique)",
                        "new_text": "The replacement text"], required: ["path", "old_text", "new_text"]),
        FileTools.tool("write_file", "Create a new file, or replace a whole file, with the given content.",
                       ["path": "File path, e.g. '~/Developer/23-workspace/hello.py'", "content": "The full file content"], required: ["path", "content"]),
        FileTools.tool("run_command", "Run a shell command (zsh) in a folder, in a sandbox: it can only change files in that folder, and has no internet unless internet is 'yes' (the user is asked).",
                       ["command": "The command, e.g. 'python3 hello.py' or 'npm test'",
                        "folder": "Folder to run in (default: the 23 workspace)",
                        "internet": "'yes' only if the command needs the internet (installs, downloads, git push), otherwise 'no'"], required: ["command"]),
        FileTools.tool("hand_off_to_claude", "Hand a coding task to Claude Code in a Terminal window. ONLY when the user explicitly asks for Claude to do it.",
                       ["task": "What Claude Code should do, in full", "folder": "The project folder"], required: ["task", "folder"]),
    ]

    enum CodeError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    struct Outcome { var text: String; var undo: FileTools.Undo? = nil; var diff: String = "" }

    /// Set by ChatModel for each request: did the user's own message ask for Claude?
    static var userAskedForClaude = false
    /// The default folder for this request (an agent's home folder), instead of the 23 workspace.
    static var folderOverride: URL?
    /// Streams command output into the activity card.
    static var onOutput: (String) -> Void = { _ in }

    // MARK: Approval

    private static func s(_ args: [String: Any], _ k: String) -> String { (args[k] as? String) ?? "" }

    private static func folder(_ args: [String: Any]) -> URL {
        let f = s(args, "folder")
        return f.isEmpty ? (folderOverride ?? workspace) : PathPolicy.resolve(f)
    }

    /// Commands that change things outside the project, install software, or are otherwise risky: ask first.
    private static let riskyCommands: [(String, String)] = [
        (#"\bsudo\b|\bsu\b"#, "it asks for administrator rights"),
        (#"\brm\s+(-[a-zA-Z]*[rRf]|--recursive|--force)"#, "it deletes files recursively or forcefully"),
        (#"\b(pip3?|uv|poetry|npm|pnpm|yarn|bun|brew|gem|cargo|go|composer|conda|mamba)\s+(install|i|add|get|upgrade|update)\b"#, "it installs or updates software packages"),
        (#"\bgit\s+(push|reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|restore\s|branch\s+-D|rebase|filter-branch|stash\s+(drop|clear))"#, "it pushes or throws away git history/changes"),
        (#"(curl|wget)[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|node|perl|ruby)\b"#, "it downloads a script and runs it straight away"),
        (#"\bxattr\b.*(-d|-c|-r).*quarantine|\bxattr\s+-c|\bspctl\b|\bcodesign\b.*--remove"#, "it removes macOS's download/malware protection from files"),
        (#"\b(chmod|chown|chflags)\b.*-R|\bchmod\b.*\+s"#, "it changes permissions in bulk"),
        (#"\b(kill|killall|pkill)\b"#, "it stops other programs"),
        (#"\b(launchctl|crontab)\b|LaunchAgents|LaunchDaemons"#, "it sets up things that run automatically"),
        (#"\bosascript\b|\bopen\s"#, "it controls or opens other apps"),
        (#"\b(shutdown|reboot|halt|diskutil|dd|mkfs|fdisk|newfs|tmutil|csrutil|nvram|pmset|systemsetup|networksetup|scutil)\b"#, "it changes disks or system settings"),
        (#"\bdefaults\s+(write|delete)\b"#, "it changes app or system preferences"),
        (#"\b(ssh|scp|sftp|rsync)\b"#, "it connects to another computer"),
    ]

    private static let iCloudCommand = try! NSRegularExpression(pattern:
        #"icloud|clouddocs|mobile ?documents|mobileme|cloudkit|\bbrctl\b|(^|[;&|(]\s*|\s)(bird|cloudd)\b|keychain|(^|[;&|(]\s*|/)security\s+(find|add|delete|dump|export|import|list|unlock|set|create|default|login|show|authorize|cms)|library/accounts|appleid|apple ?account|\bakd\b|findmy|searchparty|identityservices|accountsd|library/(messages|mail|calendars|reminders|photos)|addressbook|photos library"#,
        options: .caseInsensitive)

    /// Commands that would browse the web (open a browser or a web address, or remote-control a browser).
    /// Refused while web browsing is switched off in Settings, so the switch can't be worked around.
    static func browsesWeb(_ command: String) -> Bool {
        command.range(of: #"\bopen\b[^;&|]*(https?://|www\.|-a\s*["']?(google chrome|safari|firefox|arc|brave|microsoft edge|opera|chromium))|osascript[^;&|]*(chrome|safari|firefox|arc|brave|edge)|\b(lynx|w3m|links)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func touchesICloud(_ command: String) -> Bool {
        // Look at the command with shell escaping and quotes removed too ("Mobile\\ Documents", "'iCl''oud'").
        let plain = command.replacingOccurrences(of: #"[\\'"]"#, with: "", options: .regularExpression)
        return [command, plain].contains { iCloudCommand.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    static func commandReasons(_ command: String, folder: URL, internet: Bool) -> [String] {
        var reasons: [String] = []
        if internet { reasons.append("it needs the internet") }
        if case .ask(let why) = PathPolicy.check(folder, write: true) { reasons.append(why) }
        if folder.path == PathPolicy.home || folder.path == "/" { reasons.append("it can change files anywhere in \(folder.path == "/" ? "the whole disk" : "your home folder")") }
        for (pattern, why) in riskyCommands where command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            reasons.append(why)
        }
        if PathPolicy.isSecret(command) { reasons.append("it reads files that may hold secrets or keys") }
        return reasons
    }

    /// Why this call needs the user's OK (nil = it doesn't). iCloud and other hard refusals happen in `run`.
    static func approvalReason(_ name: String, _ args: [String: Any]) -> String? {
        switch name {
        case "read_file":
            if case .ask(let why) = PathPolicy.check(PathPolicy.resolve(s(args, "path")), write: false) { return why }
        case "edit_file", "write_file":
            if case .ask(let why) = PathPolicy.check(PathPolicy.resolve(s(args, "path")), write: true) { return why }
        case "run_command":
            // Browsing while it's switched off: no approval card at all, `run` refuses it straight away.
            if !Prefs.allowWeb && browsesWeb(s(args, "command")) { return nil }
            let r = commandReasons(s(args, "command"), folder: folder(args), internet: s(args, "internet").lowercased().hasPrefix("y"))
            return r.isEmpty ? nil : r.joined(separator: ", ")
        case "hand_off_to_claude":
            // Not asked for by the user: no approval card at all, `run` refuses it straight away.
            return userAskedForClaude ? "your task and code will be sent to Claude Code (Anthropic's cloud), outside this Mac" : nil
        default: break
        }
        return nil
    }

    static func preview(_ name: String, _ args: [String: Any]) -> String {
        let short = { (p: String) in p.replacingOccurrences(of: PathPolicy.home, with: "~") }
        switch name {
        case "list_files": return "List files in \(short(folder(args).path))"
        case "read_file": return "Read \(short(PathPolicy.resolve(s(args, "path")).path))"
        case "search_code": return "Search for “\(s(args, "text").prefix(60))” in \(short(folder(args).path))"
        case "edit_file": return "Edit \(short(PathPolicy.resolve(s(args, "path")).path))"
        case "write_file":
            let u = PathPolicy.resolve(s(args, "path"))
            return (FileManager.default.fileExists(atPath: u.path) ? "Replace " : "Create ") + short(u.path)
        case "run_command": return "$ \(s(args, "command").prefix(140))  (in \(short(folder(args).path)))"
        case "hand_off_to_claude": return "Hand off to Claude Code: “\(s(args, "task").prefix(120))”"
        default: return name
        }
    }

    // MARK: Running

    static func run(_ name: String, _ args: [String: Any]) async throws -> Outcome {
        switch name {
        case "list_files": return Outcome(text: try list(folder(args), depth: Int(s(args, "depth")) ?? 2))
        case "read_file": return Outcome(text: try read(PathPolicy.resolve(s(args, "path")), Int(s(args, "start_line")), Int(s(args, "end_line"))))
        case "search_code": return Outcome(text: try search(s(args, "text"), in: folder(args)))
        case "edit_file": return try await edit(PathPolicy.resolve(s(args, "path")), old: s(args, "old_text"), new: s(args, "new_text"))
        case "write_file": return try await write(PathPolicy.resolve(s(args, "path")), content: s(args, "content"))
        case "run_command":
            let approved = args["__approved"] as? Bool == true
            return Outcome(text: try await runCommand(s(args, "command"), in: folder(args),
                                                       internet: s(args, "internet").lowercased().hasPrefix("y"), approved: approved))
        case "hand_off_to_claude": return Outcome(text: try handOff(s(args, "task"), folder: folder(args)))
        default: throw CodeError.message("Unknown code tool \(name).")
        }
    }

    private static func guardPath(_ url: URL, write: Bool) throws {
        if case .deny(let why) = PathPolicy.check(url, write: write) { throw CodeError.message(why) }
    }

    private static let skipDirs: Set<String> = [".git", "node_modules", ".build", "build", "dist", ".venv", "venv", "__pycache__",
                                                 ".next", "DerivedData", "Pods", ".gradle", "target", ".cache", ".Trash"]

    private static func list(_ dir: URL, depth: Int) throws -> String {
        try guardPath(dir, write: false)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw CodeError.message("There's no folder at \(dir.path).") }
        var lines: [String] = []
        func walk(_ u: URL, _ level: Int) {
            guard lines.count < 300 else { return }
            let items = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") || [".env", ".gitignore"].contains($0.lastPathComponent) }
                .filter { !PathPolicy.isICloud($0.path) }
                .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
            for item in items {
                guard lines.count < 300 else { lines.append("… (more not shown)"); return }
                let dir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let indent = String(repeating: "  ", count: level)
                if dir {
                    let skip = skipDirs.contains(item.lastPathComponent)
                    lines.append(indent + item.lastPathComponent + "/" + (skip ? " (skipped)" : ""))
                    if !skip && level + 1 < min(max(depth, 1), 4) { walk(item, level + 1) }
                } else {
                    let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    lines.append(indent + item.lastPathComponent + "  (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
                }
            }
        }
        walk(dir, 0)
        return "\(dir.path)/\n" + (lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
    }

    private static func textContent(_ url: URL) throws -> String {
        try guardPath(url, write: false)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CodeError.message("There's no file at \(url.path).") }
        let data = try Data(contentsOf: url)
        guard data.count <= 5_000_000 else { throw CodeError.message("That file is over 5 MB; it's too big to read.") }
        guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CodeError.message("That isn't a text file.")
        }
        return text
    }

    private static func read(_ url: URL, _ start: Int?, _ end: Int?) throws -> String {
        let text = try textContent(url)
        let lines = text.components(separatedBy: "\n")
        let a = max(1, start ?? 1)
        var b = min(lines.count, end ?? lines.count)
        // Keep each read small enough for the model's memory.
        var out: [String] = []
        var chars = 0
        var i = a
        while i <= b {
            let line = "\(i)\t\(lines[i - 1])"
            if chars + line.count > 9000 { b = i - 1; break }
            out.append(line); chars += line.count + 1; i += 1
        }
        BrowserTools.pageTextThisRequest += "\n" + out.joined(separator: "\n")   // file text can't be pasted into websites unasked
        let more = b < lines.count ? "\n(lines \(a)–\(b) of \(lines.count); ask for start_line=\(b + 1) to continue)" : ""
        return "\(url.path) (\(lines.count) lines)\n" + out.joined(separator: "\n") + more
    }

    private static func search(_ text: String, in dir: URL) throws -> String {
        guard !text.isEmpty else { throw CodeError.message("Nothing to search for.") }
        try guardPath(dir, write: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-rnIF", "--max-count=20"] + skipDirs.map { "--exclude-dir=\($0)" } + ["--", text, dir.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
            .filter { !PathPolicy.isICloud(String($0)) }
            .map { String($0.prefix(220)).replacingOccurrences(of: dir.path + "/", with: "") }
        if lines.isEmpty { return "No matches for “\(text)” in \(dir.path)." }
        return "Matches for “\(text)” in \(dir.path) (file:line):\n" + lines.prefix(60).joined(separator: "\n")
            + (lines.count > 60 ? "\n… \(lines.count - 60) more" : "")
    }

    // MARK: Changing files (snapshotted, so Undo always works)

    private static let snapshots: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/23/snapshots")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private static func snapshot(_ url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let copy = snapshots.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// A small red/green view of a change: up to 2 lines of context, then removed and added lines.
    private static func diff(old: String, new: String, around line: Int, in fileLines: [String]) -> String {
        var out: [String] = []
        let before = fileLines[max(0, line - 3)..<max(0, line - 1)]
        out += before.map { "  " + $0 }
        out += old.components(separatedBy: "\n").prefix(12).map { "- " + $0 }
        out += new.components(separatedBy: "\n").prefix(12).map { "+ " + $0 }
        return "@@ line \(line)\n" + out.joined(separator: "\n")
    }

    private static func edit(_ url: URL, old: String, new: String) async throws -> Outcome {
        let (out, line) = try editCore(url, old: old, new: new)
        await showInEditor(url, line: line)
        return out
    }

    static func editCore(_ url: URL, old: String, new: String) throws -> (Outcome, Int) {
        try guardPath(url, write: true)
        guard !old.isEmpty else { throw CodeError.message("old_text is empty. To create a file, use write_file.") }
        let text = try textContent(url)
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { throw CodeError.message("old_text wasn't found in \(url.lastPathComponent). Read the file again and copy the text exactly.") }
        if count > 1 { throw CodeError.message("old_text appears \(count) times in \(url.lastPathComponent). Include more surrounding lines so it's unique.") }
        let line = text.components(separatedBy: old)[0].components(separatedBy: "\n").count
        let snap = try snapshot(url)
        try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
        let d = diff(old: old, new: new, around: line, in: text.components(separatedBy: "\n"))
        ActivityLog.add("edit", "\(url.path) at line \(line)")
        return (Outcome(text: "Edited \(url.path) at line \(line).", undo: .restoreFile(url, snapshot: snap), diff: d), line)
    }

    private static func write(_ url: URL, content: String) async throws -> Outcome {
        let out = try writeCore(url, content: content)
        await showInEditor(url, line: 1)
        return out
    }

    static func writeCore(_ url: URL, content: String) throws -> Outcome {
        try guardPath(url, write: true)
        guard content.utf8.count <= 1_000_000 else { throw CodeError.message("That's too much to write at once (1 MB max).") }
        if Downloads.isBlockedName(url.lastPathComponent) && (url.pathExtension == "app" || url.pathExtension == "pkg" || url.pathExtension == "dmg") {
            throw CodeError.message("I don't create app bundles or installers this way.")
        }
        let existed = FileManager.default.fileExists(atPath: url.path)
        let oldLines = existed ? (try? textContent(url))?.components(separatedBy: "\n").count ?? 0 : 0
        let snap = try snapshot(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let newLines = content.components(separatedBy: "\n")
        let d = (existed ? "@@ replaced \(oldLines) lines with \(newLines.count)\n" : "@@ new file, \(newLines.count) lines\n")
            + newLines.prefix(14).map { "+ " + $0 }.joined(separator: "\n") + (newLines.count > 14 ? "\n+ …" : "")
        ActivityLog.add(existed ? "replace file" : "create file", url.path)
        return Outcome(text: "\(existed ? "Replaced" : "Created") \(url.path) (\(newLines.count) lines).",
                       undo: .restoreFile(url, snapshot: snap), diff: d)
    }

    /// Opens the file in VS Code at the changed line and points the AI cursor at it (if visuals are on).
    private static func showInEditor(_ url: URL, line: Int) async {
        guard UserDefaults.standard.object(forKey: "showEditsInEditor") as? Bool ?? true else { return }
        let cli = URL(fileURLWithPath: "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
        guard FileManager.default.fileExists(atPath: cli.path) else { return }
        let p = Process()
        p.executableURL = cli
        p.arguments = ["--reuse-window", "--goto", "\(url.path):\(line)"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        // Wait until VS Code really shows the file (a cold start takes a few seconds).
        var frame: CGRect?
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let app = AX.app("com.microsoft.VSCode"),
               let win: AXUIElement = AX.attr(app, kAXFocusedWindowAttribute) ?? AX.attr(app, kAXMainWindowAttribute),
               let title: String = AX.attr(win, kAXTitleAttribute), title.contains(url.lastPathComponent) {
                frame = AX.frame(win); break
            }
        }
        guard let f = frame else { return }
        let target = CGRect(x: f.minX + f.width * 0.35, y: f.minY + f.height * 0.3, width: 40, height: 30)
        _ = try? await Visualizer.shared.point(at: target, label: "Edited \(url.lastPathComponent):\(line)") { () async throws -> Bool in true }
    }

    // MARK: Running commands in the sandbox

    private static var running: Process?

    /// The user's normal PATH (from an interactive login shell, where nvm/Homebrew set it up), read once.
    static let userPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "print -r -- \"__PATH__$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe(); p.standardInput = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if let line = out.split(separator: "\n").last(where: { $0.hasPrefix("__PATH__") }) { return String(line.dropFirst(8)) }
        return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    static func which(_ tool: String) -> String? {
        for dir in userPath.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func cancel() { if let p = running, p.isRunning { p.terminate() } }

    private static func runCommand(_ command: String, in dir: URL, internet: Bool, approved: Bool) async throws -> String {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { throw CodeError.message("The command was empty.") }
        if touchesICloud(cmd) { throw CodeError.message("That command touches iCloud / Apple Account data or the keychain, which I never do.") }
        if !Prefs.allowWeb && browsesWeb(cmd) {
            throw CodeError.message("Web browsing is switched off in 23's Settings, so I won't open a browser or web page another way.")
        }
        try guardPath(dir, write: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CodeError.message("There's no folder at \(dir.path).")
        }
        // Defence in depth: if something risky slipped past the approval step, ask now.
        let reasons = commandReasons(cmd, folder: dir, internet: internet)
        if !reasons.isEmpty && !approved {
            guard await BrowserTools.askUser("Run “\(cmd.prefix(120))” (asking because \(reasons.joined(separator: ", ")))") else {
                return "The user chose not to run that. Do not try again unless they ask."
            }
        }
        let lower = cmd.lowercased()
        let profile = PathPolicy.sandboxProfile(writeRoot: dir.resolvingSymlinksInPath().path, internet: internet,
                                                allowSecrets: PathPolicy.isSecret(cmd),
                                                allowAppControl: lower.contains("osascript") || lower.range(of: #"\bopen\s"#, options: .regularExpression) != nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, "/bin/zsh", "-c", cmd]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPath
        env["NO_COLOR"] = "1"; env["TERM"] = "dumb"; env["GIT_TERMINAL_PROMPT"] = "0"; env["PAGER"] = "cat"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let chunk = String(decoding: d, as: UTF8.self)
                .replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
            collector.append(chunk)
            Task { @MainActor in onOutput(collector.text) }
        }
        ActivityLog.add("run", "\(cmd)  [in \(dir.path)\(internet ? ", internet" : "")]")
        running = p
        let start = Date()
        try p.run()
        let timeout = 180.0
        while p.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Date().timeIntervalSince(start) > timeout { p.terminate(); collector.append("\n[stopped: took longer than \(Int(timeout)) s]") }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { collector.append(String(decoding: rest, as: UTF8.self)) }
        running = nil
        onOutput(collector.text)

        var out = collector.text
        if out.contains("Operation not permitted") || out.contains("deny(") {
            out += "\n[note: the sandbox blocked something. Files can only change inside \(dir.path)\(internet ? "" : ", and there is no internet (use internet='yes' if it's needed)").]"
        }
        let tail = out.count > 6000 ? "…" + out.suffix(6000) : out
        return "$ \(cmd)\n(exit code \(p.terminationStatus), \(String(format: "%.1f", Date().timeIntervalSince(start))) s)\n" + (tail.isEmpty ? "(no output)" : tail)
    }

    // MARK: Hand-off to Claude Code (explicit request only)

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func handOff(_ task: String, folder: URL) throws -> String {
        guard userAskedForClaude else {
            throw CodeError.message("Only the user can choose to bring in Claude, by asking for it in their message. Offer it instead of doing it.")
        }
        guard !task.trimmingCharacters(in: .whitespaces).isEmpty else { throw CodeError.message("The task was empty.") }
        try guardPath(folder, write: false)
        if PathPolicy.isICloud(folder.path) { throw CodeError.message("That folder is iCloud data, which I never touch.") }
        guard let claude = which("claude") else { throw CodeError.message("Claude Code isn't installed on this Mac.") }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/23/handoff")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("handoff-\(Int(Date().timeIntervalSince1970)).command")
        let body = """
        #!/bin/zsh
        export PATH=\(shellQuote(userPath))
        # Started by 23 because you asked for Claude Code. Claude Code asks for its own permissions as usual.
        cd \(shellQuote(folder.path)) || exit 1
        clear
        echo "23 → Claude Code in \(folder.path.replacingOccurrences(of: "\"", with: ""))"
        exec \(shellQuote(claude)) \(shellQuote(task))
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
        ActivityLog.add("hand-off", "Claude Code in \(folder.path): \(task)")
        return "Claude Code is starting in a Terminal window in \(folder.path) with that task. It works there with its own permission prompts; its results don't come back into this chat."
    }
}

/// Thread-safe text buffer for streamed command output (keeps the last 30k characters).
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) {
        lock.lock(); buffer += s
        if buffer.count > 30_000 { buffer = String(buffer.suffix(30_000)) }
        lock.unlock()
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}
