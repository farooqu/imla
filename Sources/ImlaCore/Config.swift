import Foundation

/// A word or phrase you use that speech recognition tends to get wrong.
public struct VocabularyEntry: Codable, Hashable, Identifiable {
    public var id = UUID()
    /// The correct spelling, such as "Kubernetes" or "MR".
    public var term: String
    /// What recognition produces instead, such as "cube" or "em are". Replaced
    /// with `term` before cleanup, as whole words, ignoring case.
    public var soundsLike: [String]

    public init(term: String, soundsLike: [String] = []) {
        self.term = term
        self.soundsLike = soundsLike
    }

    enum CodingKeys: String, CodingKey { case term, soundsLike }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decode(String.self, forKey: .term)
        soundsLike = try c.decodeIfPresent([String].self, forKey: .soundsLike) ?? []
    }
}

public struct Hotkey: Codable, Hashable {
    /// Carbon virtual key code.
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control-Option-Space.
    public static let `default` = Hotkey(keyCode: 49, modifiers: 0x1000 | 0x0800)
}

/// Which model polishes the transcript.
public enum CleanupEngine: String, Codable, CaseIterable {
    /// S1-mini, in process.
    case builtIn
    /// Any model served by Ollama.
    case ollama
}

public struct ImlaConfig: Codable, Equatable {
    public var ollamaURL = "http://localhost:11434"
    /// Empty until you choose one of your Ollama models.
    public var ollamaModel = ""
    public var llmCleanup = true
    public var cleanupEngine = CleanupEngine.builtIn
    public var hotkey = Hotkey.default
    public var playSounds = true
    /// Show the words as they're recognized in the pill, instead of the waveform.
    public var liveTranscript = false
    public var vocabulary: [VocabularyEntry] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so new settings don't reset existing files.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImlaConfig()
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel
        llmCleanup = try c.decodeIfPresent(Bool.self, forKey: .llmCleanup) ?? d.llmCleanup
        cleanupEngine = (try? c.decodeIfPresent(CleanupEngine.self, forKey: .cleanupEngine)) ?? d.cleanupEngine
        hotkey = try c.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? d.hotkey
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        liveTranscript = try c.decodeIfPresent(Bool.self, forKey: .liveTranscript) ?? d.liveTranscript
        vocabulary = try c.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) ?? d.vocabulary
    }

    /// Whether S1-mini should be loaded.
    public var usesBuiltInCleanup: Bool { llmCleanup && cleanupEngine == .builtIn }

    /// Phrases the Nemotron decoder is biased toward.
    public var boostTerms: [String] {
        var seen = Set<String>()
        return vocabulary.map { $0.term.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Imla/config.json")
    }

    /// Moves settings and history from the app's old name, Scribe, the first time Imla runs.
    public static func migrateFromScribe() {
        let support = fileURL.deletingLastPathComponent()
        let old = support.deletingLastPathComponent().appendingPathComponent("Scribe")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: support.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.moveItem(at: old, to: support)
    }

    public static func load(from url: URL = fileURL) -> ImlaConfig {
        guard let data = try? Data(contentsOf: url) else { return ImlaConfig() }
        return (try? JSONDecoder().decode(ImlaConfig.self, from: data)) ?? ImlaConfig()
    }

    public func save(to url: URL = ImlaConfig.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
