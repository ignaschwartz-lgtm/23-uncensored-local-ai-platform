import Foundation

/// The file actions 23 is allowed to perform. All paths are confined to the allowed folders;
/// nothing is ever overwritten and deletion always goes to the Trash.
struct FileTools {
    static let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    static let names: Set<String> = ["list_folder", "move_file", "copy_file", "rename_file", "create_folder", "trash_file"]
    static let allowedRoots = ["Desktop", "Downloads", "Documents"].map { home.appendingPathComponent($0).standardizedFileURL }

    enum ToolError: LocalizedError {
        case outsideAllowed(String), notFound(String), alreadyExists(String), ambiguous(String, [String]), invalid(String)
        var errorDescription: String? {
            switch self {
            case .outsideAllowed(let p): return "'\(p)' is outside the folders I'm allowed to touch (Desktop, Downloads, Documents)."
            case .notFound(let p): return "I couldn't find '\(p)'."
            case .alreadyExists(let p): return "'\(p)' already exists there, and I never overwrite files."
            case .ambiguous(let p, let c): return "'\(p)' matches several items: \(c.joined(separator: ", ")). Which one?"
            case .invalid(let m): return m
            }
        }
    }

    /// What an executed action needs to be undone.
    enum Undo: Codable {
        case move(from: URL, to: URL)        // move `to` back to `from`
        case trashCopy(URL)                  // a copy was made; undo = send it to the Trash
        case removeFolder(URL)               // remove the (still empty) folder we created
        case restoreFromTrash(original: URL, trashed: URL)
        case restoreFile(URL, snapshot: URL?) // put the file back as it was (nil = it was new: move it to the Trash)
        case memoryAdded(String)             // remove the fact again
        case memoryRemoved([String])         // put the facts back
        case chatMemoryAdded(String)         // handled by the chat itself
        case forgot(chat: [String], global: [String])   // handled by the chat itself
    }

    // MARK: Tool definitions sent to the model

    static let definitions: [[String: Any]] = [
        tool("list_folder", "List the files and folders inside a folder. Use this first when you are not sure of exact file names.",
             ["folder": "Folder to list, e.g. 'Desktop', 'Downloads', 'Documents' or 'Documents/Invoices'"], required: ["folder"]),
        tool("move_file", "Move a file or folder into another folder. The name stays the same.",
             ["source": "Path of the item to move, e.g. 'Desktop/report.pdf'",
              "destination_folder": "Folder to move it into, e.g. 'Downloads'"], required: ["source", "destination_folder"]),
        tool("copy_file", "Copy a file or folder into another folder.",
             ["source": "Path of the item to copy, e.g. 'Desktop/report.pdf'",
              "destination_folder": "Folder to copy it into, e.g. 'Documents'"], required: ["source", "destination_folder"]),
        tool("rename_file", "Rename a file or folder, keeping it in the same folder.",
             ["path": "Path of the item, e.g. 'Desktop/IMG_001.png'",
              "new_name": "The new name including extension, e.g. 'holiday.png'"], required: ["path", "new_name"]),
        tool("create_folder", "Create a new, empty folder.",
             ["path": "Path of the new folder, e.g. 'Documents/Receipts'"], required: ["path"]),
        tool("trash_file", "Move a file or folder to the Trash. The user must approve this first.",
             ["path": "Path of the item, e.g. 'Downloads/old.zip'"], required: ["path"]),
    ]

