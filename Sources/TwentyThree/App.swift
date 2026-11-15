import AppKit
import SwiftUI
import Carbon.HIToolbox

@main
@MainActor
struct TwentyThreeMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            _ = NSApplication.shared
            Snapshot.run(dir: args[i + 1])
            return
        }
        if args.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        if args.contains("--direction") { DirectionStudy.run(args); return }   // developer aid: visual direction study
        if let i = args.firstIndex(of: "--axdump"), i + 1 < args.count {
            _ = NSApplication.shared
            AX.dump(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--webdump"), i + 1 < args.count {
            _ = NSApplication.shared
            Task { @MainActor in await Chrome.dump(to: args[i + 1]); exit(0) }
            RunLoop.main.run()
        }
        // Developer aids for voice: speak text, or transcribe a recording (launch through `open` for permissions).
        if let i = args.firstIndex(of: "--fit"), i + 1 < args.count {
            // Developer aid: the "will it run here?" report for every size of a Hugging Face model.
            Task {
                do {
                    let installed = (try? await OllamaAdmin.installed()) ?? []
                    let ref = FitCheck.reference(installed: installed, loaded: await OllamaAdmin.loaded())
                    let d = try await HuggingFace.details(HuggingFace.repoID(from: args[i + 1]) ?? args[i + 1])
                    print("repo \(d.repo) arch=\(d.architecture ?? "?") params=\(d.parameters ?? 0) ctx=\(d.contextLength ?? 0) tools=\(String(describing: d.templateHasTools)) vision=\(d.hasVisionFile) ref=\(String(describing: ref))")
                    guard let mid = d.quants.first(where: { $0.tag.hasPrefix("Q4_K_M") }) ?? d.quants.first else { print("no gguf files"); exit(0) }
                    let h = try? await HuggingFace.header(d.repo, file: mid.files[0])
                    print("header from \(mid.files[0]): layers=\(h?.blockCount ?? -1) heads=\(h?.headCount ?? -1)/\(h?.headCountKV ?? -1) key=\(h?.keyLength ?? -1) interval=\(h?.fullAttentionInterval ?? 0) experts=\(h?.expertUsed ?? 0)/\(h?.expertCount ?? 0) kv16k=\(h?.kvCacheBytes(context: 16384) ?? -1)")
                    var reports: [String: FitReport] = [:]
                    for q in d.quants { reports[q.tag] = FitCheck.evaluate(fileBytes: q.bytes, header: h, templateHasTools: d.templateHasTools, hasVision: d.hasVisionFile, reference: ref) }
                    let rec = FitCheck.recommended(d.quants, reports: reports)
                    for q in d.quants {
                        let r = reports[q.tag]!
                        print(String(format: "  %@%-12@ %5.1f GB  need %5.1f / %4.1f GB  ~%4.1f tok/s  %@ · %@", q.tag == rec ? "★" : " ", q.tag, Double(q.bytes) / 1e9, Double(r.needBytes) / 1e9, Double(r.budgetBytes) / 1e9, r.tokensPerSecond ?? 0, r.verdict.rawValue, q.quality.label))
                    }
                    for n in reports[rec ?? ""]?.notes ?? [] { print("  note: " + n) }
                } catch { print("error: \(error.localizedDescription)") }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--model-delete"), i + 1 < args.count {   // developer aid: delete through 23's own code
            Task {
                do { try await OllamaAdmin.delete(args[i + 1]); print("deleted") } catch { print("error: \(error.localizedDescription)") }
                exit(0)
            }
            RunLoop.main.run()
        }
        if args.contains("--compact-test") {
            // Developer aid: a chat with a few long turns, then compacting, then a question about the very start.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let chat = ChatModel()
                chat.autoApprove = false
                @MainActor func ask(_ q: String) async {
                    chat.send(q)
                    while chat.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
                    print(String(format: "context %5d tokens (%2.0f%%) dropped=%@ | %@", chat.contextTokens, chat.contextFraction * 100, chat.droppedOldMessages ? "yes" : "no",
                                 String((chat.messages.last { $0.role == .assistant }?.text ?? "").prefix(90)).replacingOccurrences(of: "\n", with: " ")))
                }
                let filler = String(repeating: "The quarterly numbers were reviewed line by line and nothing unusual was found in this section. ", count: 60)
                await ask("Our project codename is Bluefin and the launch date is 3 March. Just say OK.")
                for i in 1...3 { await ask("Background note \(i), no need to answer beyond 'Noted': \(filler)") }
                await chat.performCompact()
                print("COMPACTED → \(chat.statusLine); summary:\n\(chat.contextSummary.prefix(600))")
                await ask("What is the project codename and launch date? One line.")
                exit(0)
            }
            app.run()
        }
        if args.contains("--retention-test") {
            // Developer aid: fake old chats and agent runs check the Bin rules, then everything the test made is removed.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                AgentRunner.shared.testMode = true
                let store = ConversationStore.shared, r = Retention.shared
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                var made: [UUID] = []
                @MainActor func fake(_ title: String, daysAgo: Double, pinned: Bool = false, agent: UUID? = nil) -> UUID {
                    let id = UUID(), d = Date().addingTimeInterval(-daysAgo * 86_400)
                    let f = ChatModel.File(id: id, title: title, created: d, updated: d, pinned: pinned, memory: [],
                                           messages: [ChatMessage(role: .user, text: "test")], api: Data("[]".utf8), agentID: agent)
                    try? enc.encode(f).write(to: ConversationStore.folder.appendingPathComponent("\(id.uuidString).json"))
                    made.append(id); return id
                }
                let old = fake("TEST old 40d", daysAgo: 40), pinned = fake("TEST pinned 400d", daysAgo: 400, pinned: true)
                let soon = fake("TEST 25d", daysAgo: 25), fresh = fake("TEST 3d", daysAgo: 3)
                var agent = Agent(name: "TEST agent"); agent.task = ""
                AgentStore.shared.add(agent)
                for i in 0..<23 { _ = fake("TEST run \(i)", daysAgo: Double(i) / 24, agent: agent.id) }
                store.loadSummaries()
                @MainActor func has(_ id: UUID) -> Bool { store.summaries.contains { $0.id == id } }
                Retention.days = 30
                r.check()
                let runsLeft = store.summaries.filter { $0.agentID == agent.id }.count
                print("first look: old still there=\(has(old)) (needs a week's notice first); 25-day announced=\(r.upcoming.contains { $0.id == soon }); 3-day announced=\(r.upcoming.contains { $0.id == fresh }); pinned announced=\(r.upcoming.contains { $0.id == pinned })")
                print("agent runs: 23 made, \(runsLeft) kept")
                // Pretend the heads-up went out 8 days ago.
                var told = (UserDefaults.standard.dictionary(forKey: "retentionAnnounced") as? [String: Date]) ?? [:]
                for k in told.keys { told[k] = Date().addingTimeInterval(-8 * 86_400) }
                UserDefaults.standard.set(told, forKey: "retentionAnnounced")
                r.check()
                print("a week later: old binned=\(!has(old)); 25-day still there=\(has(soon)) (only 25 days old); pinned still there=\(has(pinned))")
                r.keep(soon)
                print("kept the 25-day chat: no longer upcoming=\(!r.upcoming.contains { $0.id == soon })")
                // Clean up: remove the fakes for good (also from the Bin) and the test agent.
                for id in made {
                    try? FileManager.default.removeItem(at: ConversationStore.folder.appendingPathComponent("\(id.uuidString).json"))
                    let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                    for f in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] where f.hasPrefix(id.uuidString) {
                        try? FileManager.default.removeItem(at: trash.appendingPathComponent(f))
                    }
                }
                AgentStore.shared.delete(agent.id)
                UserDefaults.standard.removeObject(forKey: "retentionAnnounced")
                store.loadSummaries()
                print("cleaned up; TEST chats left: \(store.summaries.filter { $0.title.hasPrefix("TEST") }.count)")
                exit(0)
            }
            app.run()
        }
        if args.contains("--tidy-test") {     // developer aid: memory tidy-up suggestions (nothing is removed)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                print("memory: \(Memory.facts)")
                do { for s in try await MemoryTidy.suggest() { print("suggest: \(s.fact) — \(s.reason)") }; print("done") } catch { print("error \(error)") }
                exit(0)
            }
            app.run()
        }
        if args.contains("--addon-policy-test") {    // developer aid: how each REA tool is treated, and the iCloud refusal
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                await AddonStore.shared.loadAll()
                let list = AddonStore.shared.tools["rea"] ?? []
                let asks = list.filter { AddonTools.approvalReason("use_tool", ["server": "rea", "tool": $0.name]) != nil }.map(\.name)
                print("REA tools: \(list.count); free: \(list.count - asks.count); ask first: \(asks.count)")
                print("ask first: " + asks.sorted().joined(separator: " "))
                print("free: " + list.map(\.name).filter { !asks.contains($0) }.sorted().joined(separator: " "))
                do { _ = try await AddonTools.run("use_tool", ["server": "rea", "tool": "open_binary", "arguments": ["path": NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/a.app"]]); print("iCloud: NOT refused") }
                catch { print("iCloud: refused — \(error.localizedDescription)") }
                print("secret file asks: \(AddonTools.approvalReason("use_tool", ["server": "rea", "tool": "open_binary", "arguments": ["path": "~/.ssh/id_ed25519"]]) ?? "no")")
                AddonStore.shared.stopAll()
                exit(0)
            }
            app.run()
        }
        if let i = args.firstIndex(of: "--install-test"), i + 2 < args.count {
            // Developer aid: find (registry|skills|link) → download → Claude review → install → start → remove again.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    let src = args[i + 1], q = args[i + 2]
                    let found: [AddonCandidate] = src == "registry" ? try await AddonCatalog.searchRegistry(q)
                        : src == "skills" ? try await AddonCatalog.anthropicSkills(matching: q) : [try await AddonCatalog.fromLink(q)]
                    print("found \(found.count): " + found.prefix(6).map { "\($0.title)\($0.unsupported == nil ? "" : " [\($0.unsupported!)]")" }.joined(separator: " | "))
                    guard let c = found.first(where: { $0.unsupported == nil }) else { print("nothing installable"); exit(0) }
                    var t = Date()
                    let dir = try await AddonInstaller.download(c)
                    print(String(format: "downloaded %@ in %.0f s (%@)", c.title, Date().timeIntervalSince(t), Storage.size(of: dir).formatted(.byteCount(style: .file))))
                    let hooks = (try? FileManager.default.contentsOfDirectory(atPath: dir.path + "/node_modules/.hooks")) ?? []
                    _ = hooks
                    t = Date()
                    let r = try await AddonInstaller.review(c, at: dir)
                    print(String(format: "review in %.0f s: risk=%@ internet=%@", Date().timeIntervalSince(t), r.risk, r.needsInternet ? "yes" : "no"))
                    print("  what: \(r.whatItDoes)\n  touches: \(r.touches)\n  flags: \(r.redFlags)\n  verdict: \(r.verdict)")
                    try AddonInstaller.install(c, from: dir, review: r, network: r.needsInternet, readOnlyFree: false, values: [:])
                    if c.kind == .npmServer {
                        _ = try await AddonStore.shared.connection(c.id)
                        let tools = AddonStore.shared.tools[c.id] ?? []
                        print("started in sandbox: \(tools.count) tools: \(tools.prefix(8).map(\.name).joined(separator: ", "))")
                        if let echo = tools.first(where: { $0.name == "echo" }) {
                            print("echo asks first: \(AddonTools.approvalReason("use_tool", ["server": c.id, "tool": echo.name]) ?? "no")")
                            print("echo → " + (try await AddonTools.run("use_tool", ["server": c.id, "tool": "echo", "arguments": ["message": "hello from 23"]])))
                        }
                        AddonStore.shared.remove(c.id)
                    } else {
                        print("skill installed: \(SkillStore.shared.skills.map(\.name)); read_skill → " + (try await AddonTools.run("read_skill", ["name": c.id])).prefix(160).replacingOccurrences(of: "\n", with: " "))
                        SkillStore.shared.remove(c.id)
                    }
                    print("removed again")
                } catch { print("error: \(error.localizedDescription)") }
                exit(0)
            }
            app.run()
        }
        if args.contains("--remote-test") {
            // Developer aid, run with `defaults write TwentyThree remoteHost <mini>`: this copy acts as the MacBook.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                print("remote mode: \(Remote.active) → \(Remote.host)")
                do {
                    print("hello: \(try await RemoteClient.hello())")
                    print("chats on the mini: \(try await RemoteClient.summaries().count)")
                    @MainActor func run(_ c: ChatModel, _ text: String, decline: Bool = false) async {
                        c.send(text)
                        var t = 0
                        while t < 3000 {
                            try? await Task.sleep(nanoseconds: 100_000_000); t += 1
                            if decline, let card = c.messages.last(where: { $0.action?.status == .awaitingApproval }) {
                                print("  approval card arrived: \(card.action!.title) → answering NO from the remote"); c.answerApproval(card.id, approved: false)
                            }
                            if t > 20 && !c.isBusy && !c.isPaused { break }
                        }
                        print("  state=\(c.state) status=\(c.statusLine) context=\(c.contextTokens)")
                        for m in c.messages where m.role == .action { print("  action: \(m.action!.title) → \(m.action!.status)") }
                        print("  answer: \(c.messages.last { $0.role == .assistant }?.text.prefix(200) ?? "-")")
                    }
                    let chat = ConversationStore.shared.newChat()
                    let t0 = Date()
                    await run(chat, "Reply with exactly: hello from the mini")
                    print(String(format: "  round trip %.1f s", Date().timeIntervalSince(t0)))
                    try? "x".write(toFile: NSHomeDirectory() + "/Desktop/23-remote-test.txt", atomically: true, encoding: .utf8)
                    await run(chat, "Put the file 23-remote-test.txt on my Desktop in the Trash (use trash_file).", decline: true)
                    print("  file still on the Desktop: \(FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Desktop/23-remote-test.txt"))")
                    try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Desktop/23-remote-test.txt")
                    let wav = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments.last!))
                    print("transcribed on the mini: “\(try await Voice.shared.transcribeWithWhisper(wav))”")
                    var req = URLRequest(url: Remote.base!.appendingPathComponent("v1/audio/speech")); req.httpMethod = "POST"
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["model": "tts-1", "input": "Hello from the mini.", "response_format": "pcm", "voice": "af_heart"])
                    let (pcm, _) = try await URLSession.shared.data(for: req)
                    print(String(format: "speech from the mini: %d bytes = %.1f s of audio", pcm.count, Double(pcm.count) / 48_000))
                    try await RemoteClient.post(chat.id, "delete")
                    print("test chat deleted on the mini")
                } catch { print("error: \(error.localizedDescription)") }
                exit(0)
            }
            app.run()
        }
        if let i = args.firstIndex(of: "--setup-test"), i + 1 < args.count {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                await Setup.shared.refresh()
                for it in Setup.shared.items { print("\(it.required ? "needed  " : "optional") \(it.title): \(it.status)") }
                print("essentials ready: \(Setup.shared.essentialsReady); recommended model here: \(Setup.recommendedModel.label)")
                await Setup.shared.selfCheck(in: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            }
            app.run()
        }
        if args.contains("--agent-test") {
            // Developer aid: a throwaway agent watches a scratch folder; a new file starts a run by itself, which has
            // to pause for an approval while a normal chat still works; then everything made by the test is removed.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let runner = AgentRunner.shared, agents = AgentStore.shared, store = ConversationStore.shared
                runner.testMode = true
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("23-agent-test-\(UUID().uuidString.prefix(6))")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? "old".write(to: dir.appendingPathComponent("already-here.txt"), atomically: true, encoding: .utf8)
                var a = Agent(name: "Test inbox", symbol: "tray", instructions: "You look after a test inbox folder.",
                              task: "Read each new file, say in one line what it contains, then move it to the Bin.")
                a.folder = dir.path; a.watchFolder = dir.path
                a.abilities = .init(files: true, web: false, webTyping: false, downloads: false, code: true, commands: false, memory: false)
                agents.add(a)
                @MainActor func log(_ s: String) { print(s); Visualizer.shared.log("agent-test: " + s) }
                log("web allowed for agent: \(a.allows("web_search")); files: \(a.allows("move_file")); commands: \(a.allows("run_command")); hand-off: \(a.allows("hand_off_to_claude"))")
                runner.tick()                                   // first look: learns already-here.txt, no run
                log("after first look: queue=\(runner.queue.count) active=\(runner.active.count)")
                try? "Invoice 77 from Acme, 120 dollars, due Friday.".write(to: dir.appendingPathComponent("invoice-77.txt"), atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: dir.appendingPathComponent("invoice-77.txt").path)
                runner.tick()
                guard let chatID = runner.active.keys.first, let run = store.chat(chatID) else { log("FAIL: no run started"); exit(1) }
                log("run started: “\(run.title)” unattended=\(run.unattended) agent=\(run.agent?.name ?? "-") busy=\(run.isBusy)")
                var waited = 0
                while !run.isPaused && run.isBusy && waited < 1200 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
                log("paused for approval: \(run.isPaused) (busy=\(run.isBusy))")
                if run.isPaused {
                    let other = ChatModel()
                    other.send("Reply with just the word: hello")
                    while other.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
                    log("a normal chat ran meanwhile: “\(other.messages.last { $0.role == .assistant }?.text ?? "nothing")”")
                    if let card = run.messages.last(where: { $0.action?.status == .awaitingApproval }) {
                        log("approval asked: \(card.action!.title) — answering NO")
                        run.answerApproval(card.id, approved: false)
                    }
                }
                while run.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
                runner.tick()                                   // notices the run finished
                for m in run.messages where m.role == .action { log("  action: \(m.action!.title) → \(m.action!.status)") }
                log("report: \(run.messages.last { $0.role == .assistant }?.text.prefix(300) ?? "-")")
                log("file still there (declined): \(FileManager.default.fileExists(atPath: dir.appendingPathComponent("invoice-77.txt").path))")
                log("saved with agent: \(store.summaries.contains { $0.id == chatID && $0.agentID == a.id })")
                // Clean up everything the test made.
                store.delete(chatID)
                agents.delete(a.id)
                try? FileManager.default.removeItem(at: dir)
                log("cleaned up")
                exit(0)
            }
            app.run()
        }
        if args.contains("--duplex-test") {
            // Developer aid: mic on for 3 s, mic off, then speak, logging the playback engine (AirPods switch modes here).
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                if args.contains("--speak-first") {
                    Voice.shared.say("Hi.")
                    await Voice.shared.waitUntilQuiet()
                    Visualizer.shared.log("duplex: first line done; " + Voice.shared.playbackDebug)
                }
                Voice.shared.startListening { err in Visualizer.shared.log("duplex: mic \(err?.localizedDescription ?? "on")") }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                _ = try? await Voice.shared.stopListening()
                Visualizer.shared.log("duplex: mic off, speaking")
                let start = Date()
                Voice.shared.say("This is 23, testing my voice right after the microphone. Can you hear me?")
                let probe = Task { @MainActor in
                    while true { Visualizer.shared.log("duplex: " + Voice.shared.playbackDebug); try? await Task.sleep(nanoseconds: 500_000_000) }
                }
                let quiet = Task { await Voice.shared.waitUntilQuiet() }
                for _ in 0..<40 where Date().timeIntervalSince(start) < 20 { try? await Task.sleep(nanoseconds: 500_000_000); if Voice.shared.speaking == false && Date().timeIntervalSince(start) > 2 { break } }
                probe.cancel(); quiet.cancel()
                Visualizer.shared.log(String(format: "duplex: finished=%@ after %.1f s, engine=%@", Voice.shared.speaking ? "NO (stuck)" : "yes", Date().timeIntervalSince(start), Voice.shared.engineName))
                exit(0)
            }
            app.run()
        }
        if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let start = Date()
                Voice.shared.say(args[i + 1])
                await Voice.shared.waitUntilQuiet()
                Visualizer.shared.log(String(format: "say: engine=%@ spoke for %.1f s (first audio after %.2f s)", Voice.shared.engineName,
                                             Date().timeIntervalSince(start), Voice.shared.firstAudioDelay ?? -1))
                exit(0)
            }
            app.run()
        }
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    let text = try await Voice.shared.transcribe(file: URL(fileURLWithPath: args[i + 1]))
                    Visualizer.shared.log("transcribe (\(Voice.shared.engineName)): \(text)")
                } catch { Visualizer.shared.log("transcribe FAILED: \(error.localizedDescription)") }
                exit(0)
            }
            app.run()
        }
        if let i = args.firstIndex(of: "--stream-test"), i + 1 < args.count {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in await Voice.shared.streamTest(file: URL(fileURLWithPath: args[i + 1])); exit(0) }
            app.run()
        }
        if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
            // Headless agent test. Launch through `open -a /Applications/23.app --args --ask "…"` so macOS
            // grants it Accessibility (needed for visuals and the browser); output also goes to ~/Library/Logs/23.log.
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let chat = ChatModel()
            chat.autoApprove = args.contains("--approve")
            Task { @MainActor in
                Visualizer.shared.orbPoint = { CGPoint(x: 1640, y: 220) }
                // `--attach a.png,b.pdf` sends files with the question (developer aid for attachments).
                var atts: [Attachment] = []
                if let k = args.firstIndex(of: "--attach"), k + 1 < args.count {
                    for p in args[k + 1].split(separator: ",") {
                        do { atts.append(try AttachmentStore.add(URL(fileURLWithPath: String(p)))) } catch { print("ATTACH REFUSED: \(error.localizedDescription)") }
                    }
                }
                chat.send(args[i + 1], attachments: atts)
                while chat.isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
                var out = "ASK: \(args[i + 1])\n"
                for m in chat.messages where m.role == .action {
                    out += "ACTION: \(m.action!.title) → \(m.action!.status) | \(m.action!.detail.prefix(200))\n"
                    if m.action!.tool == "attachment" && !m.action!.output.isEmpty { out += "  CLAUDE SAW: \(m.action!.output.prefix(400).replacingOccurrences(of: "\n", with: " ⏎ "))\n" }
                }
                out += "STATE: \(chat.state) | \(chat.statusLine)\n"
                out += "ANSWER: \(chat.messages.last(where: { $0.role == .assistant })?.text ?? "")"
                await Voice.shared.waitUntilQuiet()
                out += "\nVOICE: \(Voice.shared.spokenCount) sentence(s) spoken with \(Voice.shared.engineName)"
                print(out)
                Visualizer.shared.log(out)
                exit(0)
            }
            app.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        // Developer aid: `--vistest <tool> key=value …` launches normally, plays one choreographed action
        // (no model involved), logs the result and quits.
        if let i = args.firstIndex(of: "--vistest"), i + 1 < args.count {
            var toolArgs: [String: Any] = [:]
            for kv in args.dropFirst(i + 2) {
                guard let eq = kv.firstIndex(of: "=") else { continue }
                toolArgs[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
            delegate.visTest = (args[i + 1], toolArgs)
        }
        app.delegate = delegate
        app.setActivationPolicy(.regular)     // a proper app: Dock icon, menus, main window
        app.run()
    }
}

