import CLlama
import Foundation

/// "S1-mini" by "Superwhisper": a 0.6B model trained only to clean up dictation.
/// Its license requires that exact name wherever it's used.
///
/// The file lives in the Hugging Face hub cache, where llama.cpp and the
/// Hugging Face tools look for it, so other apps share the download.
public enum S1MiniModel {
    static let repo = "superwhisper/s1-mini-GGUF"
    static let revision = "34add00a48a2e5d24e5a4ee5405a99620a3a240c"
    static let fileName = "s1-mini-q4_k_m.gguf"
    static let sha256 = "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
    public static let downloadBytes: Int64 = 484_219_808

    /// The hub cache, resolved as huggingface_hub does.
    static var hubCache: URL {
        let env = ProcessInfo.processInfo.environment
        func dir(_ key: String) -> String? { env[key].flatMap { $0.isEmpty ? nil : $0 } }
        if let path = dir("HF_HUB_CACHE") ?? dir("HUGGINGFACE_HUB_CACHE") { return URL(fileURLWithPath: path) }
        if let home = dir("HF_HOME") { return URL(fileURLWithPath: home).appendingPathComponent("hub") }
        let cache = dir("XDG_CACHE_HOME").map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return cache.appendingPathComponent("huggingface/hub")
    }

    static var repoDirectory: URL { hubCache.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--")) }
    public static var url: URL { repoDirectory.appendingPathComponent("snapshots/\(revision)/\(fileName)") }

    /// Checked by size; the checksum is verified when it's downloaded.
    public static func isInstalled() -> Bool {
        // The snapshot entry is a symlink to the blob, so measure what it points to.
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.size] as? Int64) == downloadBytes
    }

    /// Downloads into the hub cache's layout: the file under blobs/<sha256>,
    /// linked from the pinned snapshot.
    public static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let blob = repoDirectory.appendingPathComponent("blobs/\(sha256)")
        if (try? FileManager.default.attributesOfItem(atPath: blob.path)[.size] as? Int64) != downloadBytes {
            let source = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)")!
            let file = try await Downloader.download(source, expectedBytes: downloadBytes, progress: progress)
            defer { try? fm.removeItem(at: file) }
            guard try ImlaCore.sha256(of: file) == sha256 else {
                throw NemotronError(message: "The downloaded cleanup model didn't match its expected checksum")
            }
            try fm.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: blob)
            try fm.moveItem(at: file, to: blob)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: url)
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: "../../blobs/\(sha256)")
        progress(1)
    }
}

/// Runs S1-mini in process through llama.cpp, on the same ggml and Metal
/// runtime as Nemotron. Every native call runs on one serial queue.
public final class S1MiniEngine: @unchecked Sendable {
    /// Mail apps get the trained email layout: a greeting line, the body, and a
    /// sign-off block, when you said them.
    public static let emailApps: Set<String> = ["com.apple.mail", "com.microsoft.Outlook"]

    /// The control line the model was trained on. Structure stays prose: a list
    /// in a chat message or code comment would be a surprise.
    public static func control(style: CleanupStyle, email: Bool) -> String {
        "[Styling: \(style.rawValue)] [Structure: prose] [Context: \(email ? "email" : "general")]"
    }
    static let system = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line "
        + "specifying the styling, structure, and context settings; clean the transcript to match those settings "
        + "and output only the cleaned text."

    private let queue = DispatchQueue(label: "imla.s1mini")
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let vocab: OpaquePointer

