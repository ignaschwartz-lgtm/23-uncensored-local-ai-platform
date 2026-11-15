import Foundation
import Metal

// MARK: - Models installed in Ollama

/// One model Ollama has on disk.
struct InstalledModel: Identifiable, Equatable {
    var id: String { name }
    let name: String               // as Ollama knows it, e.g. "defiant-fable:latest" or "hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M"
    let bytes: Int64
    let family: String
    let parameters: String
    let quant: String
    let modified: Date?
    var capabilities: [String] = []    // tools, vision, thinking, completion…

    /// The short name 23 shows and stores (no ":latest").
    var shortName: String { name.hasSuffix(":latest") ? String(name.dropLast(7)) : name }
    /// A friendlier label for Hugging Face downloads: "Qwen3-8B · Q4_K_M".
    var displayName: String {
        guard shortName.hasPrefix("hf.co/") else { return shortName }
        let rest = shortName.dropFirst(6)
        let repo = rest.split(separator: ":").first.map(String.init) ?? String(rest)
        let tag = rest.split(separator: ":").dropFirst().first.map(String.init)
        let base = (repo.split(separator: "/").last.map(String.init) ?? repo).replacingOccurrences(of: "-GGUF", with: "").replacingOccurrences(of: "-gguf", with: "")
        return tag.map { "\(base) · \($0)" } ?? base
    }
    var canUseTools: Bool { capabilities.contains("tools") }
    var canSee: Bool { capabilities.contains("vision") }
    var canThink: Bool { capabilities.contains("thinking") }
}

/// Talks to the local Ollama server for listing, downloading, switching and deleting models.
/// Only the Settings page calls this: the chat model has no tool that can download or delete models.
enum OllamaAdmin {
    static let base = URL(string: "http://localhost:11434/api/")!

    private static func call(_ path: String, method: String = "GET", _ body: [String: Any]? = nil, timeout: TimeInterval = 5) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = body == nil ? method : (method == "GET" ? "POST" : method)
        req.timeoutInterval = timeout
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
            throw ModelError.message(obj["error"] as? String ?? "Ollama answered \(code)")
        }
        return obj
    }

    static func installed() async throws -> [InstalledModel] {
        let tags = try await call("tags")
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [InstalledModel] = []
        for m in tags["models"] as? [[String: Any]] ?? [] {
            let d = m["details"] as? [String: Any] ?? [:]
            var model = InstalledModel(name: m["name"] as? String ?? "?", bytes: Int64(m["size"] as? Double ?? 0),
                                       family: d["family"] as? String ?? "", parameters: d["parameter_size"] as? String ?? "",
                                       quant: d["quantization_level"] as? String ?? "",
                                       modified: (m["modified_at"] as? String).flatMap { iso.date(from: $0) })
            model.capabilities = (try? await call("show", ["model": model.name]))?["capabilities"] as? [String] ?? []
            out.append(model)
        }
        return out.sorted { $0.name < $1.name }
    }

    /// What is in memory right now (name → bytes).
    static func loaded() async -> [String: Int64] {
        guard let ps = try? await call("ps") else { return [:] }
        var out: [String: Int64] = [:]
        for m in ps["models"] as? [[String: Any]] ?? [] { out[m["name"] as? String ?? ""] = Int64(m["size"] as? Double ?? 0) }
        return out
    }

    /// Takes a model out of memory (23 keeps its model loaded, and only one fits).
    static func unload(_ name: String) async {
        _ = try? await call("generate", ["model": name, "keep_alive": 0], timeout: 20)
    }

    static func delete(_ name: String) async throws {
        _ = try await call("delete", method: "DELETE", ["model": name], timeout: 30)
    }

    struct PullProgress { var status: String; var done: Int64; var total: Int64 }

    /// Downloads a model, reporting progress. Cancel the surrounding Task to stop it.
    static func pull(_ name: String, progress: @escaping @MainActor (PullProgress) -> Void) async throws {
        var req = URLRequest(url: base.appendingPathComponent("pull"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { throw ModelError.message("Ollama answered \(code)") }
        var last = PullProgress(status: "starting", done: 0, total: 0)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw ModelError.message(err) }
            last.status = obj["status"] as? String ?? last.status
            if let t = obj["total"] as? Double { last.total = Int64(t) }
            if let c = obj["completed"] as? Double { last.done = Int64(c) }
            let snapshot = last
            await progress(snapshot)
        }
        guard last.status == "success" else { throw ModelError.message("The download stopped early (\(last.status)).") }
    }
}

enum ModelError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Hugging Face (read-only lookups; nothing personal is sent, only the search words and repo names)

