import AVFoundation
import Speech

/// 23's voice: push-to-talk listening and spoken replies.
///  • Speech goes through VoiceStudio's local API (http://127.0.0.1:3900) when it's running;
///    otherwise macOS's built-in voice and ON-DEVICE recognizer (audio never goes to Apple's servers).
///  • The microphone is only on while the user holds the key / has the mic button on. No wake word.
@MainActor
final class Voice: ObservableObject {
    static let shared = Voice()

    enum Mode: String, CaseIterable { case auto, always, off }   // auto = speak replies to spoken questions

    @Published var listening = false
    @Published var speaking = false
    @Published var engineName = "…"
    /// Sentences spoken since launch (for tests and the log).
    var spokenCount = 0
    /// Seconds from the first sentence being queued to its audio starting (for tests and the log).
    var firstAudioDelay: Double?
    private var firstQueuedAt: Date?

    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "voiceMode") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "voiceMode"); objectWillChange.send() }
    }
    /// VoiceStudio voice to use (empty = its default).
    var voiceID: String {
        get { UserDefaults.standard.string(forKey: "voiceStudioVoice") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceStudioVoice") }
    }

    /// Live loudness 0…1 (mic while listening, playback while speaking), for the orb.
    var onLevel: (Double) -> Void = { _ in }
    var onSpeakingChanged: (Bool) -> Void = { _ in }
    /// Called when the 60-second recording cap is reached (treated like letting go of the key).
    var onCapReached: () -> Void = {}

    static let base = URL(string: "http://127.0.0.1:3900")!

    enum VoiceError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    // MARK: Is VoiceStudio running?

    private var lastCheck = Date.distantPast
    private var studioUp = false

    func voiceStudioAvailable() async -> Bool {
        if Date().timeIntervalSince(lastCheck) < 20 { return studioUp }
        var req = URLRequest(url: Self.base.appendingPathComponent(".well-known/voicestudio-speech"))
        req.timeoutInterval = 1.0
        let ok = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
        studioUp = ok
        lastCheck = Date()
        engineName = ok ? "VoiceStudio" : "macOS voice"
        return ok
    }

    // MARK: Light local engines: whisper.cpp (listening) and Kokoro (speaking)

    static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/23")
    static let whisperCLI = "/opt/homebrew/bin/whisper-cli"
    static let whisperModel = support.appendingPathComponent("models/ggml-small.en.bin")
    static let kokoroPython = support.appendingPathComponent("kokoro-venv/bin/python")
    /// The voice server script ships inside 23.app (Resources); older setups have it in Application Support.
    static let kokoroServer: URL = Bundle.main.url(forResource: "kokoro_server", withExtension: "py") ?? support.appendingPathComponent("kokoro_server.py")
    static let kokoroVoices = support.appendingPathComponent("models/voices-v1.0.bin")
    static let kokoroPort = 3910
    static let kokoroBase = URL(string: "http://127.0.0.1:\(kokoroPort)")!
    /// "int8" (compact, ~0.4 GB, fastest) or "full" (~0.7 GB). Menu: 23 → Voice replies.
    var kokoroQuality: String {
        get { UserDefaults.standard.string(forKey: "kokoroQuality") ?? "int8" }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroQuality") }
    }
    /// Kokoro voice, e.g. af_heart (US), bf_emma (British), am_michael (US male), bm_george (British male).
    var kokoroVoice: String {
        get { UserDefaults.standard.string(forKey: "kokoroVoice") ?? "af_heart" }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroVoice") }
    }
    private var kokoroModel: URL {
        Self.support.appendingPathComponent(kokoroQuality == "full" ? "models/kokoro-v1.0.onnx" : "models/kokoro-v1.0.int8.onnx")
    }

    var whisperInstalled: Bool {
        if Remote.active { return true }         // the other Mac transcribes
        return FileManager.default.isExecutableFile(atPath: Self.whisperCLI) && FileManager.default.fileExists(atPath: Self.whisperModel.path)
    }
    var kokoroInstalled: Bool {
        [Self.kokoroPython.path, Self.kokoroServer.path, Self.kokoroVoices.path, kokoroModel.path].allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    private func kokoroHealthy() async -> Bool {
        var req = URLRequest(url: Self.kokoroBase.appendingPathComponent("health"))
        req.timeoutInterval = 0.5
        return ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    private var kokoroStarting: Task<Bool, Never>?

    /// Starts the Kokoro server if it isn't running (it stops itself after 5 idle minutes). Returns when it's ready.
    @discardableResult
    func ensureKokoro() async -> Bool {
        if Remote.active { return true }         // the other Mac speaks (its Kokoro), the audio plays here
        guard kokoroInstalled else { return false }
        if await kokoroHealthy() { return true }
        if let t = kokoroStarting { return await t.value }
        let t = Task { @MainActor () -> Bool in
            let p = Process()
            p.executableURL = Self.kokoroPython
            p.arguments = ["-I", Self.kokoroServer.path, kokoroModel.path, Self.kokoroVoices.path, String(Self.kokoroPort), "300"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            for _ in 0..<60 {                       // up to ~12 s on a cold start
                try? await Task.sleep(nanoseconds: 200_000_000)
                if await kokoroHealthy() { return true }
            }
            return false
        }
        kokoroStarting = t
        let ok = await t.value
        kokoroStarting = nil
        return ok
    }

    /// Stops the Kokoro server (e.g. to switch models); the next sentence starts it again.
    func restartKokoro() {
        stopSpeaking()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", Self.kokoroServer.path]
        try? p.run()
    }

    /// whisper.cpp, loaded only for the moment it transcribes (no memory used in between).
    func transcribeWithWhisper(_ wav: Data) async throws -> String {
        if Remote.active {
            let (d, code) = try await RemoteClient.request("POST", "/v1/transcribe", body: wav, timeout: 60)
            guard code == 200, let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { throw VoiceError.message("\(Remote.host) couldn't transcribe that (\(code)).") }
            return o["text"] ?? ""
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("23-speech-\(UUID().uuidString).wav")
        try wav.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.whisperCLI)
        p.arguments = ["-m", Self.whisperModel.path, "-f", file.path, "-l", "en", "-nt", "-np"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data: Data = await withCheckedContinuation { c in
            DispatchQueue.global().async { let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); c.resume(returning: d) }
        }
        guard p.terminationStatus == 0 else { throw VoiceError.message("whisper.cpp couldn't transcribe that (exit \(p.terminationStatus)).") }
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"\[(BLANK_AUDIO|MUSIC|NOISE|SILENCE)[^\]]*\]|\((music|silence|noise)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Listening (push-to-talk)

    private let engine = AVAudioEngine()
    private var samples = [Int16]()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var listenStarted = Date()

    /// Live words: what whisper makes of the recording so far, refreshed while you speak.
    @Published var partial = ""
    /// When on, listening ends by itself once you have spoken and then been quiet for a moment.
    var autoStop = false
    var onSilence: () -> Void = {}
    private var heardSpeech = false
    private var lastLoud = Date()
    private var partialTask: Task<Void, Never>?

    /// Re-transcribes the growing recording about once a second. Only one run at a time, and only when there is new audio.
    private func startPartials() {
        partial = ""
        partialTask?.cancel()
        guard whisperInstalled else { return }
        partialTask = Task { [weak self] in
            var done = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self, self.listening else { return }
                let n = self.samples.count
                guard n >= 12_000, n - done >= 8_000 else { continue }
                done = n
                if let text = try? await self.transcribeWithWhisper(Self.wav(self.samples, rate: 16_000)), self.listening, !Task.isCancelled {
                    self.partial = text
                }
            }
        }
    }

    /// Developer aid (`--stream-test file.wav`): feeds a recording in as if it were being spoken and logs the live words.
    func streamTest(file: URL) async {
        guard let wav = try? Data(contentsOf: file), wav.count > 44 else { return Visualizer.shared.log("stream-test: can't read \(file.path)") }
        let all = wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let start = Date()
        var fed = 0
        while fed < all.count {
            fed = min(all.count, fed + 16_000)
            let t0 = Date()
            let text = (try? await transcribeWithWhisper(Self.wav(Array(all[..<fed]), rate: 16_000))) ?? "(failed)"
            Visualizer.shared.log(String(format: "stream-test: %.1f s of audio → %.2f s to transcribe → “%@”", Double(fed) / 16_000, Date().timeIntervalSince(t0), text))
        }
        Visualizer.shared.log(String(format: "stream-test done in %.1f s", Date().timeIntervalSince(start)))
    }

    /// Is any microphone connected? (A Mac mini has none built in.)
    static var hasMicrophone: Bool {
        !AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.isEmpty
    }

    /// Turns the microphone on. Plain main-thread code with a callback on purpose: macOS may show its permission
    /// prompt here, and doing that from inside a Swift async task crashed SwiftUI's tooltip code.
    func startListening(_ done: @escaping (Error?) -> Void) {
        guard !listening else { return done(nil) }
        stopSpeaking()
        guard Self.hasMicrophone else {
            return done(VoiceError.message("No microphone is connected to this Mac. Plug in a USB mic or headset, or connect AirPods."))
        }
        let begin = { [weak self] in
            guard let self else { return }
            do { try self.beginRecording(); done(nil) } catch { done(error) }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? begin() : done(VoiceError.message("Microphone access was declined.")) }
            }
        default:
            done(VoiceError.message("23 can't use the microphone. Turn it on in System Settings → Privacy & Security → Microphone."))
        }
    }

    private var inputObserver: NSObjectProtocol?
    private var noiseFloor = 0.02
    private var peakLevel = 0.0

    private func beginRecording(keepAudio: Bool = false) throws {
        if inputObserver == nil {
            // The mic switching AirPods into headset mode changes the input format mid-recording: restart on the new one.
            inputObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.listening else { return }
                    Visualizer.shared.log("voice: microphone changed mode, carrying on")
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                    do { try self.beginRecording(keepAudio: true) } catch { Visualizer.shared.log("voice: couldn't restart the mic (\(error.localizedDescription))") }
                }
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw VoiceError.message("No microphone found.") }
        guard let conv = AVAudioConverter(from: format, to: targetFormat) else { throw VoiceError.message("The microphone's audio format isn't supported.") }
        let target = targetFormat
        let ratio = 16_000 / format.sampleRate
        if !keepAudio { samples.removeAll() }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            // Audio thread: measure loudness and convert to 16 kHz mono, then hand over on the main thread.
            let level = Self.rms(buffer)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)) else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            let chunk = Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
            Task { @MainActor in
                guard let self, self.listening else { return }
                self.samples += chunk
                let loud = min(1, level * 6)
                self.onLevel(loud)
                // Speech is judged against the room's own background level, so a hum or AirPods' hiss doesn't count as talking.
                self.noiseFloor = loud < self.noiseFloor ? loud : self.noiseFloor + (loud - self.noiseFloor) * 0.005
                self.peakLevel = max(self.peakLevel, loud)
                let speechLevel = max(0.08, self.noiseFloor * 2.5 + 0.04)
                if loud > speechLevel { self.heardSpeech = true; self.lastLoud = Date() }
                else if self.autoStop && self.heardSpeech && Date().timeIntervalSince(self.lastLoud) > 1.4 {
                    self.heardSpeech = false
                    self.onSilence()
                }
                if Date().timeIntervalSince(self.listenStarted) > 60 { self.onCapReached() }   // safety cap
            }
        }
        engine.prepare()
        try engine.start()
        if keepAudio { return }
        listenStarted = Date()
        listening = true
        heardSpeech = false
        noiseFloor = 0.02; peakLevel = 0
        startPartials()
        if mode != .off { Task { await ensureKokoro() } }   // warm the voice while the user talks
        ActivityLog.add("mic on", "push-to-talk")
    }

    /// Stops listening and returns what was said (empty if it was too short).
    /// Stops the microphone without transcribing (e.g. the user pressed Stop).
    func cancelListening() {
        guard listening || engine.isRunning else { return }
        listening = false
        partialTask?.cancel(); partial = ""; autoStop = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        samples.removeAll()
        ActivityLog.add("mic off", "cancelled")
    }

    /// Developer aid (`--transcribe file.wav`): run a recording through the same path as the microphone.
    func transcribe(file: URL) async throws -> String {
        let wav = try Data(contentsOf: file)
        if whisperInstalled { engineName = "whisper.cpp"; return try await transcribeWithWhisper(wav) }
        if await voiceStudioAvailable() { return try await transcribeWithVoiceStudio(wav) }
        return try await transcribeOnDevice(wav)
    }

    /// Developer aid: waits until everything queued has been spoken.
    func waitUntilQuiet() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        while speaking || worker != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    func stopListening() async throws -> String {
        guard listening || engine.isRunning else { return "" }
        listening = false
        partialTask?.cancel(); autoStop = false
        defer { partial = "" }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ActivityLog.add("mic off", String(format: "%.1f s", Date().timeIntervalSince(listenStarted)))
        Visualizer.shared.log(String(format: "voice: mic off after %.1f s (loudest %.2f, background %.2f)", Date().timeIntervalSince(listenStarted), peakLevel, noiseFloor))
        let audio = samples
        samples.removeAll()
        guard audio.count > 16_000 / 3 else { return "" }   // under ⅓ s: ignore
        let wav = Self.wav(audio, rate: 16_000)
        if whisperInstalled {
            do { return try await transcribeWithWhisper(wav) } catch {
                Visualizer.shared.log("whisper.cpp failed (\(error.localizedDescription)); trying the next engine")
            }
        }
        if await voiceStudioAvailable() {
            do { return try await transcribeWithVoiceStudio(wav) } catch {
                Visualizer.shared.log("VoiceStudio transcription failed (\(error.localizedDescription)); using on-device macOS")
            }
        }
        return try await transcribeOnDevice(wav)
    }

    private func transcribeWithVoiceStudio(_ wav: Data) async throws -> String {
        var req = URLRequest(url: Self.base.appendingPathComponent("v1/audio/transcriptions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        let boundary = "23-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        field("model", "whisper-1")
        field("response_format", "json")
        body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body += wav
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["text"] as? String else {
            throw VoiceError.message("VoiceStudio couldn't transcribe that (\(String(decoding: data.prefix(200), as: UTF8.self))).")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// macOS's recognizer, strictly on-device: if that isn't possible we fail rather than send audio to Apple.
    private func transcribeOnDevice(_ wav: Data) async throws -> String {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        if status == .denied || status == .restricted, !(SFSpeechRecognizer()?.isAvailable ?? false) {
            throw VoiceError.message("To talk to 23, start VoiceStudio. (macOS's own recognizer needs Siri & Dictation turned on, and it's off on this Mac.)")
        }
        guard status == .authorized else {
            throw VoiceError.message("Speech recognition isn't allowed. Turn it on in System Settings → Privacy & Security → Speech Recognition, or start VoiceStudio.")
        }
        guard let rec = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")), rec.supportsOnDeviceRecognition else {
            throw VoiceError.message("On-device speech recognition isn't available for this language. Start VoiceStudio to talk to me.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("23-speech-\(UUID().uuidString).wav")
        try wav.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true      // never leaves the Mac
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { c in
            var done = false
            rec.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let r = result, r.isFinal { done = true; c.resume(returning: r.bestTranscription.formattedString) }
                else if let e = error {
                    done = true
                    let msg = e.localizedDescription.lowercased().contains("dictation")
                        ? "To talk to 23, start VoiceStudio. (macOS's own recognizer needs Siri & Dictation turned on, and it's off on this Mac.)"
                        : e.localizedDescription
                    c.resume(throwing: VoiceError.message(msg))
                }
            }
        }
    }

    // MARK: Speaking

    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private let player = AVAudioPlayerNode()
    private let playEngine = AVAudioEngine()
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var pending = 0                          // buffers scheduled but not yet played
    /// Bumped whenever scheduled audio is thrown away, so late "finished" callbacks from it are ignored.
    private var epoch = 0
    /// When each recent sentence's audio should have finished playing, so a device change can repeat the unfinished ones.
    private var sentenceEnds: [(text: String, end: Date)] = []
    private var scheduledUntil = Date.distantPast
    private func dropScheduled() { epoch += 1; pending = 0; sentenceEnds.removeAll(); scheduledUntil = .distantPast }
    private let synth = AVSpeechSynthesizer()
    private let synthWatcher = SynthWatcher()
    private var generation = 0                       // bumps on stop, so stale audio is dropped

    private var playerReady = false
    var playbackDebug: String {
        let out = playEngine.outputNode.outputFormat(forBus: 0)
        return "engineRunning=\(playEngine.isRunning) playerPlaying=\(player.isPlaying) pending=\(pending) out=\(Int(out.sampleRate))Hz/\(out.channelCount)ch speaking=\(speaking)"
    }
    private func setUpPlayer() throws {
        guard !playerReady else { return }
        playEngine.attach(player)
        playEngine.connect(player, to: playEngine.mainMixerNode, format: pcmFormat)
        playEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            let level = Self.rms(buf)
            Task { @MainActor in if self?.speaking == true { self?.onLevel(min(1, level * 5)) } }
        }
        try playEngine.start()
        playerReady = true
        // AirPods switch between music and headset mode whenever their mic turns on or off. macOS then stops this
        // engine; without this, every reply after that was queued into a dead player and stayed silent.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: playEngine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playbackRouteChanged() }
        }
    }

    private var streaming = false
    private var streamingSentence: String?
    private var restartSentence = false

    private func playbackRouteChanged() {
        let wasPlaying = player.isPlaying || speaking
        // Whatever was scheduled went to the old device: say the unfinished sentences again rather than lose them.
        let now = Date().addingTimeInterval(0.15)
        var again = sentenceEnds.filter { $0.end > now }.map(\.text)
        if streaming, let current = streamingSentence {
            restartSentence = true                          // streamSpeech stops; the sentence is said again from the start
            if again.last != current { again.append(current) }
        }
        dropScheduled()
        player.stop()
        if !again.isEmpty {
            queue.insert(contentsOf: again, at: 0)
            if worker == nil { let gen = generation; worker = Task { [weak self] in await self?.drain(gen) } }
        }
        do { try playEngine.start() } catch { Visualizer.shared.log("voice: couldn't restart audio after a device change (\(error.localizedDescription))") }
        if wasPlaying { player.play() }
        Visualizer.shared.log("voice: audio device changed, playback restarted (\(playbackDebug))")
    }

    /// The engine may have been stopped by a device change; make sure it is running before scheduling audio.
    private func ensurePlaybackRunning() throws {
        try setUpPlayer()
        if !playEngine.isRunning { try playEngine.start() }
        if !player.isPlaying { player.play() }
    }

    /// Adds text to be spoken (it's cleaned and split into sentences first).
    func say(_ text: String) {
        let parts = Self.sentences(Self.speakable(text))
        guard !parts.isEmpty else { return }
        if firstQueuedAt == nil { firstQueuedAt = Date() }
        queue += parts
        if worker == nil {
            let gen = generation
            worker = Task { [weak self] in await self?.drain(gen) }
        }
    }

    private func setSpeaking(_ on: Bool) {
        guard speaking != on else { return }
        speaking = on
        onSpeakingChanged(on)
    }

    private func drain(_ gen: Int) async {
        let kokoro = await ensureKokoro()
        let studio = kokoro ? false : await voiceStudioAvailable()
        engineName = kokoro ? "Kokoro" : studio ? "VoiceStudio" : "macOS voice"
        while !queue.isEmpty, gen == generation {
            let sentence = queue.removeFirst()
            spokenCount += 1
            if firstAudioDelay == nil, let t = firstQueuedAt { firstAudioDelay = Date().timeIntervalSince(t) }
            setSpeaking(true)
            if kokoro || studio {
                do { try await streamSpeech(sentence, gen, kokoro: kokoro) } catch {
                    // Stopped by the user: stay silent (don't repeat the sentence in another voice).
                    let cancelled = (error as? URLError)?.code == .cancelled || error is CancellationError || gen != generation
                    if cancelled { break }
                    Visualizer.shared.log("\(engineName) speech failed (\(error.localizedDescription)); using macOS voice")
                    speakWithMac(sentence)
                }
            } else {
                speakWithMac(sentence)
            }
        }
        // Let the last audio finish before saying we're done.
        var stalled = 0
        while gen == generation && (pending > 0 || synthWatcher.pending > 0 || synth.isSpeaking) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Never wait forever on audio that can no longer play.
            stalled = pending > 0 && !playEngine.isRunning ? stalled + 1 : 0
            if stalled > 10 { Visualizer.shared.log("voice: playback stalled, giving up on \(pending) buffer(s)"); dropScheduled() }
        }
        worker = nil
        if gen == generation {
            if !queue.isEmpty { worker = Task { [weak self] in await self?.drain(gen) } } else { setSpeaking(false) }
        }
    }

    private func streamSpeech(_ sentence: String, _ gen: Int, kokoro: Bool) async throws {
        try ensurePlaybackRunning()
        streamingSentence = sentence
        streaming = true; restartSentence = false
        defer { streaming = false }
        var req = URLRequest(url: (kokoro ? (Remote.base ?? Self.kokoroBase) : Self.base).appendingPathComponent("v1/audio/speech"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": "tts-1", "input": sentence, "response_format": "pcm", "stream_format": "audio"]
        if kokoro { body["voice"] = kokoroVoice } else if !voiceID.isEmpty { body["voice"] = voiceID }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceError.message("\(kokoro ? "Kokoro" : "VoiceStudio") answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try ensurePlaybackRunning()
        var chunk = Data()
        let chunkBytes = 24_000 / 5 * 2      // ~0.2 s of 16-bit audio per buffer
        for try await byte in bytes {
            guard gen == generation else { return }
            if restartSentence { restartSentence = false; return }
            chunk.append(byte)
            if chunk.count >= chunkBytes { schedule(chunk, sentence); chunk.removeAll(keepingCapacity: true) }
        }
        if chunk.count >= 2 { schedule(chunk, sentence) }
    }

    private func schedule(_ data: Data, _ sentence: String) {
        let frames = data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        scheduledUntil = max(Date(), scheduledUntil).addingTimeInterval(Double(frames) / pcmFormat.sampleRate)
        if sentenceEnds.last?.text == sentence { sentenceEnds[sentenceEnds.count - 1].end = scheduledUntil }
        else { sentenceEnds.append((sentence, scheduledUntil)); if sentenceEnds.count > 8 { sentenceEnds.removeFirst() } }
        pending += 1
        let mine = epoch
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor in if let self, self.epoch == mine { self.pending = max(0, self.pending - 1) } }
        }
    }

    private func speakWithMac(_ sentence: String) {
        if synth.delegate == nil {
            synth.delegate = synthWatcher
            synthWatcher.onWord = { [weak self] in self?.onLevel(0.55) }   // the orb pulses with each word
        }
        synthWatcher.pending += 1
        let u = AVSpeechUtterance(string: sentence)
        u.voice = Self.bestMacVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        synth.speak(u)
        onLevel(0.5)
    }

    /// The best-quality installed English voice (Premium > Enhanced > default).
    private static let bestMacVoice: AVSpeechSynthesisVoice? = {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }()

    func stopSpeaking() {
        generation += 1
        queue.removeAll()
        worker?.cancel(); worker = nil
        if playerReady { player.stop() }
        dropScheduled()
        synth.stopSpeaking(at: .immediate)
        synthWatcher.pending = 0
        setSpeaking(false)
    }

    // MARK: Helpers

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        return Double(sqrt(sum / Float(buffer.frameLength)))
    }

    static func wav(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d += Data("RIFF".utf8); u32(36 + bytes); d += Data("WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d += Data("data".utf8); u32(bytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// What should be read aloud: no code, links, file paths, markdown symbols or emoji.
    static func speakable(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " ", options: .regularExpression)       // code blocks
        t = t.replacingOccurrences(of: #"`([^`]{1,24})`"#, with: "$1", options: .regularExpression)           // short inline code: say it
        t = t.replacingOccurrences(of: #"`[^`]*`"#, with: " ", options: .regularExpression)                   // long inline code: skip
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)     // [text](link) → text
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(~|/Users/[^/\s]+)?(/[\w.\- ]+){2,}/([\w.\-]+)"#, with: "$3", options: .regularExpression) // paths → name
        t = t.replacingOccurrences(of: #"[*_#>|]+"#, with: " ", options: .regularExpression)
        t = t.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) }
            .map(String.init).joined()
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), s.count > 1 { out.append(s) }
        }
        return out
    }
}

/// Collects a streaming reply and hands complete sentences to the voice as soon as they're finished,
/// skipping anything inside code blocks.
struct SpeechFeeder {
    private var buffer = ""

    /// Returns the text that is now ready to be spoken.
    mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        // Hold everything while a code block is open.
        if buffer.components(separatedBy: "```").count % 2 == 0 { return "" }
        // Cut at the last sentence end (., !, ?, … followed by space/newline) or a line break.
        guard let r = buffer.range(of: #"[.!?…:](\s)|\n"#, options: [.regularExpression, .backwards]) else { return "" }
        let ready = String(buffer[..<r.upperBound])
        buffer = String(buffer[r.upperBound...])
        return ready
    }

    mutating func flush() -> String {
        defer { buffer = "" }
        return buffer
    }
}

/// Counts the Mac voice's sentences until each one has really finished (or was cancelled).
final class SynthWatcher: NSObject, AVSpeechSynthesizerDelegate {
    var pending = 0
    var onWord: () -> Void = {}
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { DispatchQueue.main.async { self.pending = max(0, self.pending - 1) } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { DispatchQueue.main.async { self.pending = max(0, self.pending - 1) } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onWord() }
    }
}