    /// The trained input format, including the empty think block the model saw in training.
    public static func prompt(for text: String, control: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(control)\n\(text)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Loads the model with all layers on the GPU. The weights are memory-mapped,
    /// so another process using the same file shares them. Call off the main thread.
    public init(model url: URL) throws {
        llama_log_set({ level, text, _ in
            if level == GGML_LOG_LEVEL_ERROR, let text { NSLog("Imla llama.cpp: %s", text) }
        }, nil)
        llama_backend_init()
        guard let model = llama_model_load_from_file(url.path, llama_model_default_params()) else {
            throw NemotronError(message: "Couldn't load the cleanup model")
        }
        var params = llama_context_default_params()
        // About 650 words per pass, at a third of 4K's memory; clean() splits longer
        // dictations. The default would size the cache for 40K tokens.
        params.n_ctx = 2048
        params.n_batch = 2048
        params.n_ubatch = 512
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw NemotronError(message: "Couldn't start the cleanup model")
        }
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
        sampler = llama_sampler_init_greedy()
    }

    deinit {
        queue.sync {
            llama_sampler_free(sampler)
            llama_free(context)
            llama_model_free(model)
        }
    }

    /// Returns the cleaned text, or nil if the model couldn't clean it. A dictation
    /// too long for one pass is cleaned a few sentences at a time, as the model
    /// card recommends; a backtrack that spans two passes stays as spoken.
    public func clean(_ text: String, style: CleanupStyle, email: Bool) async throws -> String? {
        let control = Self.control(style: style, email: email)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    let fits = { self.fits($0, control: control) }
                    if fits(text) { return try generate(text, control: control) }
                    // A part the model can't clean stays rule-cleaned rather than losing the rest.
                    return try Self.chunks(of: text, fitting: fits).map { try generate($0, control: control) ?? $0 }
                        .joined(separator: " ")
                })
            }
        }
    }

    /// Splits text at sentence ends into the fewest runs that each fit. A single
    /// sentence too long to fit becomes its own run.
    static func chunks(of text: String, fitting fits: (String) -> Bool) -> [String] {
        var sentences = [String]()
        var current = [Substring]()
        for word in text.split(whereSeparator: \.isWhitespace) {
            current.append(word)
            if word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’")).last.map(".!?".contains) == true {
                sentences.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { sentences.append(current.joined(separator: " ")) }
        var chunks = [String]()
        for sentence in sentences {
            if let last = chunks.last, fits(last + " " + sentence) {
                chunks[chunks.count - 1] = last + " " + sentence
            } else {
                chunks.append(sentence)
            }
        }
        return chunks
    }

    /// Whether the prompt and the longest output it allows fit in the context.
    private func fits(_ text: String, control: String) -> Bool {
        let prompt = tokenize(Self.prompt(for: text, control: control)).count
        return prompt + Self.outputLimit(prompt) <= Int(llama_n_ctx(context))
    }

    /// Output tracks input length; the model card suggests 1.3x + 32 as a ceiling.
    private static func outputLimit(_ promptTokens: Int) -> Int { promptTokens * 13 / 10 + 32 }

    private func generate(_ text: String, control: String) throws -> String? {
        var tokens = tokenize(Self.prompt(for: text, control: control))
        let limit = Self.outputLimit(tokens.count)
        // A cut-off cleanup would drop words, so text that doesn't fit stays rule-cleaned.
        guard tokens.count + limit <= Int(llama_n_ctx(context)) else { return nil }
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)

        let failed = NemotronError(message: "Cleanup model failed to decode")
        guard tokens.withUnsafeMutableBufferPointer({
            llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
        }) == 0 else { throw failed }
        var output = [CChar]()
        var piece = [CChar](repeating: 0, count: 64)
        var finished = false
        for _ in 0..<limit {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { finished = true; break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { output.append(contentsOf: piece[0..<Int(n)]) }
            guard withUnsafeMutablePointer(to: &token, { llama_decode(context, llama_batch_get_one($0, 1)) }) == 0 else {
                throw failed
            }
        }
        guard finished else { return nil }
        // Pieces can split a UTF-8 character, so decode only the whole output.
        return String(decoding: output.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let bytes = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(bytes) + 8)
        // parse_special turns the <|im_start|> markers into their tokens.
        let n = llama_tokenize(vocab, text, bytes, &tokens, Int32(tokens.count), false, true)
        return Array(tokens.prefix(Int(max(n, 0))))
    }
}
