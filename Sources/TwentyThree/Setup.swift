import Foundation
import AppKit
import AVFoundation
import CryptoKit

/// First-run setup: what 23 needs, what is optional, and one-click installs from each project's official source.
/// Downloads are checked against known SHA-256 checksums before they are used. Nothing installs without a click.
@MainActor
final class Setup: ObservableObject {
    static let shared = Setup()

    enum Status: Equatable { case unknown, ok(String), missing, working(String), failed(String) }

    struct Item: Identifiable {
        let id: String
        let title: String
        let why: String
        let required: Bool
        let size: String
        var status: Status = .unknown
        var manual: String              // what to do by hand, shown when it can't (or shouldn't) install itself
        var link: String? = nil
    }

    @Published var items: [Item] = []
    @Published var log: [String: [String]] = [:]
    private var running: Process?

    static var brew: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static let ghidraVersion = "12.1.4"
    static let ghidraZip = "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip"
    static let ghidraSHA = "ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db"
    static let javaHome = "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"

    /// Downloads with the checksum each must match (whisper's from Hugging Face; Kokoro's pinned from a verified copy).
    static let files: [String: (url: String, sha: String, bytes: Int64)] = [
        "whisper": ("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
                    "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d", 487_614_201),
        "kokoro-model": ("https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx",
                         "6e742170d309016e5891a994e1ce1559c702a2ccd0075e67ef7157974f6406cb", 92_361_271),
        "kokoro-voices": ("https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
                          "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d", 28_214_398),
    ]

    /// A model that fits this Mac comfortably and can use tools (all from Hugging Face, through Ollama).
    static var recommendedModel: (name: String, label: String, gb: Double) {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        if ram >= 30 { return ("hf.co/unsloth/Qwen3-14B-GGUF:Q4_K_M", "Qwen3 14B", 9.0) }
        if ram >= 15 { return ("hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M", "Qwen3 8B", 5.0) }
        return ("hf.co/unsloth/Qwen3-4B-GGUF:Q4_K_M", "Qwen3 4B", 2.5)
    }

    private init() { buildList() }

    private func buildList() {
        let rec = Self.recommendedModel
        items = [
            Item(id: "ollama", title: "Ollama", why: "Runs AI models on this Mac. 23 talks to it.", required: true, size: "about 500 MB",
                 manual: "Download it from ollama.com and open it once.", link: "https://ollama.com/download"),
            Item(id: "model", title: "An AI model", why: "The brain. Suggested for this Mac: \(rec.label), which can use 23's tools. You can add others, including uncensored ones, in Settings › Model.",
                 required: true, size: String(format: "about %.0f GB", rec.gb),
                 manual: "Settings › Model › Add a model from Hugging Face."),
            Item(id: "homebrew", title: "Homebrew", why: "The standard Mac package manager. 23 uses it to install the optional parts below.", required: false, size: "about 300 MB",
                 manual: "Paste the install command from brew.sh into Terminal (it asks for your Mac password).", link: "https://brew.sh"),
            Item(id: "whisper", title: "Listening (whisper.cpp)", why: "Turns your voice into text, on this Mac.", required: false, size: "about 500 MB",
                 manual: "brew install whisper-cpp, then the ggml-small.en model.", link: "https://github.com/ggml-org/whisper.cpp"),
            Item(id: "kokoro", title: "Speaking (Kokoro)", why: "A natural voice for 23's replies, on this Mac. Without it, the macOS voice is used.", required: false, size: "about 250 MB",
                 manual: "brew install python@3.12, a virtual environment with kokoro-onnx 0.6.1, and the model files.", link: "https://github.com/thewh1teagle/kokoro-onnx"),
            Item(id: "claude", title: "Claude Code", why: "Optional: lets Claude look at pictures, videos and scans you attach (23 asks every time before sending), and review add-ons before you install them.", required: false, size: "small",
                 manual: "Install it from claude.com/claude-code, then run “claude” once in Terminal to sign in.", link: "https://claude.com/claude-code"),
            Item(id: "rea", title: "REA (reverse engineering)", why: "Optional add-on: inspect apps, binaries and archives.", required: false, size: "about 100 MB",
                 manual: "npm install -g rea-agents (needs Node: brew install node).", link: "https://github.com/morluto/rea"),
            Item(id: "ghidra", title: "Ghidra for REA", why: "Optional: lets REA decompile code. Free, open source (NSA); built for this Mac from its official release.", required: false, size: "about 1.2 GB with Java",
                 manual: "Needs Homebrew and REA first.", link: "https://github.com/NationalSecurityAgency/ghidra"),
            Item(id: "tailscale", title: "Tailscale", why: "Optional: use this 23 from your other Macs, privately, from anywhere.", required: false, size: "small",
                 manual: "Install Tailscale on each Mac and sign in with the same account.", link: "https://tailscale.com/download/mac"),
            Item(id: "access", title: "Permissions", why: "Accessibility (to show its cursor and use Chrome) and the microphone. macOS asks once.", required: false, size: "",
                 manual: "System Settings › Privacy & Security › Accessibility and Microphone."),
        ]
    }