struct HFRepo: Identifiable, Hashable {
    var id: String
    var downloads: Int
    var likes: Int
    var tags: [String]
    var updated: Date?
}

/// One downloadable size of a model (a quantization), possibly split over several files.
struct HFQuant: Identifiable, Hashable {
    var id: String { tag }
    let tag: String                 // e.g. Q4_K_M, as Ollama's hf.co/<repo>:<tag> expects
    let files: [String]
    let bytes: Int64
}

extension HFQuant {
    /// How much a size gives up compared with the original, in plain words.
    var quality: (rank: Int, label: String) {
        let t = tag.replacingOccurrences(of: "UD-", with: "")
        if t.hasPrefix("IQ1") || t.hasPrefix("IQ2") || t.hasPrefix("Q2") || t.hasPrefix("TQ") { return (1, "Rough: noticeably worse answers") }
        if t.hasPrefix("IQ3") || t.hasPrefix("Q3") { return (2, "Fair: some loss") }
        if t.hasPrefix("IQ4") || t.hasPrefix("Q4") || t.hasPrefix("MXFP4") { return (3, "Good: the usual choice") }
        if t.hasPrefix("Q5") || t.hasPrefix("Q6") { return (4, "Very good") }
        if t.hasPrefix("Q8") { return (5, "Near the original") }
        return (6, "Original (very large)")
    }
}

struct HFDetails {
    var repo: String
    var quants: [HFQuant]
    var hasVisionFile: Bool         // an mmproj file: Ollama then gets image support
    var architecture: String?
    var parameters: Int64?
    var contextLength: Int?
    var templateHasTools: Bool?
    var license: String?
}

enum HuggingFace {
    private static func json(_ url: URL) async throws -> Any {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("23-local-assistant", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 || code == 401 { throw ModelError.message("Hugging Face doesn't have a public model with that name.") }
        if code >= 300 { throw ModelError.message("Hugging Face answered \(code).") }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Turns "https://huggingface.co/user/repo/…", "hf.co/user/repo:Q4" or "user/repo" into "user/repo".
    static func repoID(from text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www.", "huggingface.co/", "hf.co/"] where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        t = t.split(separator: ":").first.map(String.init) ?? t
        let parts = t.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] != "models", parts[0] != "search" else { return nil }
        let ok = { (s: String) in s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil }
        return ok(parts[0]) && ok(parts[1]) ? "\(parts[0])/\(parts[1])" : nil
    }

    static func search(_ words: String) async throws -> [HFRepo] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        c.queryItems = [.init(name: "search", value: words), .init(name: "filter", value: "gguf"),
                        .init(name: "sort", value: "downloads"), .init(name: "limit", value: "20")]
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (try await json(c.url!) as? [[String: Any]] ?? []).map {
            HFRepo(id: $0["id"] as? String ?? "?", downloads: $0["downloads"] as? Int ?? 0, likes: $0["likes"] as? Int ?? 0,
                   tags: $0["tags"] as? [String] ?? [], updated: ($0["lastModified"] as? String).flatMap { iso.date(from: $0) })
        }
    }

    static func details(_ repo: String) async throws -> HFDetails {
        let enc = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        async let infoAny = json(URL(string: "https://huggingface.co/api/models/\(enc)?expand[]=gguf&expand[]=cardData")!)
        async let treeAny = json(URL(string: "https://huggingface.co/api/models/\(enc)/tree/main?recursive=true")!)
        let info = try await infoAny as? [String: Any] ?? [:]
        let tree = try await treeAny as? [[String: Any]] ?? []
        let files: [(path: String, size: Int64)] = tree.compactMap {
            guard $0["type"] as? String == "file", let p = $0["path"] as? String, p.lowercased().hasSuffix(".gguf") else { return nil }
            let lfs = $0["lfs"] as? [String: Any]
            return (p, Int64((lfs?["size"] as? Double) ?? ($0["size"] as? Double) ?? 0))
        }
        let vision = files.contains { $0.path.lowercased().contains("mmproj") }
        var groups: [String: (files: [String], bytes: Int64)] = [:]
        for f in files where !f.path.lowercased().contains("mmproj") {
            guard let tag = quantTag(f.path) else { continue }
            groups[tag, default: ([], 0)].files.append(f.path)
            groups[tag, default: ([], 0)].bytes += f.size
        }
        let quants = groups.map { HFQuant(tag: $0.key, files: $0.value.files.sorted(), bytes: $0.value.bytes) }.sorted { $0.bytes < $1.bytes }
        let gguf = info["gguf"] as? [String: Any]
        let card = info["cardData"] as? [String: Any]
        return HFDetails(repo: repo, quants: quants, hasVisionFile: vision,
                         architecture: gguf?["architecture"] as? String,
                         parameters: (gguf?["total"] as? Double).map { Int64($0) },
                         contextLength: gguf?["context_length"] as? Int,
                         templateHasTools: (gguf?["chat_template"] as? String).map { $0.contains("tools") },
                         license: card?["license"] as? String)
    }

