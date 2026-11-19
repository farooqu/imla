import AppKit
import AVFoundation
import ImlaCore

struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    let raw: String
    let final: String
    let app: String?
    let seconds: TimeInterval
}

@MainActor
final class DictationController: ObservableObject {
    enum ModelState: Equatable {
        case missing
        case installing(progress: Double)
        case loading
        case ready
        case failed(String)
    }

    enum Phase: Equatable {
        case idle, listening, transcribing, polishing
        /// The notice is only for something the user must act on.
        case done(notice: String?)
        case failed(String)

        var isBusy: Bool { self == .listening || self == .transcribing || self == .polishing }
    }

    @Published private(set) var phase: Phase = .idle
    /// Microphone loudness from 0 to 1, about ten times a second.
    @Published private(set) var level: Float = 0
    /// Saved to disk so a dictation that couldn't be pasted survives a restart.
    @Published private(set) var history: [HistoryItem]
    /// Where the caret was when dictation started, in screen points with a top-left origin.
    @Published private(set) var anchor: CGRect?
    @Published var settingsTab = 0
    @Published private(set) var hotkeyRegistered = true
    @Published private(set) var modelState: ModelState = .loading
    /// The built-in cleanup model, S1-mini.
    @Published private(set) var cleanupModelState: ModelState = .loading
    @Published var config: ImlaConfig {
        didSet {
            guard config != oldValue else { return }
            try? config.save()
            if config.hotkey != oldValue.hotkey { registerHotkey() }
            if config.usesBuiltInCleanup != oldValue.usesBuiltInCleanup { Task { await loadCleanupModel() } }
        }
    }

    private static let mainHotkey: UInt32 = 1
    private static let cancelHotkey: UInt32 = 2