    func index(_ id: String) -> Int? { items.firstIndex { $0.id == id } }
    private func set(_ id: String, _ s: Status) { if let i = index(id) { items[i].status = s } }
    private func note(_ id: String, _ line: String) { log[id, default: []].append(line); if (log[id]?.count ?? 0) > 200 { log[id]?.removeFirst() } }

    var essentialsReady: Bool { items.filter(\.required).allSatisfy { if case .ok = $0.status { true } else { false } } }

    // MARK: Checking

    func refresh() async {
        let list = try? await OllamaAdmin.installed()
        let ollamaUp = list != nil
        let installed = list ?? []
        let ollamaThere = FileManager.default.fileExists(atPath: "/Applications/Ollama.app") || CodeTools.which("ollama") != nil
        set("ollama", ollamaUp ? .ok("running") : ollamaThere ? .failed("installed but not running: open Ollama") : .missing)
        Self.adoptInstalledModelIfNeeded(installed)
        if let m = installed.first(where: { $0.shortName == Prefs.model || $0.name == Prefs.model }) {
            set("model", .ok(m.displayName + (m.canUseTools ? "" : " (can't use tools)")))
        } else { set("model", .missing) }
        set("homebrew", Self.brew != nil ? .ok("installed") : .missing)
        let v = Voice.shared
        set("whisper", FileManager.default.isExecutableFile(atPath: Voice.whisperCLI) && FileManager.default.fileExists(atPath: Voice.whisperModel.path) ? .ok("ready") : .missing)
        set("kokoro", v.kokoroInstalled ? .ok("ready") : .missing)
        set("claude", CodeTools.which("claude") != nil ? .ok("installed") : .missing)
        set("rea", CodeTools.which("rea") != nil ? .ok("installed") : .missing)
        set("ghidra", REAEngines.installed ? .ok("Ghidra \(Self.ghidraVersion)") : .missing)
        set("tailscale", Discovery.cli != nil ? .ok("installed") : .missing)
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        set("access", AX.isTrusted && mic == .authorized ? .ok("granted")
            : .failed([AX.isTrusted ? nil : "Accessibility", mic == .authorized ? nil : "Microphone"].compactMap { $0 }.joined(separator: " and ") + " not granted yet"))
    }

    /// Setups from before models were chosen explicitly: keep using the installed model that can use tools.
    static func adoptInstalledModelIfNeeded(_ installed: [InstalledModel]) {
        guard Prefs.model.isEmpty, let m = installed.first(where: \.canUseTools) ?? installed.first else { return }
        Prefs.model = m.shortName
        ActivityLog.add("setting", "model → \(m.shortName) (already installed)")
    }

    // MARK: Installing

