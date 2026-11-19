import AVFoundation

/// Captures the default microphone as 16 kHz mono float samples for Nemotron.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "No microphone input is available" }
    }

    /// `onChunk` runs on the audio thread with samples and a 0–1 loudness level.
    func start(onChunk: @escaping ([Float], Float) -> Void) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw NoMicrophone() }
        let outFormat = outFormat
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        // ~100 ms buffers keep latency low without flooding the socket.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 10), format: inFormat) { buffer, _ in
            let level = Self.level(buffer)
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.floatChannelData else { return }
            onChunk(Array(UnsafeBufferPointer(start: samples[0], count: Int(out.frameLength))), level)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        return min(1, max(0, (db + 55) / 45))
    }
}