    private let recorder = AudioRecorder()
    private var engine: NemotronEngine?
    private var cleaner: S1MiniEngine?
    private var stream: NemotronStream?
    private var targetApp: NSRunningApplication?
    private var target: FocusTarget?
    private var startedAt = Date()
    private var pressedAt = Date.distantPast
    private var work: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    init() {
        ImlaConfig.migrateFromScribe()
        history = Self.loadHistory()
        config = ImlaConfig.load()
        if !FileManager.default.fileExists(atPath: ImlaConfig.fileURL.path) { try? config.save() }
        registerHotkey()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Ask once. Without it dictations are copied instead, and Settings has a Grant button,
        // so a stale grant doesn't bring the system prompt back on every launch.
        if !Paster.canPaste, !UserDefaults.standard.bool(forKey: "askedForAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedForAccessibility")
            Paster.requestAccessibility()
        }
        Task { await loadModel() }
        Task { await loadCleanupModel() }
    }

    // MARK: Models

    /// Loads the shared model if it's installed; otherwise Settings offers to download it.
    func loadModel() async {
        modelState = .loading
        let url = NemotronModel.url
        let result: Result<NemotronEngine?, Error> = await Task.detached {
            guard NemotronModel.isInstalled() else { return .success(nil) }
            return Result { try NemotronEngine(model: url) }
        }.value
        switch result {
        case .success(let loaded?): engine = loaded; modelState = .ready
        case .success(nil): modelState = .missing
        case .failure(let error): modelState = .failed(error.localizedDescription)
        }
    }

    /// Loads S1-mini while it's the cleanup engine and frees it otherwise.
    func loadCleanupModel() async {
        guard config.usesBuiltInCleanup else { cleaner = nil; cleanupModelState = .loading; return }
        guard cleaner == nil else { cleanupModelState = .ready; return }
        cleanupModelState = .loading
        let url = S1MiniModel.url
        let result: Result<S1MiniEngine?, Error> = await Task.detached {
            guard S1MiniModel.isInstalled() else { return .success(nil) }
            return Result { try S1MiniEngine(model: url) }
        }.value
        // The setting may have changed while it loaded.
        guard config.usesBuiltInCleanup else { return }
        switch result {
        case .success(let loaded?): cleaner = loaded; cleanupModelState = .ready
        case .success(nil): cleanupModelState = .missing
        case .failure(let error): cleanupModelState = .failed(error.localizedDescription)
        }
    }

    func installModel() {
        install(\.modelState, NemotronModel.install, then: loadModel)
    }

    func installCleanupModel() {
        install(\.cleanupModelState, S1MiniModel.install, then: loadCleanupModel)
    }

    private func install(_ state: ReferenceWritableKeyPath<DictationController, ModelState>,
                         _ install: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void,
                         then load: @escaping () async -> Void) {
        switch self[keyPath: state] {
        case .missing, .failed: break
        default: return
        }
        self[keyPath: state] = .installing(progress: 0)
        Task {
            do {
                try await install { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .installing = self[keyPath: state] else { return }
                        self[keyPath: state] = .installing(progress: fraction)
                    }
                }
                await load()
            } catch {
                self[keyPath: state] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Hotkey

    func registerHotkey() {
        hotkeyRegistered = HotkeyCenter.shared.register(Self.mainHotkey, config.hotkey,
            pressed: { [weak self] in self?.hotkeyPressed() },
            released: { [weak self] in self?.hotkeyReleased() })
    }

    /// Tap to start and tap again to stop, or hold while speaking and release.
    private func hotkeyPressed() {
        switch phase {
        case .listening: stop()
        case .transcribing, .polishing: break
        default:
            pressedAt = Date()
            start()
        }
    }

    private func hotkeyReleased() {
        if phase == .listening, Date().timeIntervalSince(pressedAt) > 0.45 { stop() }
    }

    // MARK: Dictation

    func toggle() { phase == .listening ? stop() : start() }

    func start() {
        guard !phase.isBusy else { return }
        hideTask?.cancel()
        targetApp = NSWorkspace.shared.frontmostApplication
        target = nil
        if Paster.canPaste {
            switch FocusTarget.capture() {
            case .field(let found), .unknown(let found): target = found
            case .notEditable: anchor = nil; return fail("Click into a text field first")
            case nil: break
            }
        }
        anchor = target?.anchor
        guard let engine else {
            return fail(modelState == .loading ? "The speech model is still loading" : "Set up the speech model in Imla Settings")
        }
        level = 0
        startedAt = Date()
        do {
            let stream = try engine.startStream(phrases: config.boostTerms)
            self.stream = stream
            try recorder.start { [weak self] samples, level in
                // Decoding runs on the engine's queue; only the level goes to the main thread.
                stream.push(samples)
                DispatchQueue.main.async { if self?.phase == .listening { self?.level = level } }
            }
        } catch {
            stream?.cancel()
            stream = nil
            return fail(error.localizedDescription)
        }
        phase = .listening
        HotkeyCenter.shared.register(Self.cancelHotkey, .escape, pressed: { [weak self] in self?.cancel() })
        if config.playSounds { NSSound(named: "Tink")?.play() }
        if config.llmCleanup, config.cleanupEngine == .ollama, let ollama { Task.detached { await ollama.warm() } }
    }

    func stop() {
        guard phase == .listening, let stream else { return }
        recorder.stop()
        if config.playSounds { NSSound(named: "Pop")?.play() }
        self.stream = nil
        phase = .transcribing
        let seconds = Date().timeIntervalSince(startedAt)
        work = Task { await self.complete(stream, seconds: seconds) }
    }

    func cancel() {
        HotkeyCenter.shared.unregister(Self.cancelHotkey)
        guard phase.isBusy else { return }
        if phase == .listening { recorder.stop() }
        stream?.cancel()
        stream = nil
        work?.cancel()
        phase = .idle
    }

    private func complete(_ stream: NemotronStream, seconds: TimeInterval) async {
        do {
            let raw = try await stream.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !raw.isEmpty else { return finishQuietly() }

            var text = TextRules.apply(raw, vocabulary: config.vocabulary)
            if config.llmCleanup {
                phase = .polishing
                text = await polish(text) ?? text
            }
            try Task.checkCancellation()
            HotkeyCenter.shared.unregister(Self.cancelHotkey)

            // Record it before pasting, so nothing is lost if the paste goes wrong.
            remember(HistoryItem(raw: raw, final: text, app: targetApp?.localizedName, seconds: seconds))
            let notice: String?
            if let target, !(await target.restore()) {
                Paster.copy(text)
                notice = "Couldn't get back to the text field. It's copied and in Recent Dictations."
            } else if Paster.insert(text, into: target == nil ? targetApp : nil) {
                notice = nil
            } else {
                notice = "Copied. Allow Accessibility to paste automatically"
            }
            phase = .done(notice: notice)
            scheduleHide(after: notice == nil ? 0.7 : 4)
        } catch is CancellationError {
            phase = .idle
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Returns nil to keep the rule-cleaned text, such as when the model isn't available.
    private func polish(_ text: String) async -> String? {
        var output = ""
        do {
            switch config.cleanupEngine {
            case .builtIn:
                // S1-mini has its own trained prompt; the vocabulary reaches it through recognition and the rules.
                guard let cleaner, let cleaned = try await cleaner.clean(text) else { return nil }
                output = cleaned
            case .ollama:
                guard let ollama else { return nil }
                let system = CleanupPrompt.system(vocabulary: config.vocabulary, targetApp: targetApp?.localizedName)
                for try await piece in ollama.stream(system: system, user: CleanupPrompt.user(text)) {
                    output += piece
                }
            }
        } catch {
            NSLog("Imla: LLM cleanup failed: \(error.localizedDescription)")
            return nil
        }
        return CleanupPrompt.accept(output, input: text)
    }

    private var ollama: OllamaClient? {
        URL(string: config.ollamaURL).map { OllamaClient(baseURL: $0, model: config.ollamaModel) }
    }

    /// Nothing was heard: let the pill go without a message.
    private func finishQuietly() {
        HotkeyCenter.shared.unregister(Self.cancelHotkey)
        phase = .idle
    }

    private func fail(_ message: String) {
        HotkeyCenter.shared.unregister(Self.cancelHotkey)
        if config.playSounds { NSSound(named: "Basso")?.play() }
        phase = .failed(message)
        scheduleHide(after: 4)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled, !phase.isBusy { phase = .idle }
        }
    }

    // MARK: Settings support

    private static let historyLimit = 20
    private static var historyURL: URL {
        ImlaConfig.fileURL.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    private static func loadHistory() -> [HistoryItem] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    private func remember(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(history).write(to: Self.historyURL, options: [.atomic, .completeFileProtection])
    }

    func copy(_ text: String) { Paster.copy(text) }
}