    /// "Qwen3-8B-Q4_K_M.gguf" → "Q4_K_M"; "Q8_0/model-00001-of-00002.gguf" → "Q8_0".
    static func quantTag(_ path: String) -> String? {
        let pattern = #"(?i)(?:^|[-_./])((?:UD-)?(?:IQ[1-4]_(?:XXS|XS|S|M|NL)|Q[2-8]_K(?:_[SML]|_XL)?|Q[4-8]_[01]|Q[2-8]_K_XL|TQ[12]_0|MXFP4(?:_MOE)?|BF16|F16|F32))(?=[-_./]|$)"#
        guard let r = path.range(of: pattern, options: .regularExpression) else { return nil }
        var tag = String(path[r])
        while let f = tag.first, "-_./".contains(f) { tag.removeFirst() }
        return tag.uppercased()
    }

    /// Reads only the start of a model file (its header, a few MB) to learn its shape without downloading it.
    static func header(_ repo: String, file: String) async throws -> GGUFHeader {
        let enc = (repo + "/resolve/main/" + file).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        var have = Data()
        for size in [3 << 20, 12 << 20] {
            var req = URLRequest(url: URL(string: "https://huggingface.co/\(enc)")!)
            req.timeoutInterval = 30
            req.setValue("bytes=0-\(size - 1)", forHTTPHeaderField: "Range")
            req.setValue("23-local-assistant", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let code = (resp as? HTTPURLResponse)?.statusCode, code == 206 || code == 200 else { throw ModelError.message("Couldn't read the model's header.") }
            have = data
            let h = GGUFHeader.parse(have)
            if h.complete || h.blockCount != nil && h.architecture != nil && h.reachedTokenizer { return h }
        }
        return GGUFHeader.parse(have)
    }
}

// MARK: - GGUF header

/// The few numbers from a model file's header that decide how much memory it needs.
struct GGUFHeader {
    var architecture: String?
    var parameterCount: Int64?
    var blockCount: Int?
    var headCount: Int?
    var headCountKV: Int?
    var keyLength: Int?
    var valueLength: Int?
    var embedding: Int?
    var fullAttentionInterval: Int?
    var slidingWindow: Int?
    var slidingPattern: Int?
    var expertCount: Int?
    var expertUsed: Int?
    var contextLength: Int?
    var hasToolTemplate: Bool?
    var complete = false            // read every key
    var reachedTokenizer = false

