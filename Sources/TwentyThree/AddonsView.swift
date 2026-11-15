import SwiftUI
import AppKit

/// The install flow's state (kept while the user moves around Settings).
@MainActor
final class AddonInstallFlow: ObservableObject {
    static let shared = AddonInstallFlow()
    enum Source: String, CaseIterable, Identifiable { case registry = "MCP Registry", skills = "Anthropic skills", link = "Paste a link"; var id: String { rawValue } }
    enum Step: Equatable { case idle, downloading, reviewing, ready, installing, failed(String) }

    @Published var source: Source = .registry
    @Published var query = ""
    @Published var searching = false
    @Published var results: [AddonCandidate] = []
    @Published var problem: String?

    @Published var picked: AddonCandidate?
    @Published var step: Step = .idle
    @Published var review: AddonReview?
    @Published var network = false
    @Published var readOnlyFree = false
    @Published var values: [String: String] = [:]
    @Published var installedMessage: String?
    private var staging: URL?
    private var work: Task<Void, Never>?

    func search() async {
        problem = nil; results = []; searching = true
        defer { searching = false }
        do {
            switch source {
            case .registry: results = try await AddonCatalog.searchRegistry(query)
            case .skills: results = try await AddonCatalog.anthropicSkills(matching: query)
            case .link: let c = try await AddonCatalog.fromLink(query); results = [c]; choose(c)
            }
            if results.isEmpty { problem = "Nothing found." }
        } catch { problem = error.localizedDescription }
    }

    /// Download, then have Claude review it. Nothing is installed until the user says so.
    func choose(_ c: AddonCandidate) {
        cancel()
        picked = c; review = nil; installedMessage = nil
        values = Dictionary(uniqueKeysWithValues: c.env.compactMap { v in v.defaultValue.map { (v.name, $0) } })
        guard c.unsupported == nil else { step = .failed(c.unsupported!); return }
        step = .downloading
        work = Task {
            do {
                let dir = try await AddonInstaller.download(c)
                staging = dir
                if Task.isCancelled { AddonInstaller.discard(dir); return }
                step = .reviewing
                let r = try await AddonInstaller.review(c, at: dir)
                if Task.isCancelled { return }
                review = r
                network = r.needsInternet
                readOnlyFree = false
                step = .ready
            } catch {
                if !Task.isCancelled { step = .failed(error.localizedDescription) }
            }
        }
    }

    func install() {
        guard let c = picked, let dir = staging, let r = review else { return }
        step = .installing
        do {
            try AddonInstaller.install(c, from: dir, review: r, network: network, readOnlyFree: readOnlyFree, values: values)
            staging = nil
            if c.kind == .npmServer {
                Task {
                    do {
                        _ = try await AddonStore.shared.connection(c.id)
                        installedMessage = "\(c.title) is installed and ready: \(AddonStore.shared.tools[c.id]?.count ?? 0) tools."
                    } catch {
                        installedMessage = "\(c.title) is installed but didn't start: \(error.localizedDescription). It may need settings it didn't get."
                    }
                    step = .idle; picked = nil
                }
            } else {
                installedMessage = "The skill “\(c.title)” is installed."
                step = .idle; picked = nil
            }
        } catch { step = .failed(error.localizedDescription) }
    }

    func cancel() {
        work?.cancel(); work = nil
        if let s = staging { AddonInstaller.discard(s) }
        staging = nil; picked = nil; review = nil; step = .idle
    }
}

// MARK: - Settings › Add-ons

struct AddonsSettings: View {
    @ObservedObject private var store = AddonStore.shared
    @ObservedObject private var skills = SkillStore.shared
    @ObservedObject private var flow = AddonInstallFlow.shared
    @State private var removing: String?