    static func tool(_ name: String, _ desc: String, _ params: [String: String], required: [String]) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": desc,
                      "parameters": ["type": "object",
                                     "properties": params.mapValues { ["type": "string", "description": $0] },
                                     "required": required]]]
    }

    static func needsApproval(_ name: String, _ args: [String: Any] = [:]) -> Bool { approvalReason(name, args) != nil }

    // MARK: Path handling

    /// Turns "Desktop/x", "~/Desktop/x" or "/abs/x" into a URL. Anywhere on the Mac is allowed except
    /// iCloud / Apple Account data, which is refused here (symlinks included). Risky places ask, via approvalReason.
    static func resolve(_ raw: String) throws -> URL {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !p.isEmpty else { throw ToolError.invalid("An empty path was given.") }
        // Accept case-insensitive root names such as "desktop/…"
        var comps = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if !p.hasPrefix("/") && !p.hasPrefix("~"), let first = comps.first,
           let root = ["Desktop", "Downloads", "Documents"].first(where: { $0.lowercased() == first.lowercased() }) {
            comps[0] = root
            p = comps.joined(separator: "/")
        }
        let url = PathPolicy.resolve(p)
        if case .deny(let why) = PathPolicy.check(url, write: false) { throw ToolError.invalid(why) }
        return url
    }

    /// Big top-level folders (your home, Desktop, Documents, Library, /Applications, …): moving, renaming or trashing them asks.
    static func isTopLevel(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/" || path == PathPolicy.home { return true }
        if url.deletingLastPathComponent().path == PathPolicy.home { return !url.lastPathComponent.hasPrefix(".") }
        return path.split(separator: "/").count <= 1
    }

    /// Why a file action needs the user's OK first (nil = it doesn't). iCloud is refused outright in `resolve`.
    static func approvalReason(_ name: String, _ args: [String: Any]) -> String? {
        let s = { (k: String) in (args[k] as? String) ?? "" }
        func url(_ k: String) -> URL? { try? existing(s(k)) }
        func writeWhy(_ u: URL?) -> String? {
            guard let u else { return nil }
            if case .ask(let why) = PathPolicy.check(u, write: true) { return why }
            return nil
        }
        switch name {
        case "trash_file":
            if let u = url("path"), isTopLevel(u) { return "it deletes a whole top-level folder" }
            return "deleting always needs your OK"
        case "list_folder":
            if let u = url("folder"), case .ask(let why) = PathPolicy.check(u, write: false) { return why }
            return nil
        case "move_file", "rename_file":
            let src = url(name == "move_file" ? "source" : "path")
            if let u = src, isTopLevel(u) { return "it moves or renames a whole top-level folder" }
            return writeWhy(src) ?? (name == "move_file" ? writeWhy(try? resolve(s("destination_folder"))) : nil)
        case "copy_file":
            return writeWhy(try? resolve(s("destination_folder")))
        case "create_folder":
            return writeWhy(try? resolve(s("path")))
        default:
            return nil
        }
    }

    /// Finds an existing item; if the exact name is missing, tries a forgiving match inside the same folder.
    static func existing(_ raw: String) throws -> URL {
        let url = try resolve(raw)
        if FileManager.default.fileExists(atPath: url.path) { return canonical(url) }
        let parent = canonical(url.deletingLastPathComponent())
        let wanted = url.lastPathComponent.lowercased()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        let exact = items.filter { $0.lowercased() == wanted }
        if exact.count == 1 { return parent.appendingPathComponent(exact[0]) }
        let fuzzy = items.filter { !$0.hasPrefix(".") && ($0.lowercased().hasPrefix(wanted) || $0.lowercased().contains(wanted)) }
        if fuzzy.count == 1 { return parent.appendingPathComponent(fuzzy[0]) }
        if fuzzy.count > 1 { throw ToolError.ambiguous(raw, fuzzy) }
        throw ToolError.notFound(raw)
    }

    /// The disk is case-insensitive, so "report.PDF" finds "Report.pdf". Return the item's real spelling.
    static func canonical(_ url: URL) -> URL {
        let std = url.standardizedFileURL
        guard std.path != "/" else { return std }
        let parent = canonical(std.deletingLastPathComponent())
        let name = std.lastPathComponent
        let items = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        let real = items.first(where: { $0 == name }) ?? items.first(where: { $0.lowercased() == name.lowercased() }) ?? name
        return parent.appendingPathComponent(real)
    }

    static func display(_ url: URL) -> String {
        url.path.replacingOccurrences(of: home.path + "/", with: "")
    }

    // MARK: Execution

    struct Result {
        var summary: String          // shown to the model and in the activity card
        var undo: Undo?
        var paths: (from: URL?, to: URL?) = (nil, nil)
    }

    static func run(_ name: String, _ args: [String: Any]) throws -> Result {
        func arg(_ k: String) throws -> String {
            guard let v = args[k] as? String, !v.isEmpty else { throw ToolError.invalid("Missing '\(k)'.") }
            return v
        }
        let fm = FileManager.default
        switch name {
        case "list_folder":
            let folder = try existing(try arg("folder"))
            let items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if items.isEmpty { return Result(summary: "\(display(folder)) is empty.") }
            let lines = items.prefix(200).map { u -> String in
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDir ? "📁 \(u.lastPathComponent)/" : u.lastPathComponent
            }
            return Result(summary: "\(display(folder)) contains \(items.count) item(s):\n" + lines.joined(separator: "\n"))

        case "move_file", "copy_file":
            let src = try existing(try arg("source"))
            let destFolder = canonical(try resolve(try arg("destination_folder")))
            if case .deny(let why) = PathPolicy.check(destFolder.appendingPathComponent(src.lastPathComponent), write: true) { throw ToolError.invalid(why) }
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: destFolder.path, isDirectory: &isDir) {
                // Allow a forgiving match for the destination folder name as well.
                let matched = try existing(try arg("destination_folder"))
                guard fm.fileExists(atPath: matched.path, isDirectory: &isDir), isDir.boolValue else { throw ToolError.notFound(display(destFolder)) }
                return try run(name, ["source": src.path, "destination_folder": matched.path])
            }
            guard isDir.boolValue else { throw ToolError.invalid("'\(display(destFolder))' is a file, not a folder.") }
            let dest = destFolder.appendingPathComponent(src.lastPathComponent)
            if dest.path == src.path { return Result(summary: "\(display(src)) is already in \(display(destFolder)).") }
            if destFolder.path.hasPrefix(src.path + "/") { throw ToolError.invalid("I can't put a folder inside itself.") }
            guard !fm.fileExists(atPath: dest.path) else { throw ToolError.alreadyExists(display(dest)) }
            if name == "move_file" {
                try fm.moveItem(at: src, to: dest)
                return Result(summary: "Moved \(display(src)) → \(display(destFolder))/", undo: .move(from: src, to: dest), paths: (src, dest))
            } else {
                try fm.copyItem(at: src, to: dest)
                return Result(summary: "Copied \(display(src)) → \(display(destFolder))/", undo: .trashCopy(dest), paths: (src, dest))
            }

        case "rename_file":
            let src = try existing(try arg("path"))
            let newName = try arg("new_name")
            guard !newName.contains("/"), newName != ".", newName != ".." else { throw ToolError.invalid("A name can't contain '/'.") }
            // Never turn a document into something that looks runnable (e.g. "invoice.pdf" → "invoice.command").
            if Downloads.isBlockedName(newName) && !Downloads.isBlockedName(src.lastPathComponent) {
                throw ToolError.invalid("I won't give a file a program or script extension (.\((newName as NSString).pathExtension)).")
            }
            let dest = src.deletingLastPathComponent().appendingPathComponent(newName)
            guard !fm.fileExists(atPath: dest.path) else { throw ToolError.alreadyExists(display(dest)) }
            try fm.moveItem(at: src, to: dest)
            return Result(summary: "Renamed \(display(src)) → \(newName)", undo: .move(from: src, to: dest), paths: (src, dest))

        case "create_folder":
            let url = try resolve(try arg("path"))
            guard !fm.fileExists(atPath: url.path) else { throw ToolError.alreadyExists(display(url)) }
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return Result(summary: "Created folder \(display(url))/", undo: .removeFolder(url), paths: (nil, url))

        case "trash_file":
            let url = try existing(try arg("path"))
            var trashed: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashed)
            let undo: Undo? = (trashed as URL?).map { .restoreFromTrash(original: url, trashed: $0) }
            return Result(summary: "Moved \(display(url)) to the Trash", undo: undo, paths: (url, trashed as URL?))

        default:
            throw ToolError.invalid("Unknown tool '\(name)'.")
        }
    }

    /// For the approval card: a human description of what a tool call would do, without doing it.
    static func preview(_ name: String, _ args: [String: Any]) -> String {
        let s = { (k: String) in (args[k] as? String) ?? "?" }
        switch name {
        case "list_folder": return "Look inside \(s("folder"))"
        case "move_file": return "Move \(s("source")) → \(s("destination_folder"))"
        case "copy_file": return "Copy \(s("source")) → \(s("destination_folder"))"
        case "rename_file": return "Rename \(s("path")) → \(s("new_name"))"
        case "create_folder": return "Create folder \(s("path"))"
        case "trash_file": return "Move \(s("path")) to the Trash"
        default: return name
        }
    }

    static func undo(_ u: Undo) throws -> String {
        let fm = FileManager.default
        switch u {
        case .move(let from, let to):
            guard !fm.fileExists(atPath: from.path) else { throw ToolError.alreadyExists(display(from)) }
            try fm.moveItem(at: to, to: from)
            return "Put \(from.lastPathComponent) back in \(display(from.deletingLastPathComponent()))"
        case .trashCopy(let url):
            try fm.trashItem(at: url, resultingItemURL: nil)
            return "Removed the copy (it's in the Trash)"
        case .removeFolder(let url):
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            guard contents.filter({ !$0.hasPrefix(".") }).isEmpty else { throw ToolError.invalid("The folder isn't empty any more, so I left it.") }
            try fm.removeItem(at: url)
            return "Removed the folder"
        case .restoreFile(let url, let snap):
            if let snap {
                if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: snap) }
                else { try fm.moveItem(at: snap, to: url) }
                return "Put \(url.lastPathComponent) back as it was"
            }
            try fm.trashItem(at: url, resultingItemURL: nil)
            return "Removed the new file \(url.lastPathComponent) (it's in the Trash)"
        case .chatMemoryAdded, .forgot:
            throw ToolError.invalid("This is undone by its chat.")
        case .memoryAdded(let fact):
            _ = try Memory.remove(matching: fact)
            return "Removed “\(fact)” from memory"
        case .memoryRemoved(let facts):
            try Memory.restore(facts)
            return "Put \(facts.count == 1 ? "it" : "them") back in memory"
        case .restoreFromTrash(let original, let trashed):
            guard !fm.fileExists(atPath: original.path) else { throw ToolError.alreadyExists(display(original)) }
            try fm.moveItem(at: trashed, to: original)
            return "Restored \(original.lastPathComponent) from the Trash"
        }
    }
}