    static func parse(_ d: Data) -> GGUFHeader {
        var h = GGUFHeader()
        var p = 0
        let bytes = [UInt8](d)
        func need(_ n: Int) -> Bool { p + n <= bytes.count }
        func u32() -> UInt32? { guard need(4) else { return nil }; defer { p += 4 }; return bytes[p..<p+4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func u64() -> UInt64? { guard need(8) else { return nil }; defer { p += 8 }; return bytes[p..<p+8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        func str() -> String? {
            guard let n = u64(), n < 50_000_000, need(Int(n)) else { return nil }
            defer { p += Int(n) }
            return String(decoding: bytes[p..<p+Int(n)], as: UTF8.self)
        }
        let sizes: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        /// Reads a value; returns an integer when it is one, a string when it is one, and skips anything else.
        func value(_ type: UInt32) -> (Int64?, String?)? {
            switch type {
            case 8: guard let s = str() else { return nil }; return (nil, s)
            case 9:
                guard let t = u32(), let n = u64() else { return nil }
                if t == 8 { for _ in 0..<n { guard str() != nil else { return nil } } }
                else if let sz = sizes[t] { guard need(sz * Int(n)) else { return nil }; p += sz * Int(n) }
                else { return nil }
                return (nil, nil)
            case 6: guard let v = u32() else { return nil }; return (Int64(Float(bitPattern: v)), nil)
            case 12: guard let v = u64() else { return nil }; return (Int64(Double(bitPattern: v)), nil)
            default:
                guard let sz = sizes[type], need(sz) else { return nil }
                var v: UInt64 = 0
                for i in (0..<sz).reversed() { v = v << 8 | UInt64(bytes[p + i]) }
                p += sz
                if type == 1 { return (Int64(Int8(truncatingIfNeeded: v)), nil) }
                if type == 3 { return (Int64(Int16(truncatingIfNeeded: v)), nil) }
                if type == 5 { return (Int64(Int32(truncatingIfNeeded: v)), nil) }
                return (Int64(truncatingIfNeeded: v), nil)
            }
        }
        guard bytes.count >= 24, bytes[0..<4] == [0x47, 0x47, 0x55, 0x46] else { return h }   // "GGUF"
        p = 4
        _ = u32()                       // version
        _ = u64()                       // tensor count
        guard let kvCount = u64() else { return h }
        for _ in 0..<kvCount {
            guard let key = str(), let type = u32() else { return h }
            if key.hasPrefix("tokenizer.") { h.reachedTokenizer = true }
            guard let (num, text) = value(type) else { return h }
            let arch = h.architecture ?? "\u{0}"
            switch key {
            case "general.architecture": h.architecture = text
            case "general.parameter_count": h.parameterCount = num
            case "tokenizer.chat_template": h.hasToolTemplate = text?.contains("tools")
            case "\(arch).block_count": h.blockCount = num.map(Int.init)
            case "\(arch).attention.head_count": h.headCount = num.map(Int.init)
            case "\(arch).attention.head_count_kv": h.headCountKV = num.map(Int.init)
            case "\(arch).attention.key_length": h.keyLength = num.map(Int.init)
            case "\(arch).attention.value_length": h.valueLength = num.map(Int.init)
            case "\(arch).embedding_length": h.embedding = num.map(Int.init)
            case "\(arch).full_attention_interval": h.fullAttentionInterval = num.map(Int.init)
            case "\(arch).attention.sliding_window": h.slidingWindow = num.map(Int.init)
            case "\(arch).attention.sliding_window_pattern": h.slidingPattern = num.map(Int.init)
            case "\(arch).expert_count": h.expertCount = num.map(Int.init)
            case "\(arch).expert_used_count": h.expertUsed = num.map(Int.init)
            case "\(arch).context_length": h.contextLength = num.map(Int.init)
            default: break
            }
        }
        h.complete = true
        return h
    }

    /// Memory for the conversation itself (the KV cache) at `context` tokens, at 16-bit precision.
    func kvCacheBytes(context: Int) -> Int64? {
        guard let layers = blockCount, let heads = headCount ?? headCountKV else { return nil }
        let kv = headCountKV ?? heads
        let keyLen = keyLength ?? embedding.map { $0 / heads } ?? 128
        let valLen = valueLength ?? keyLen
        let perToken = Int64(kv) * Int64(keyLen + valLen) * 2
        // Hybrid models (e.g. Qwen3.5) only keep a cache on every Nth layer.
        if let n = fullAttentionInterval, n > 1 { return Int64(max(1, layers / n)) * perToken * Int64(context) }
        // Sliding-window models (Gemma, gpt-oss) remember only a short window on most layers.
        if let w = slidingWindow, w > 0, w < context {
            let pattern = slidingPattern ?? (architecture?.hasPrefix("gemma3") == true ? 6 : 2)
            let global = max(1, layers / max(1, pattern))
            return Int64(global) * perToken * Int64(context) + Int64(layers - global) * perToken * Int64(w)
        }
        return Int64(layers) * perToken * Int64(context)
    }
}

// MARK: - Will it run comfortably here?

struct FitReport {
    enum Verdict: String { case comfortable = "Runs comfortably", tight = "Tight, but it should run", tooBig = "Too big for this Mac" }
    var verdict: Verdict
    var recommended = false
    var needBytes: Int64
    var budgetBytes: Int64
    var weightsBytes: Int64
    var cacheBytes: Int64
    var tokensPerSecond: Double?
    var currentTokensPerSecond: Double?
    var diskFreeBytes: Int64
    var reasons: [String]
    var notes: [String]
}

enum FitCheck {
    static let context = 16_384                       // what 23 runs every model with
    static let runtimeOverhead: Int64 = 600_000_000   // Ollama's working buffers, roughly
    /// Room the rest of the Mac needs while 23 works: macOS, Chrome, the voice, whisper.
    static let restOfMac: Int64 = 4_000_000_000

    /// How much of the memory the graphics side may use (macOS sets this; about 12 GB of 16 here).
    static var gpuBudget: Int64 { Int64(MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 10_700_000_000) }
    static var totalRAM: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }
    static var diskFree: Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { Int64($0) } ?? 0
    }

    /// Memory-bandwidth speed estimate, tuned by what the model in use really does here.
    /// `reference`: (bytes the current model reads per token, its measured tokens/s).
    static func speed(activeBytes: Int64, reference: (bytes: Int64, tps: Double)?) -> Double {
        let effective: Double
        if let r = reference, r.tps > 1, r.bytes > 0 { effective = Double(r.bytes) * r.tps }
        else { effective = 75e9 }                      // ~60 % of the M4's 120 GB/s
        // Small models stop being limited by memory speed; past ~60 tokens/s the estimate means little.
        return min(60, effective / Double(max(activeBytes, 1)))
    }

    static func evaluate(fileBytes: Int64, header: GGUFHeader?, templateHasTools: Bool?, hasVision: Bool,
                         reference: (bytes: Int64, tps: Double)?, alreadyDownloaded: Bool = false) -> FitReport {
        let cache = header?.kvCacheBytes(context: context) ?? Int64(Double(fileBytes) * 0.12)
        let need = fileBytes + cache + runtimeOverhead
        let budget = gpuBudget
        var reasons: [String] = [], notes: [String] = []
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1e9) }

        // Mixture-of-experts models only read the experts they use for each word, so they run faster than their size.
        var active = fileBytes
        if let n = header?.expertCount, let k = header?.expertUsed, n > 0, k > 0, k < n {
            active = Int64(Double(fileBytes) * (0.15 + 0.85 * Double(k) / Double(n)))
            notes.append("A mixture-of-experts model: it uses \(k) of its \(n) experts per word, so it runs faster than its size suggests.")
        }
        let tps = speed(activeBytes: active, reference: reference)

        var verdict: FitReport.Verdict
        if need > budget {
            verdict = .tooBig
            reasons.append("Needs about \(gb(need)), but this Mac lets models use \(gb(budget)). It would spill onto the processor and run very slowly.")
        } else if need > budget - 1_500_000_000 || totalRAM - need < restOfMac {
            verdict = .tight
            reasons.append("Needs about \(gb(need)) of the \(gb(budget)) available to models, leaving little room for Chrome, the voice and other apps.")
        } else {
            verdict = .comfortable
            reasons.append("Needs about \(gb(need)) of the \(gb(budget)) available to models.")
        }
        if tps < 4 { if verdict == .comfortable { verdict = .tight }; reasons.append(String(format: "Expect only about %.0f tokens per second: replies will feel slow.", tps)) }

        let disk = diskFree
        if !alreadyDownloaded && fileBytes > disk - 10_000_000_000 {
            verdict = .tooBig
            reasons.append("Not enough free disk space: it is \(gb(fileBytes)) and \(gb(disk)) is free.")
        }
        if templateHasTools == false { notes.append("Its chat template has no tool support, so it can talk but can't move files, browse or run code for you.") }
        if hasVision { notes.append("Includes image support (a vision file), so it can look at pictures.") }
        if header == nil { notes.append("Couldn't read its header, so the memory figure is a rougher estimate.") }

        return FitReport(verdict: verdict, needBytes: need, budgetBytes: budget, weightsBytes: fileBytes, cacheBytes: cache,
                         tokensPerSecond: tps, currentTokensPerSecond: reference?.tps, diskFreeBytes: disk, reasons: reasons, notes: notes)
    }

