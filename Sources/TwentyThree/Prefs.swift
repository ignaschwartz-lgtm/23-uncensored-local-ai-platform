import Foundation

/// The user's settings. Ability switches are enforced in code: a switched-off ability is not offered to the
/// model at all, and is refused if the model asks for it anyway.
enum Prefs {
    private static let d = UserDefaults.standard

    private static func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }

    // What 23 may do
    static var allowFiles: Bool { bool(Key.allowFiles, true) }
    static var allowWeb: Bool { bool(Key.allowWeb, true) }
    static var allowWebTyping: Bool { bool(Key.allowWebTyping, true) }
    static var allowDownloads: Bool { bool(Key.allowDownloads, true) }
    static var allowCode: Bool { bool(Key.allowCode, true) }
    static var allowCommands: Bool { bool(Key.allowCommands, true) }
    static var allowHandOff: Bool { bool(Key.allowHandOff, true) }
    static var allowMemory: Bool { bool(Key.allowMemory, true) }
    static var allowAddons: Bool { bool(Key.allowAddons, true) }

    // How it behaves
    static var thinkByDefault: Bool { bool(Key.thinkByDefault, false) }
    static var customInstructions: String { d.string(forKey: Key.customInstructions) ?? "" }
    static var model: String {
        get { d.string(forKey: Key.model) ?? "" }          // "" until one is chosen (Settings › Setup or Model)
        set { d.set(newValue, forKey: Key.model) }
    }
    static var lastSpeed: Double {
        get { d.double(forKey: Key.lastSpeed) }
        set { d.set(newValue, forKey: Key.lastSpeed) }
    }

    enum Key {
        static let allowFiles = "allowFiles", allowWeb = "allowWeb", allowWebTyping = "allowWebTyping"
        static let allowDownloads = "allowDownloads", allowCode = "allowCode", allowCommands = "allowCommands"
        static let allowHandOff = "allowHandOff", allowMemory = "allowMemory", allowAddons = "allowAddons"
        static let thinkByDefault = "thinkByDefault", customInstructions = "customInstructions"
        static let model = "model", lastSpeed = "lastTokensPerSec"
        static let showActions = "showActions", showEditsInEditor = "showEditsInEditor"
    }

    /// Is this tool switched on in Settings?
    @MainActor static func allows(_ tool: String) -> Bool {
        if FileTools.names.contains(tool) { return allowFiles }
        if MemoryTools.names.contains(tool) { return allowMemory }
        if BrowserTools.names.contains(tool) {
            guard allowWeb else { return false }
            if tool == "type_text" { return allowWebTyping }
            if tool == "download_file" { return allowDownloads }
            return true
        }
        if AddonTools.names.contains(tool) { return allowAddons }
        if CodeTools.names.contains(tool) {
            guard allowCode else { return false }
            if tool == "run_command" { return allowCommands }
            if tool == "hand_off_to_claude" { return allowHandOff }
            return true
        }
        return false
    }

    /// The tool definitions to offer the model right now.
    @MainActor static var activeTools: [[String: Any]] {
        (FileTools.definitions + BrowserTools.definitions + MemoryTools.definitions + CodeTools.definitions + AddonTools.definitions).filter {
            guard let f = $0["function"] as? [String: Any], let name = f["name"] as? String else { return false }
            return allows(name)
        }
    }

    /// Plain-English list of what's switched off, for the system prompt.
    static var disabledSummary: String {
        var off: [String] = []
        if !allowFiles { off.append("file actions") }
        if !allowWeb { off.append("web browsing") } else {
            if !allowWebTyping { off.append("typing into web pages") }
            if !allowDownloads { off.append("downloads") }
        }
        if !allowCode { off.append("code tools") } else {
            if !allowCommands { off.append("running commands") }
            if !allowHandOff { off.append("handing off to Claude") }
        }
        if !allowMemory { off.append("saving memories") }
        if !allowAddons { off.append("add-on tools") }
        return off.joined(separator: ", ")
    }
}
