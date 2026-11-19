import CNemoSpeech
import Foundation

public struct NemotronError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// In-process streaming Nemotron on Metal, through the NeMo-Speech.cpp C ABI.
///
/// Every native call runs on one serial queue: the recognizer and its streams
/// belong to a single thread, as in the voice stack's server.
public final class NemotronEngine: @unchecked Sendable {
    /// Matches the voice stack's tested decoder contexts boost.
    public static let boost: Float = 1.5

    let queue = DispatchQueue(label: "imla.nemotron")
    private var recognizer: OpaquePointer?

    /// Loads the model. The weights are memory-mapped, so another process
    /// using the same file shares them. Takes a few seconds; call off the main thread.
    public init(model: URL) throws {
        try queue.sync {
            var backend = nemo_speech_asr_backend_config(size: MemoryLayout<nemo_speech_asr_backend_config>.size, gpu: 0)
            // The voice stack's benchmarked cache-aware streaming geometry.
            var streaming = nemo_speech_asr_streaming_config(
                size: MemoryLayout<nemo_speech_asr_streaming_config>.size,
                chunk_size: 0.16, ctc_left_padding: 1.92, ctc_right_padding: 1.92, rnnt_right_context: 6)
            var endpointing = nemo_speech_asr_endpointing_config(
                size: MemoryLayout<nemo_speech_asr_endpointing_config>.size, enable: false, vad_based: false,
                stop_history_eou_ms: 0)
            try model.path.withCString { path in
                var modelConfig = nemo_speech_asr_model_config(
                    size: MemoryLayout<nemo_speech_asr_model_config>.size, path: path, name: nil)
                try withUnsafePointer(to: &backend) { backend in
                    try withUnsafePointer(to: &modelConfig) { modelConfig in
                        try withUnsafePointer(to: &streaming) { streaming in
                            try withUnsafePointer(to: &endpointing) { endpointing in
                                var config = nemo_speech_asr_recognizer_config()
                                config.size = MemoryLayout<nemo_speech_asr_recognizer_config>.size
                                config.backend = backend
                                config.model = modelConfig
                                config.streaming = streaming
                                config.endpointing = endpointing
                                try Self.check(nemo_speech_asr_create(&config, &recognizer), "load the speech model")
                            }
                        }
                    }
                }
            }
        }
    }

    deinit {
        queue.sync { if let recognizer { nemo_speech_asr_destroy(recognizer) } }
    }

    /// Starts one utterance, biased toward `phrases`.
    public func startStream(phrases: [String]) throws -> NemotronStream {
        try queue.sync {
            var options = nemo_speech_asr_recognition_options_default()
            options.interim_results = true
            options.verbatim_transcripts = true
            // Keeps native casing and punctuation; there is no separate punctuation model.
            options.enable_automatic_punctuation = true
            options.profanity_filter = false
            let cStrings = phrases.map { strdup($0) }
            defer { cStrings.forEach { free($0) } }
            var handle: OpaquePointer?
            let status: nemo_speech_asr_status = cStrings.map { UnsafePointer($0) }.withUnsafeBufferPointer { phrasePointers in
                var context = nemo_speech_asr_speech_context(
                    size: MemoryLayout<nemo_speech_asr_speech_context>.size,
                    phrases: phrasePointers.baseAddress, phrase_count: phrasePointers.count, boost: Self.boost)
                return withUnsafePointer(to: &context) { context in
                    if !phrases.isEmpty {
                        options.speech_contexts = context
                        options.speech_context_count = 1
                    }
                    return nemo_speech_asr_streaming_recognize(recognizer, &options, &handle)
                }
            }
            try Self.check(status, "start recognition")
            return NemotronStream(engine: self, handle: handle!)
        }
    }

    static func check(_ status: nemo_speech_asr_status, _ action: String) throws {
        guard status != NEMO_SPEECH_ASR_OK else { return }
        let detail = nemo_speech_asr_last_error().map { String(cString: $0) } ?? "error \(status.rawValue)"
        throw NemotronError(message: "Couldn't \(action): \(detail)")
    }
}

/// One utterance. `push` decodes as audio arrives, so `finish` only has the
/// last chunk left to do.
public final class NemotronStream: @unchecked Sendable {
    private let engine: NemotronEngine
    private var handle: OpaquePointer?
    private var failure: Error?
    private var lastPartial = ""
    /// Called on the engine's queue with the whole transcript so far, each time it changes.
    public var onPartial: (@Sendable (String) -> Void)?

    init(engine: NemotronEngine, handle: OpaquePointer) {
        self.engine = engine
        self.handle = handle
    }

    deinit {
        let handle = handle
        engine.queue.async { if let handle { nemo_speech_asr_stream_close(handle) } }
    }

    /// 16 kHz mono float samples.
    public func push(_ samples: [Float]) {
        engine.queue.async { [self] in
            guard let handle, failure == nil else { return }
            do {
                try NemotronEngine.check(samples.withUnsafeBufferPointer {
                    nemo_speech_asr_stream_push_f32(handle, $0.baseAddress, $0.count, 16000)
                }, "decode audio")
                try drain(handle)
            } catch {
                failure = error
            }
        }
    }

    /// Flushes the tail and returns the final transcript.
    public func finish() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            engine.queue.async { [self] in
                continuation.resume(with: Result {
                    if let failure { throw failure }
                    guard let handle else { throw CancellationError() }
                    defer { close() }
                    try NemotronEngine.check(nemo_speech_asr_stream_finish(handle), "finish recognition")
                    guard let text = try drain(handle, untilFinal: true) else {
                        throw NemotronError(message: "Recognition ended without a final transcript")
                    }
                    return text
                })
            }
        }
    }

    public func cancel() {
        engine.queue.async { [self] in close() }
    }

    private func close() {
        if let handle { nemo_speech_asr_stream_close(handle) }
        handle = nil
    }

    /// Pulls available results. Returns the final transcript once one arrives.
    @discardableResult
    private func drain(_ handle: OpaquePointer, untilFinal: Bool = false) throws -> String? {
        while true {
            var result: OpaquePointer?
            try NemotronEngine.check(nemo_speech_asr_stream_next(handle, &result), "decode audio")
            guard let result else { return nil }
            defer { nemo_speech_asr_result_destroy(result) }
            let text = nemo_speech_asr_result_transcript(result, 0).map { String(cString: $0) } ?? ""
            if nemo_speech_asr_result_is_final(result) {
                if untilFinal { return text }
                throw NemotronError(message: "Recognition finalized before the end of audio")
            }
            if text != lastPartial {
                lastPartial = text
                onPartial?(text)
            }
        }
    }
}