/// 23's main window: a normal app window (sidebar · chat · details), not a floating panel.
final class MainWindow: NSWindow {
    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1180, screen.width - 80), height: min(780, screen.height - 60))
        super.init(contentRect: NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "23"
        isReleasedWhenClosed = false
        isOpaque = false                 // the content is one sheet of system glass over whatever is behind
        backgroundColor = .clear
        minSize = NSSize(width: 760, height: 520)
        isMovableByWindowBackground = true
        // An empty unified toolbar gives the window its taller title area, so the system places the
        // close, minimise and zoom buttons lower and further in, inside the sidebar pane rather than on its edge.
        let bar = NSToolbar(identifier: "main")
        bar.showsBaselineSeparator = false
        toolbar = bar
        toolbarStyle = .unified
        setFrameAutosaveName("TwentyThreeMainWindow")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: MainWindow!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var talkKeyRef: EventHotKeyRef?
    private var listenerKeyRef: EventHotKeyRef?
    private let store = ConversationStore.shared
    private var chat: ChatModel { store.current }
    var visTest: (String, [String: Any])?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }     // developer aids
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        buildMainMenu()
        buildWindow()
        buildStatusItem()
        registerHotKey()
        // The AI cursor starts at the orb in the sidebar, and the window fades if something it's acting on is behind it.
        Visualizer.shared.orbPoint = { [weak self] in
            if let p = ListenerController.shared.presencePoint { return p }
            guard let w = self?.window, w.isVisible, !w.isMiniaturized else { return nil }
            let f = AX.axRect(w.frame)
            let home = PresenceHome.pointInWindow ?? CGPoint(x: f.width / 2, y: f.height - 60)
            return CGPoint(x: f.minX + home.x, y: f.minY + home.y)
        }
        Visualizer.shared.panelRect = { [weak self] in
            guard let w = self?.window, w.isVisible, !w.isMiniaturized else { return nil }
            return AX.axRect(w.frame)
        }
        Visualizer.shared.setPanelDimmed = { [weak self] dim in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self?.window.animator().alphaValue = dim ? 0.12 : 1 }
        }
        ListenerController.shared.openMainWindow = { [weak self] in self?.showWindow() }
        // Agents that run by themselves; a notification click opens that run's chat.
        AgentRunner.shared.openChat = { [weak self] id in ConversationStore.shared.select(id); self?.showWindow() }
        AgentRunner.shared.openStorage = { [weak self] in
            ConversationStore.shared.page = .settings; SettingsView.jump(to: .storage); self?.showWindow()
        }
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) || CommandLine.arguments.contains("--serve") {   // not in developer runs
            if Remote.active {
                Visualizer.shared.log("remote mode: using 23 on \(Remote.host)")
                Task { @MainActor in await Remote.learnAddressIfNeeded() }
            } else {
                Task { @MainActor in
                    // First launch: maybe this Mac is a remote for another; otherwise make sure the essentials are here.
                    if !UserDefaults.standard.bool(forKey: "askedRemoteSetup"), await RemoteSetup.offerIfNeeded() { return }
                    await Setup.shared.refresh()
                    if !Setup.shared.essentialsReady {
                        ConversationStore.shared.page = .settings
                        SettingsView.jump(to: .setup)
                        self.showWindow()
                    }
                }
            }
            if !Remote.active {
                AgentRunner.shared.start()
                Retention.shared.start()
                RemoteServer.shared.start()
            }
        }
        // Developer aids: `--listener` opens the floating listener as a menu bar click would;
        // `--listener-demo "words"` plays those words in as if spoken, then sends them.
        if let i = CommandLine.arguments.firstIndex(of: "--listener-demo"), i + 1 < CommandLine.arguments.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                ListenerController.shared.show(below: statusItem.button, demo: CommandLine.arguments[i + 1])
            }
            return
        }
        if CommandLine.arguments.contains("--listener") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in ListenerController.shared.show(below: statusItem.button) }
            return
        }
        showWindow()
        if CommandLine.arguments.contains("--mic-test") {   // developer aid: press the mic button and report what happens
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                chat.toggleListening()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                    Visualizer.shared.log("mic-test: state=\(chat.state) status=\(chat.statusLine) hasMic=\(Voice.hasMicrophone)")
                    if chat.state == .listening { chat.stop() }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        // Developer aid: `--gui-script "+" "message" "+" "message" …` drives the real window: "+" starts a new chat,
        // anything else is sent to the current chat. Results go to the log; the app stays open for screenshots.
        if let i = CommandLine.arguments.firstIndex(of: "--gui-script") {
            let steps = Array(CommandLine.arguments.dropFirst(i + 1))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                var chats: [ChatModel] = []
                for step in steps {
                    if step == "+" { chats.append(store.newChat()); continue }
                    let c = store.current
                    c.autoApprove = false          // scripted runs never sit waiting for a click
                    if chats.last !== c { chats.append(c) }
                    c.send(step)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    while c.isBusy { try? await Task.sleep(nanoseconds: 200_000_000) }
                    let answer = c.messages.last(where: { $0.role == .assistant })?.text ?? "(no answer)"
                    let acts = c.messages.compactMap { $0.action }.suffix(3).map { "\($0.title) → \($0.status)" }
                    Visualizer.shared.log("gui-script [\(c.title)] Q: \(step)\n  A: \(answer.prefix(300))\n  actions: \(acts)\n  chat notes: \(c.chatMemory)")
                }
                Visualizer.shared.log("gui-script done; all-chats memory: \(Memory.facts)")
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--agents-page") {   // developer aid: the Agents page (optionally one agent open)
            store.page = .agents
            if i + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]), n < AgentStore.shared.agents.count {
                store.agentSelection = AgentStore.shared.agents[n].id
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--settings"), i + 1 < CommandLine.arguments.count {   // developer aid
            store.page = .settings
            store.settingsSection = SettingsSection.allCases.first { $0.rawValue.lowercased().hasPrefix(CommandLine.arguments[i + 1].lowercased()) } ?? .general
            if let h = CommandLine.arguments.firstIndex(of: "--hf"), h + 1 < CommandLine.arguments.count {   // pre-fill a model search / link
                ModelStore.shared.query = CommandLine.arguments[h + 1]
                Task { await ModelStore.shared.refresh(); await ModelStore.shared.search() }
            }
            return
        }
        if CommandLine.arguments.contains("--demo-cards") {   // developer aid: show sample code-tool cards (not saved)
            if CommandLine.arguments.contains("working") {      // a command in mid-run, with 23 still busy
                var m = Array(Snapshot.codeDemo().prefix(3))
                m[2].action?.status = .running
                m[2].action?.output = "First 15 Fibonacci numbers:\n 1. 0\n 2. 1\n 3. 1\n 4. 2\n 5. 3"
                m.append(ChatMessage(role: .assistant, text: "", thinking: "The loop now runs to 15.\nNext I should check the last value is 377 and then install requests."))
                chat.messages = m
                chat.state = .acting
                chat.statusLine = "Running python3 fib.py…"
                return
            }
            chat.messages = CommandLine.arguments.contains("diff") ? Array(Snapshot.codeDemo().prefix(2)) : Snapshot.codeDemo()
            chat.state = .acting
            chat.statusLine = "Waiting for your approval…"
            return
        }
        // Ask for folder access now (one-time macOS prompts) rather than in the middle of an animated action.
        for root in FileTools.allowedRoots { _ = try? FileManager.default.contentsOfDirectory(atPath: root.path) }
        if let (name, args) = visTest {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                do {
                    if BrowserTools.names.contains(name) {
                        let text = try await BrowserTools.run(name, args)
                        Visualizer.shared.log("vistest OK: \(text.text.prefix(1500))")
                    } else {
                        let r = try await Visualizer.shared.perform(name, args) { try FileTools.run(name, args) }
                        Visualizer.shared.log("vistest OK: \(r.summary)")
                    }
                } catch {
                    Visualizer.shared.log("vistest FAILED: \(error)")
                }
                NSApp.terminate(nil)
            }
            return
        }
        chat.warmUp()
    }

    /// Closing the window keeps 23 running (menu bar and hotkeys still work); the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func buildWindow() {
        window = MainWindow()
        window.contentView = NSHostingView(rootView: RootView(store: store))
    }

    /// Standard menus, so copy/paste, ⌘N, ⌘, and window commands all work.
    private func buildMainMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            item.submenu = m
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        menu("23", [item("About 23", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
                    item("Settings…", #selector(openSettings), ",", target: self), .separator(),
                    item("Hide 23", #selector(NSApplication.hide(_:)), "h"),
                    item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                    item("Show All", #selector(NSApplication.unhideAllApplications(_:))), .separator(),
                    item("Quit 23", #selector(NSApplication.terminate(_:)), "q")])
        menu("File", [item("New Chat", #selector(newConversation), "n", target: self), .separator(),
                      item("Close Window", #selector(NSWindow.performClose(_:)), "w")])
        menu("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                      item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                      item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
        menu("View", [item("Toggle Sidebar", #selector(toggleSidebar), "s", [.command, .control], target: self),
                      item("Toggle Details", #selector(toggleDetails), "i", [.command, .option], target: self)])
        menu("Window", [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), item("Zoom", #selector(NSWindow.performZoom(_:))),
                        .separator(), item("Show 23", #selector(showWindowAction), "0", target: self)])
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { showWindow(); store.page = .settings }
    @objc private func toggleSidebar() { NotificationCenter.default.post(name: .toggleSidebar, object: nil) }
    @objc private func toggleDetails() { store.showInspector.toggle() }
    @objc private func showWindowAction() { showWindow() }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarMark.image(needsYou: false)
        statusItem.button?.setAccessibilityLabel("23")
        // The mark takes the accent colour only while 23 is waiting for an approval, so you notice even with the window closed.
        var asking = false
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let chat = ChatModel.running ?? self.store.current
                let agentWaiting = AgentRunner.shared.active.keys.contains { self.store.chat($0)?.isPaused == true }
                let now = agentWaiting || chat.messages.contains { $0.action?.status == .awaitingApproval }
                guard now != asking else { return }
                asking = now
                self.statusItem.button?.image = MenuBarMark.image(needsYou: now)
                self.statusItem.button?.setAccessibilityLabel(now ? "23, waiting for your approval" : "23")
            }
        }
        // A click opens the floating listener; a right-click (or ⌃-click) opens the menu.
        let menu = NSMenu()
        menu.addItem(withTitle: "Open 23", action: #selector(showWindowAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Chat", action: #selector(newConversation), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let hint = menu.addItem(withTitle: "⌥3 talk to 23 · ⌥Space show or hide · hold ⌃⌥Space push to talk", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit 23", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusMenu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private var statusMenu: NSMenu?

    @objc private func statusItemClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            ListenerController.shared.toggle(below: statusItem.button)
        }
    }

    @objc func togglePanel() {
        if window.isVisible && window.isKeyWindow && NSApp.isActive { NSApp.hide(nil) } else { showWindow() }
    }

    @objc func newConversation() { store.newChat(); showWindow() }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .focusInput, object: nil)
    }

    /// Global ⌥Space hotkey (Carbon API: needs no Accessibility permission).
    /// ⌥Space shows/hides 23. Hold ⌃⌥Space to talk: the mic is on only while the keys are held.
    private func registerHotKey() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                if id.id == 1 { if pressed { me.togglePanel() } }
                else if id.id == 3 { if pressed { ListenerController.shared.toggle(below: me.statusItem.button) } }
                else if id.id == 2 { pressed ? me.startTalking() : me.chatFinishListening() }
            }
            return noErr
        }, 2, &specs, selfPtr, nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x32335F5F), id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)                 // "23__" ⌥Space
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | controlKey), EventHotKeyID(signature: OSType(0x32335F5F), id: 2),
                            GetApplicationEventTarget(), 0, &talkKeyRef)                // ⌃⌥Space (hold to talk)
        RegisterEventHotKey(UInt32(kVK_ANSI_3), UInt32(optionKey), EventHotKeyID(signature: OSType(0x32335F5F), id: 3),
                            GetApplicationEventTarget(), 0, &listenerKeyRef)            // ⌥3 (floating listener)
    }

    private func startTalking() {
        if !window.isVisible { showWindow() }
        chat.startListening()
    }

    private func chatFinishListening() { chat.finishListening() }
}

/// 23's mark in the menu bar: two drops joining, sized 2 to 3 (the same shape as the app icon).
enum MenuBarMark {
    static func image(needsYou: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            (needsYou ? NSColor.controlAccentColor : NSColor.black).setFill()
            path(big: CGPoint(x: 7.3, y: 10.9), r1: 5.1, small: CGPoint(x: 13.75, y: 5.4), r2: 3.4).fill()
            return true
        }
        img.isTemplate = !needsYou
        return img
    }

    /// Two circles and the liquid bridge between them.
    static func path(big c1: CGPoint, r1: CGFloat, small c2: CGPoint, r2: CGFloat, spread v: CGFloat = 0.5) -> NSBezierPath {
        let p = NSBezierPath()
        p.appendOval(in: NSRect(x: c1.x - r1, y: c1.y - r1, width: r1 * 2, height: r1 * 2))
        p.appendOval(in: NSRect(x: c2.x - r2, y: c2.y - r2, width: r2 * 2, height: r2 * 2))
        let d = hypot(c2.x - c1.x, c2.y - c1.y)
        let overlap = d < r1 + r2
        let u1 = overlap ? acos((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d)) : 0
        let u2 = overlap ? acos((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d)) : 0
        let between = atan2(c2.y - c1.y, c2.x - c1.x)
        let maxSpread = acos((r1 - r2) / d)
        let a1 = between + u1 + (maxSpread - u1) * v, a2 = between - u1 - (maxSpread - u1) * v
        let a3 = between + .pi - u2 - (.pi - u2 - maxSpread) * v, a4 = between - .pi + u2 + (.pi - u2 - maxSpread) * v
        func on(_ c: CGPoint, _ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r) }
        let p1 = on(c1, a1, r1), p2 = on(c1, a2, r1), p3 = on(c2, a3, r2), p4 = on(c2, a4, r2)
        let handle = min(v * 2.4, hypot(p1.x - p3.x, p1.y - p3.y) / (r1 + r2)) * min(1, d * 2 / (r1 + r2))
        let h1 = on(p1, a1 - .pi / 2, r1 * handle), h2 = on(p2, a2 + .pi / 2, r1 * handle)
        let h3 = on(p3, a3 + .pi / 2, r2 * handle), h4 = on(p4, a4 - .pi / 2, r2 * handle)
        let bridge = NSBezierPath()
        bridge.move(to: p1)
        bridge.curve(to: p3, controlPoint1: h1, controlPoint2: h3)
        bridge.line(to: p4)
        bridge.curve(to: p2, controlPoint1: h4, controlPoint2: h2)
        bridge.close()
        p.append(bridge)
        p.windingRule = .nonZero
        return p
    }
}

extension Notification.Name {
    static let focusInput = Notification.Name("TwentyThreeFocusInput")
}