    var body: some View {
        SettingsGroup(title: "Tool servers",
                      note: "Each runs in 23's sandbox: no iCloud, keychain or SSH keys, and it can only write in its own folder, temp and caches. Tools that could change things or run programs ask you first.") {
            if store.servers.isEmpty { Text("None yet. Add one below.").foregroundStyle(.secondary) }
            ForEach(store.servers) { s in serverRow(s) }
        }
        if store.server("rea") != nil && REAEngines.installed {
            SettingsGroup(title: "REA analysis engine", note: "Ghidra (free, open source) lets REA decompile and search inside code. It came from the official GitHub release with its published SHA-256 checksum verified, and its decompiler was built on this Mac from the source in that release. It runs inside REA's sandbox.") {
                LabeledContent("Decompiling") { Text("Ghidra 12.1.4, with Java 21") }
            }
        }
        if store.server("rea") != nil && !REAEngines.installed {
            SettingsGroup(title: "REA analysis engine",
                          note: "REA's inspection tools work now (apps, signatures, libraries, archives, plists). Decompiling and searching inside code need an analysis engine: Ghidra is free (about 1 GB with Java), Hopper and IDA are paid. Ask 23's builder to set one up.") {
                LabeledContent("Decompiling") { Text("not available yet").foregroundStyle(.secondary) }
            }
        }
        SettingsGroup(title: "Skills", note: "Instructions for particular kinds of task. 23 sees each skill's name and description, and reads the whole skill when it's relevant.") {
            if skills.skills.isEmpty { Text("None yet. Add one below.").foregroundStyle(.secondary) }
            ForEach(skills.skills) { sk in
                HStack {
                    Toggle(isOn: Binding(get: { sk.enabled }, set: { skills.setEnabled(sk.id, $0) })) {
                        Text(sk.name)
                        Text(sk.description).lineLimit(2)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([sk.folder]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder")
                    Button(role: .destructive) { skills.remove(sk.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove")
                }
            }
        }
        addSection
        .confirmationDialog("Remove \(removing.flatMap { store.server($0)?.name } ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let r = removing { store.remove(r) }; removing = nil }
        } message: { Text("Its files go to the Bin.") }
    }

    private func serverRow(_ s: AddonServer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { s.enabled }, set: { store.setEnabled(s.id, $0) })) {
                    Text(s.name)
                    Text(s.summary).lineLimit(2)
                }
                if s.id != "rea" {
                    Button(role: .destructive) { removing = s.id } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Remove")
                }
            }
            Group {
                Text(policyText(s) + (s.network ? " · may use the internet" : " · no internet"))
                if let n = store.tools[s.id]?.count { Text("\(n) tools") }
                if let p = store.status[s.id] { Text(p).foregroundStyle(.red) }
                if let r = s.review { Text("Review at install: \(r)") }
                Text(s.source)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func policyText(_ s: AddonServer) -> String {
        switch s.policy {
        case .rea: return "Inspecting files runs freely; running, attaching, devices, web and changes ask first"
        case .readOnlyFree: return "Read-only tools run freely; the rest ask first"
        case .askAll: return "Every tool asks first"
        }
    }

    // MARK: Adding

    @ViewBuilder private var addSection: some View {
        SettingsGroup(title: "Add", note: "Before anything is installed, it's downloaded into a sandbox with install scripts switched off, and Claude reads its code and tells you what it does and any red flags. Claude sees only that add-on's public code.") {
            Picker("From", selection: $flow.source) { ForEach(AddonInstallFlow.Source.allCases) { Text($0.rawValue).tag($0) } }
            HStack {
                TextField("Search", text: $flow.query, prompt: Text(flow.source == .link ? "npmjs.com/package/… or a GitHub link to a skill" : flow.source == .skills ? "Search skills (empty: all)" : "Search, e.g. “git”, “calendar”"))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await flow.search() } }
                Button(flow.searching ? "Looking…" : flow.source == .link ? "Check" : "Search") { Task { await flow.search() } }
                    .disabled(flow.searching || (flow.source != .skills && flow.query.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            if let p = flow.problem { Text(p).font(.callout).foregroundStyle(.red) }
            if let m = flow.installedMessage { Label(m, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            if let c = flow.picked {
                installCard(c)
            } else {
                ForEach(flow.results) { c in
                    Button { flow.choose(c) } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).foregroundStyle(.primary)
                                if !c.summary.isEmpty { Text(c.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                if let u = c.unsupported { Text(u).font(.caption).foregroundStyle(.tertiary) }
                            }
                            Spacer()
                            Text(c.kind == .skill ? "Skill" : "Tools").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(c.unsupported != nil)
                }
            }
        }
    }

    @ViewBuilder private func installCard(_ c: AddonCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.headline)
                    Text(c.source + (c.version.map { " \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let r = c.repository, let u = URL(string: r.replacingOccurrences(of: "git+", with: "").replacingOccurrences(of: ".git", with: "")) {
                    Link("Source", destination: u).font(.callout)
                }
            }
            switch flow.step {
            case .downloading: HStack { ProgressView().controlSize(.small); Text("Downloading in the sandbox (install scripts off)…").foregroundStyle(.secondary) }
            case .reviewing: HStack { ProgressView().controlSize(.small); Text("Claude is reading its code… (a minute or two)").foregroundStyle(.secondary) }
            case .installing: HStack { ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(.secondary) }
            case .failed(let why): Text(why).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            case .ready, .idle: EmptyView()
            }
            if let r = flow.review, flow.step == .ready {
                reviewView(r)
                if c.kind == .npmServer {
                    Toggle("Let it use the internet", isOn: $flow.network)
                    Toggle("Allow tools it marks read-only without asking", isOn: $flow.readOnlyFree)
                        .disabled(r.risk.lowercased() == "high")
                    ForEach(c.env, id: \.name) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name + (v.required ? " (required)" : "")).font(.callout)
                            if v.secret {
                                SecureField(v.description, text: Binding(get: { flow.values[v.name] ?? "" }, set: { flow.values[v.name] = $0 }))
                            } else {
                                TextField(v.description, text: Binding(get: { flow.values[v.name] ?? "" }, set: { flow.values[v.name] = $0 }))
                            }
                        }
                    }
                    if c.env.contains(where: \.secret) { Text("Secret values are kept in your keychain and only given to this add-on.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { flow.cancel() }
                if flow.step == .ready {
                    let missing = c.env.filter { $0.required && (flow.values[$0.name] ?? "").isEmpty }
                    Button("Install") { flow.install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!missing.isEmpty)
                        .help(missing.isEmpty ? "Install it, sandboxed" : "Fill in: " + missing.map(\.name).joined(separator: ", "))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func reviewView(_ r: AddonReview) -> some View {
        let high = r.risk.lowercased() == "high"
        return VStack(alignment: .leading, spacing: 6) {
            Label("Claude's review: \(r.risk.lowercased()) risk", systemImage: high ? "exclamationmark.octagon" : r.risk.lowercased() == "medium" ? "exclamationmark.triangle" : "checkmark.shield")
                .font(.body.weight(.semibold))
                .foregroundStyle(high ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Text(r.whatItDoes).font(.callout)
            Text("Reaches: \(r.touches)").font(.callout).foregroundStyle(.secondary)
            Text(r.needsInternet ? "Needs the internet." : "Doesn't need the internet.").font(.callout).foregroundStyle(.secondary)
            ForEach(r.redFlags, id: \.self) { f in Label(f, systemImage: "flag").font(.callout).foregroundStyle(.red) }
            Text(r.verdict).font(.callout.italic())
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