    /// The size to suggest: the best quality that runs comfortably (and is at least "Fair"), else the best that runs at all.
    static func recommended(_ quants: [HFQuant], reports: [String: FitReport]) -> String? {
        // Q4_K_M is the well-tested sweet spot between quality and speed; suggest it whenever it is comfortable.
        if let q = quants.first(where: { $0.tag == "Q4_K_M" }), reports[q.tag]?.verdict == .comfortable { return q.tag }
        let fits = quants.filter { reports[$0.tag]?.verdict == .comfortable && $0.quality.rank >= 2 }
        let pick = fits.max { ($0.quality.rank, $0.bytes) < ($1.quality.rank, $1.bytes) }
            ?? quants.filter { reports[$0.tag]?.verdict == .tight }.max { ($0.quality.rank, $0.bytes) < ($1.quality.rank, $1.bytes) }
        return pick?.tag
    }

    /// The model in use, as a speed reference: what it really occupies while loaded (else its size on disk)
    /// and the last measured speed.
    static func reference(installed: [InstalledModel], loaded: [String: Int64]) -> (bytes: Int64, tps: Double)? {
        guard Prefs.lastSpeed > 1, let m = installed.first(where: { $0.shortName == Prefs.model || $0.name == Prefs.model }) else { return nil }
        return (loaded[m.name].flatMap { $0 > 0 ? $0 : nil } ?? m.bytes, Prefs.lastSpeed)
    }
}