    func install(_ id: String) {
        guard running == nil else { return }
        Task {
            do {
                switch id {
                case "ollama": try await installOllama()
                case "model": try await installModel()
                case "homebrew": openTerminal(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#, "Homebrew's official installer")
                case "whisper": try await installWhisper()
                case "kokoro": try await installKokoro()
                case "claude": NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
                case "rea": try await installREA()
                case "ghidra": try await installGhidra()
                case "tailscale": NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
                case "access":
                    AX.requestPermission()
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                default: break
                }
            } catch {
                set(id, .failed(error.localizedDescription))
                note(id, "failed: \(error.localizedDescription)")
                ActivityLog.add("setup failed", "\(id): \(error.localizedDescription)")
            }
            await refresh()
        }
    }

    func cancel() { running?.terminate() }

    private func needBrew() throws -> String {
        guard let b = Self.brew else { throw InstallError.message("This needs Homebrew first (above).") }
        return b
    }

    private func installOllama() async throws {
        if let brew = Self.brew {
            set("ollama", .working("Installing with Homebrew…"))
            try await run("ollama", brew, ["install", "--cask", "ollama-app"])
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ollama.app"), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            set("ollama", .working("Starting Ollama…"))
            for _ in 0..<30 { if (try? await OllamaAdmin.installed()) != nil { break }; try await Task.sleep(nanoseconds: 1_000_000_000) }
            ActivityLog.add("setup", "installed Ollama (Homebrew cask ollama-app)")
        } else {
            NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
        }
    }

    private func installModel() async throws {
        let rec = Self.recommendedModel
        set("model", .working("Downloading \(rec.label)…"))
        try await OllamaAdmin.pull(rec.name) { [weak self] p in
            guard p.total > 0 else { return }
            self?.set("model", .working(String(format: "Downloading %@: %.1f of %.1f GB", rec.label, Double(p.done) / 1e9, Double(p.total) / 1e9)))
        }
        Prefs.model = rec.name
        ActivityLog.add("setup", "downloaded and chose \(rec.name)")
    }

    private func installWhisper() async throws {
        let brew = try needBrew()
        if !FileManager.default.isExecutableFile(atPath: Voice.whisperCLI) {
            set("whisper", .working("Installing whisper.cpp with Homebrew…"))
            try await run("whisper", brew, ["install", "whisper-cpp"])
        }
        try await download("whisper", key: "whisper", to: Voice.whisperModel)
        ActivityLog.add("setup", "installed listening (whisper.cpp + ggml-small.en, checksum verified)")
    }

    private func installKokoro() async throws {
        let brew = try needBrew()
        let python = "/opt/homebrew/opt/python@3.12/bin/python3.12"
        if !FileManager.default.isExecutableFile(atPath: python) {
            set("kokoro", .working("Installing Python 3.12 with Homebrew…"))
            try await run("kokoro", brew, ["install", "python@3.12"])
        }
        let venv = Voice.support.appendingPathComponent("kokoro-venv")
        if !FileManager.default.fileExists(atPath: Voice.kokoroPython.path) {
            set("kokoro", .working("Preparing its Python environment…"))
            try await run("kokoro", python, ["-m", "venv", venv.path])
        }
        set("kokoro", .working("Installing kokoro-onnx 0.6.1…"))
        try await run("kokoro", venv.appendingPathComponent("bin/pip").path, ["install", "--disable-pip-version-check", "kokoro-onnx==0.6.1"])
        try await download("kokoro", key: "kokoro-model", to: Voice.support.appendingPathComponent("models/kokoro-v1.0.int8.onnx"))
        try await download("kokoro", key: "kokoro-voices", to: Voice.kokoroVoices)
        ActivityLog.add("setup", "installed speaking (Kokoro, checksums verified)")
    }

    private func installREA() async throws {
        var npm = CodeTools.which("npm")
        if npm == nil {
            let brew = try needBrew()
            set("rea", .working("Installing Node with Homebrew…"))
            try await run("rea", brew, ["install", "node"])
            npm = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        guard let npm else { throw InstallError.message("npm isn't available.") }
        set("rea", .working("Installing REA from npm…"))
        try await run("rea", npm, ["install", "-g", "rea-agents"])
        ActivityLog.add("setup", "installed REA (npm rea-agents)")
    }

    /// The same steps used on the first Mac: official 12.1.4 release (REA requires exactly this version), checksum
    /// verified, decompiler built for this Mac from the release's own sources, Java 21 from Homebrew.
    private func installGhidra() async throws {
        let brew = try needBrew()
        guard CodeTools.which("rea") != nil else { throw InstallError.message("Install REA first.") }
        set("ghidra", .working("Installing Java 21 and Gradle with Homebrew…"))
        try await run("ghidra", brew, ["install", "openjdk@21", "gradle"])
        let engines = AddonStore.root.appendingPathComponent("engines")
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
        let zip = engines.appendingPathComponent("ghidra.zip")
        try await download("ghidra", url: Self.ghidraZip, sha: Self.ghidraSHA, bytes: 569_649_598, to: zip)
        set("ghidra", .working("Unpacking…"))
        try await run("ghidra", "/usr/bin/ditto", ["-x", "-k", zip.path, engines.path])
        try? FileManager.default.removeItem(at: zip)
        let g = engines.appendingPathComponent("ghidra_\(Self.ghidraVersion)_PUBLIC")
        set("ghidra", .working("Building its decompiler for this Mac (a few minutes)…"))
        let gradle = ["/opt/homebrew/bin/gradle", "/usr/local/bin/gradle"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "gradle"
        try await run("ghidra", gradle, ["buildNatives", "--no-daemon", "-q"], cwd: g.appendingPathComponent("support/gradle"), env: ["JAVA_HOME": Self.javaHome])
        for m in ["Decompiler", "FileFormats"] {
            let from = g.appendingPathComponent("Ghidra/Features/\(m)/build/os/mac_arm_64")
            let to = g.appendingPathComponent("Ghidra/Features/\(m)/os/mac_arm_64")
            try? FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            for f in (try? FileManager.default.contentsOfDirectory(atPath: from.path)) ?? [] {
                try? FileManager.default.removeItem(at: to.appendingPathComponent(f))
                try FileManager.default.copyItem(at: from.appendingPathComponent(f), to: to.appendingPathComponent(f))
            }
        }
        AddonStore.shared.configureREAEngine()
        ActivityLog.add("setup", "installed Ghidra \(Self.ghidraVersion) (checksum verified, natives built here)")
    }

    // MARK: Helpers

    private func download(_ id: String, key: String, to dest: URL) async throws {
        guard let f = Self.files[key] else { return }
        try await download(id, url: f.url, sha: f.sha, bytes: f.bytes, to: dest)
    }

    /// Downloads with curl (progress shown), then checks the SHA-256. A file that doesn't match is deleted, never used.
    private func download(_ id: String, url: String, sha: String, bytes: Int64, to dest: URL) async throws {
        if FileManager.default.fileExists(atPath: dest.path), (try? Self.sha256(dest)) == sha { return }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        let name = dest.lastPathComponent
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                let have = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                self?.set(id, .working(String(format: "Downloading %@: %.0f of %.0f MB", name, Double(have) / 1e6, Double(bytes) / 1e6)))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { watcher.cancel() }
        try await run(id, "/usr/bin/curl", ["-fL", "--retry", "2", "-o", part.path, url])
        set(id, .working("Checking \(name)…"))
        let got = try Self.sha256(part)
        guard got == sha else {
            try? FileManager.default.removeItem(at: part)
            throw InstallError.message("\(name) didn't match its known checksum, so it was deleted and not used.")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
        note(id, "\(name): checksum OK")
    }

    /// Developer aid (`--setup-test <folder>`): one real download that must verify, and one that must be refused.
    func selfCheck(in dir: URL) async {
        let f = Self.files["kokoro-voices"]!
        do { try await download("test", url: f.url, sha: f.sha, bytes: f.bytes, to: dir.appendingPathComponent("voices.bin")); print("good download: verified") }
        catch { print("good download FAILED: \(error.localizedDescription)") }
        do { try await download("test", url: f.url, sha: String(repeating: "0", count: 64), bytes: f.bytes, to: dir.appendingPathComponent("bad.bin")); print("bad checksum: WRONGLY accepted") }
        catch { print("bad checksum: refused (\(error.localizedDescription)); file left behind: \(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad.bin").path) || FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad.bin.part").path))") }
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs one installer command (no shell in between), keeping its output for the log.
    private func run(_ id: String, _ exe: String, _ args: [String], cwd: URL? = nil, env extra: [String: String] = [:]) async throws {
        note(id, "$ " + ([exe] + args).joined(separator: " "))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + CodeTools.userPath
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in for l in text.split(separator: "\n") where !l.isEmpty { self?.note(id, String(l.prefix(300))) } }
        }
        try p.run()
        running = p
        defer { running = nil; out.fileHandleForReading.readabilityHandler = nil }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        guard p.terminationStatus == 0 else {
            throw InstallError.message("\(URL(fileURLWithPath: exe).lastPathComponent) stopped with an error. The log shows what it said.")
        }
    }

    /// For installers that need the user's password (Homebrew's): opens Terminal with the official command, for them to run.
    private func openTerminal(_ command: String, _ what: String) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("23-setup-\(UUID().uuidString.prefix(6)).command")
        let script = "#!/bin/zsh\necho '23 Setup: \(what). It will ask for your Mac password.'\necho\n\(command)\necho\necho 'Done. You can close this window and go back to 23.'\n"
        try? script.write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        NSWorkspace.shared.open(f)
        ActivityLog.add("setup", "opened Terminal for \(what)")
    }
}
