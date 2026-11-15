import SwiftUI

/// State for Settings › Model. A singleton so a download keeps going (and keeps its progress) when you leave the page.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published var installed: [InstalledModel] = []
    @Published var loaded: [String: Int64] = [:]
    @Published var ollamaUp: Bool?
    @Published var problem: String?
    @Published var switching = false

    // Adding from Hugging Face
    @Published var query = ""
    @Published var results: [HFRepo] = []
    @Published var searching = false
    @Published var details: HFDetails?
    @Published var reports: [String: FitReport] = [:]
    @Published var recommended: String?
    @Published var selectedQuant: String?
    @Published var checking = false

    // Download
    @Published var downloading: String?             // Ollama name being pulled
    @Published var progress: OllamaAdmin.PullProgress?
    @Published var justDownloaded: String?
    private var pullTask: Task<Void, Never>?

    var current: InstalledModel? { installed.first { $0.shortName == Prefs.model || $0.name == Prefs.model } }
    var anyChatBusy: Bool { ChatModel.running?.isBusy == true }

    func refresh() async {
        do {
            installed = try await OllamaAdmin.installed()
            loaded = await OllamaAdmin.loaded()
            ollamaUp = true
        } catch { ollamaUp = false }
    }

    /// Makes another installed model the one 23 uses, and frees the old one's memory (only one fits).
    func use(_ m: InstalledModel) async {
        guard !anyChatBusy else { problem = "A chat is still working. Wait for it or stop it, then switch."; return }
        let old = current?.name
        switching = true
        Prefs.model = m.shortName
        ActivityLog.add("setting", "model → \(m.shortName)")
        if let old, old != m.name { await OllamaAdmin.unload(old) }
        Prefs.lastSpeed = 0                         // the old model's speed says nothing about this one
        switching = false
        problem = nil
        await refresh()
    }

    func delete(_ m: InstalledModel) async {
        guard m.name != current?.name else { problem = "That's the model in use. Switch to another one first."; return }
        do {
            await OllamaAdmin.unload(m.name)
            try await OllamaAdmin.delete(m.name)
            ActivityLog.add("model deleted", "\(m.shortName) (\(Self.gb(m.bytes)))")
            problem = nil
        } catch { problem = "Couldn't delete it: \(error.localizedDescription)" }
        await refresh()
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        problem = nil
        // A pasted link (or "user/repo") goes straight to that model.
        if q.contains("/"), let repo = HuggingFace.repoID(from: q) { await open(repo); return }
        searching = true
        defer { searching = false }
        do { results = try await HuggingFace.search(q); details = nil
            if results.isEmpty { problem = "No GGUF models found for “\(q)”." }
        } catch { problem = error.localizedDescription }
    }

    func open(_ repo: String) async {
        checking = true
        defer { checking = false }
        details = nil; reports = [:]; recommended = nil; selectedQuant = nil
        do {
            let d = try await HuggingFace.details(repo)
            guard !d.quants.isEmpty else { problem = "\(repo) has no GGUF files Ollama can use."; return }
            // The header of a middle size tells the model's shape; it is the same for every size.
            let probe = d.quants.first { $0.tag == "Q4_K_M" } ?? d.quants[d.quants.count / 2]
            let header = try? await HuggingFace.header(repo, file: probe.files[0])
            let ref = FitCheck.reference(installed: installed, loaded: loaded)
            let tools = d.templateHasTools ?? header?.hasToolTemplate
            var r: [String: FitReport] = [:]
            for q in d.quants {
                let have = installed.contains { $0.name.lowercased() == Self.ollamaName(repo, q.tag).lowercased() }
                r[q.tag] = FitCheck.evaluate(fileBytes: q.bytes, header: header, templateHasTools: tools, hasVision: d.hasVisionFile, reference: ref, alreadyDownloaded: have)
            }
            details = d; reports = r
            recommended = FitCheck.recommended(d.quants, reports: r)
            selectedQuant = recommended ?? d.quants.first?.tag
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    static func ollamaName(_ repo: String, _ tag: String) -> String { "hf.co/\(repo):\(tag)" }

    func download(_ repo: String, _ q: HFQuant) {
        guard downloading == nil else { return }
        let name = Self.ollamaName(repo, q.tag)
        downloading = name; progress = nil; justDownloaded = nil; problem = nil
        ActivityLog.add("model download", "\(name) (\(Self.gb(q.bytes)))")
        pullTask = Task {
            do {
                try await OllamaAdmin.pull(name) { [weak self] p in self?.progress = p }
                justDownloaded = name
                ActivityLog.add("model downloaded", name)
            } catch is CancellationError {
                ActivityLog.add("model download", "cancelled \(name)")
            } catch {
                if !Task.isCancelled { problem = "The download failed: \(error.localizedDescription)" }
            }
            downloading = nil; progress = nil
            await refresh()
        }
    }

    func cancelDownload() { pullTask?.cancel(); pullTask = nil }

    static func gb(_ b: Int64) -> String { String(format: b >= 10_000_000_000 ? "%.0f GB" : "%.1f GB", Double(b) / 1e9) }
}

// MARK: - The page

struct ModelSettings: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var confirmDelete: InstalledModel?

    var body: some View {
        inUse
        installedList
        addModel
        if let p = store.problem {
            Section { Label(p, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
        }
        Section {} footer: {
            Button("Refresh") { Task { await store.refresh() } }.controlSize(.small)
        }
        .task { await store.refresh() }
        .confirmationDialog(confirmDelete.map { "Delete \($0.displayName)?" } ?? "", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let m = confirmDelete { Task { await store.delete(m) } }; confirmDelete = nil }
        } message: {
            Text("This frees \(ModelStore.gb(confirmDelete?.bytes ?? 0)) of disk space. It doesn't go to the Bin: to have it back you would download it again.")
        }
    }

    // MARK: In use

    private var inUse: some View {
        SettingsGroup(title: "In use", note: "23 runs entirely on this Mac through Ollama. Only one model fits in memory at a time, so switching frees the old one.") {
            InfoRow(key: "Ollama", value: store.ollamaUp == nil ? "checking…" : store.ollamaUp! ? "running on this Mac" : "not responding", ok: store.ollamaUp)
            if let m = store.current {
                LabeledContent("Model") { Text(m.displayName).textSelection(.enabled) }
                LabeledContent("Size") { Text([m.parameters, m.quant, ModelStore.gb(m.bytes)].filter { !$0.isEmpty }.joined(separator: " · ")) }
                LabeledContent("Can") { Text(abilities(m)) }
                if let l = store.loaded[m.name] {
                    LabeledContent("Right now") { Text("loaded, using \(ModelStore.gb(l)) of memory") }
                } else {
                    LabeledContent("Right now") { Text("not in memory: it loads with the next message").foregroundStyle(.secondary) }
                }
                LabeledContent("Speed") { Text(Prefs.lastSpeed > 0 ? String(format: "%.1f tokens per second (last reply)", Prefs.lastSpeed) : "not measured yet") }
                if !m.canUseTools {
                    Label("This model can't use tools: it can talk, but it can't move files, browse or run code.", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red)
                }
            } else if store.ollamaUp == true {
                Text("“\(Prefs.model)” isn't installed. Pick one below.").foregroundStyle(.secondary)
            }
        }
    }

    private func abilities(_ m: InstalledModel) -> String {
        var a = ["chat"]
        if m.canUseTools { a.append("use tools") }
        if m.canThink { a.append("think") }
        if m.canSee { a.append("see images") }
        return a.joined(separator: ", ")
    }

    // MARK: Installed

    private var installedList: some View {
        SettingsGroup(title: "Installed") {
            ForEach(store.installed) { m in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.displayName)
                        Text([m.parameters, m.quant, ModelStore.gb(m.bytes), abilities(m)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if m.name == store.current?.name {
                        Text("In use").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("Use") { Task { await store.use(m) } }
                            .disabled(store.switching || store.anyChatBusy)
                        Button(role: .destructive) { confirmDelete = m } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete \(m.displayName)")
                            .accessibilityLabel("Delete \(m.displayName)")
                    }
                }
            }
            if store.installed.isEmpty { Text(store.ollamaUp == false ? "Ollama isn't running." : "No models yet.").foregroundStyle(.secondary) }
        }
    }

    // MARK: Add

    private var addModel: some View {
        SettingsGroup(title: "Add a model from Hugging Face",
                      note: "Before anything downloads, 23 reads the model's description and checks it against this Mac: memory, speed, disk space and whether it can use tools. Only your search words are sent to Hugging Face.") {
            HStack {
                TextField("Search", text: $store.query, prompt: Text("Search, or paste a Hugging Face link"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.search() } }
                Button(store.searching ? "Searching…" : "Search") { Task { await store.search() } }
                    .disabled(store.searching || store.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let name = store.downloading { downloadRow(name) }
            if let done = store.justDownloaded, let m = store.installed.first(where: { $0.name.lowercased() == done.lowercased() }) {
                HStack {
                    Label("\(m.displayName) is ready.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    if m.name != store.current?.name { Button("Use it now") { Task { await store.use(m); store.justDownloaded = nil } }.disabled(store.anyChatBusy) }
                }
            }
            if store.checking {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking it against this Mac…").foregroundStyle(.secondary) }
            } else if let d = store.details {
                fitView(d)
            } else if !store.results.isEmpty {
                ForEach(store.results) { r in
                    Button { Task { await store.open(r.id) } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.id).foregroundStyle(.primary)
                                Text(resultLine(r)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func resultLine(_ r: HFRepo) -> String {
        var parts = ["\(r.downloads.formatted(.number.notation(.compactName))) downloads"]
        if r.tags.contains("image-text-to-text") || r.tags.contains("vision") { parts.append("sees images") }
        if let u = r.updated { parts.append("updated \(u.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    private func downloadRow(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading \(InstalledModel(name: name, bytes: 0, family: "", parameters: "", quant: "", modified: nil).displayName)")
                Spacer()
                Button("Cancel") { store.cancelDownload() }.controlSize(.small)
            }
            if let p = store.progress, p.total > 0 {
                ProgressView(value: Double(p.done), total: Double(p.total))
                Text("\(ModelStore.gb(p.done)) of \(ModelStore.gb(p.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
                Text(store.progress?.status ?? "Starting…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Fit check

    @ViewBuilder private func fitView(_ d: HFDetails) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.repo).font(.headline)
                Text([d.parameters.map { String(format: "%.1fB parameters", Double($0) / 1e9) }, d.architecture, d.license].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Back to results") { store.details = nil }.controlSize(.small).disabled(store.results.isEmpty)
        }
        Picker("Size", selection: Binding(get: { store.selectedQuant ?? "" }, set: { store.selectedQuant = $0 })) {
            ForEach(d.quants) { q in
                let r = store.reports[q.tag]
                Text("\(q.tag) · \(ModelStore.gb(q.bytes))\(q.tag == store.recommended ? " · suggested" : "")\(r?.verdict == .tooBig ? " · too big" : "")").tag(q.tag)
            }
        }
        if let tag = store.selectedQuant, let q = d.quants.first(where: { $0.tag == tag }), let r = store.reports[tag] {
            verdictView(r, q)
            let have = store.installed.contains { $0.name.lowercased() == ModelStore.ollamaName(d.repo, tag).lowercased() }
            HStack {
                Spacer()
                if have {
                    Text("Already installed").foregroundStyle(.secondary)
                } else {
                    Button(r.verdict == .tooBig ? "Too big to download" : "Download \(ModelStore.gb(q.bytes))") { store.download(d.repo, q) }
                        .buttonStyle(.borderedProminent)
                        .disabled(r.verdict == .tooBig || store.downloading != nil)
                }
            }
        }
    }

    private func verdictView(_ r: FitReport, _ q: HFQuant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(r.verdict.rawValue, systemImage: r.verdict == .comfortable ? "checkmark.circle" : r.verdict == .tight ? "exclamationmark.triangle" : "xmark.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(r.verdict == .tooBig ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow { Text("Memory").foregroundStyle(.secondary); Text("about \(ModelStore.gb(r.needBytes)) of the \(ModelStore.gb(r.budgetBytes)) models can use here (model \(ModelStore.gb(r.weightsBytes)) + conversation \(ModelStore.gb(r.cacheBytes)))") }
                if let t = r.tokensPerSecond {
                    GridRow { Text("Speed").foregroundStyle(.secondary)
                        Text((t >= 60 ? "very fast (60+ tokens per second)" : String(format: "roughly %.0f tokens per second", t)) + (r.currentTokensPerSecond.map { String(format: " (yours now: %.0f)", $0) } ?? "")) }
                }
                GridRow { Text("Quality").foregroundStyle(.secondary); Text(q.quality.label) }
                GridRow { Text("Disk").foregroundStyle(.secondary); Text("\(ModelStore.gb(q.bytes)) to download, \(ModelStore.gb(r.diskFreeBytes)) free") }
            }
            .font(.callout)
            ForEach(r.reasons.dropFirst(), id: \.self) { Text($0).font(.callout) }
            ForEach(r.notes, id: \.self) { n in
                if n.contains("no tool support") {
                    Label(n, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)    // a real limitation for 23
                } else {
                    Text(n).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Estimates from the model's description and this Mac's measured speed; the real figure shows after the first reply.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
