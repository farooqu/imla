import CryptoKit
import Foundation

/// The English Nemotron streaming model, in NeMo-Speech.cpp's shared model cache
/// so every app on the Mac that uses it maps the same file.
///
/// NVIDIA's published GGUF lacks the SentencePiece tokenizer that hotword
/// boosting needs, so the shared copy is the published file with the original
/// tokenizer embedded as `asr.tokenizer.spm_model`. It sits next to where the
/// NeMo-Speech CLI keeps the published file, under its own name.
public enum NemotronModel {
    static let repo = "nvidia/nemotron-speech-streaming-en-0.6b"
    static let revision = "ebe59e5a817142986528bbbee5dba8db7b38ed50"
    static let publishedName = "nemotron-speech-streaming-en-0.6b.q8_0.gguf"
    static let publishedSHA256 = "d9a01898d2a611c8764e23a1c2f45e70bbd5a425dc4de93692ac951dd603812d"
    static let hotwordName = "nemotron-speech-streaming-en-0.6b.q8_0.spm.gguf"
    static let hotwordSHA256 = "926495522ccd2626d8665283b4c9225f704ed2b45e82158984d1823f7e528b52"
    static let hotwordBytes: UInt64 = 700_207_744
    static let tokenizerSHA256 = "07d4e5a63840a53ab2d4d106d2874768143fb3fbdd47938b3910d2da05bfb0a9"
    static let tokenizerMember = "./e8dc9587bf16427491071501d9080e4e_tokenizer.model"
    public static let downloadBytes: Int64 = 699_872_960

    /// NeMo-Speech.cpp's cache: `$NEMO_SPEECH_MODEL_DIR`, else ~/Library/Caches/NeMoSpeech/models.
    static var cacheRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["NEMO_SPEECH_MODEL_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/NeMoSpeech/models")
    }

    static var directory: URL { cacheRoot.appendingPathComponent(repo).appendingPathComponent(revision) }
    public static var url: URL { directory.appendingPathComponent(hotwordName) }

    /// True when the shared hotword-ready file is present. Its checksum is
    /// verified when it's built; hashing 700 MB on every launch would delay dictation.
    public static func isInstalled() -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) == hotwordBytes
    }

    /// Builds the shared file: downloads the published model (unless the
    /// NeMo-Speech CLI already cached it) and the tokenizer, then embeds it.
    public static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        if (try? sha256(of: url)) == hotwordSHA256 { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)")!

        let cachedPublished = directory.appendingPathComponent(publishedName)
        var published = cachedPublished
        var downloaded: URL?
        if (try? sha256(of: cachedPublished)) != publishedSHA256 {
            let file = try await Downloader.download(base.appendingPathComponent(publishedName),
                                                     expectedBytes: downloadBytes, progress: progress)
            downloaded = file
            published = file
        }
        defer { if let downloaded { try? fm.removeItem(at: downloaded) } }
        guard try sha256(of: published) == publishedSHA256 else {
            throw NemotronError(message: "The downloaded speech model didn't match its expected checksum")
        }

        let tokenizer = try await fetchTokenizer(from: base.appendingPathComponent("nemotron-speech-streaming-en-0.6b.nemo"))
        let staging = directory.appendingPathComponent(hotwordName + ".partial")
        try? fm.removeItem(at: staging)
        try GGUF.appendString(key: "asr.tokenizer.spm_model", value: tokenizer.base64EncodedString(),
                              from: published, to: staging)
        guard try sha256(of: staging) == hotwordSHA256 else {
            try? fm.removeItem(at: staging)
            throw NemotronError(message: "The prepared speech model didn't match its expected checksum")
        }
        _ = try? fm.removeItem(at: url)
        try fm.moveItem(at: staging, to: url)
        progress(1)
    }

    /// The tokenizer is near the start of the uncompressed .nemo tar, so a 1 MB
    /// range request avoids downloading the 2.5 GB archive.
    static func fetchTokenizer(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            throw NemotronError(message: "Couldn't fetch the tokenizer (no HTTP range support)")
        }
        guard let tokenizer = Tar.member(named: tokenizerMember, in: data),
              SHA256.hash(data: tokenizer).hex == tokenizerSHA256 else {
            throw NemotronError(message: "Couldn't find the expected tokenizer in the model archive")
        }
        return tokenizer
    }
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().hex
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Just enough of the tar format to pull one small member out of a prefix.
enum Tar {
    static func member(named name: String, in data: Data) -> Data? {
        var offset = 0
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<offset + 512)
            if header.allSatisfy({ $0 == 0 }) { return nil }
            let memberName = String(decoding: header[0..<100].prefix { $0 != 0 }, as: UTF8.self)
            let sizeField = String(decoding: header[124..<136].prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
            guard let size = Int(sizeField, radix: 8) else { return nil }
            let start = offset + 512
            if memberName == name {
                return start + size <= data.count ? data.subdata(in: start..<start + size) : nil
            }
            offset = start + (size + 511) / 512 * 512
        }
        return nil
    }
}

/// Copies a GGUF file with one string key-value appended to its metadata.
/// Tensor offsets are relative to the data section, so only the header grows.
enum GGUF {
    struct FormatError: Error {}

    static func appendString(key: String, value: String, from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        // Metadata and tensor infos fit comfortably in the first few MB.
        let head = try input.read(upToCount: 16 << 20) ?? Data()
        var reader = Reader(data: head)
        guard try reader.bytes(4) == Data("GGUF".utf8) else { throw FormatError() }
        let version = try reader.u32()
        let tensorCount = try reader.u64()
        let kvCount = try reader.u64()
        let kvStart = reader.offset
        var alignment = 32
        for _ in 0..<kvCount {
            let name = try reader.string()
            let type = try reader.u32()
            if name == "general.alignment", type == 4 { alignment = Int(try reader.u32()) } else { try reader.skipValue(type) }
        }
        let kvEnd = reader.offset
        for _ in 0..<tensorCount {
            _ = try reader.string()
            let dims = try reader.u32()
            reader.offset += Int(dims) * 8 + 4 + 8
        }
        let infoEnd = reader.offset
        let dataStart = (infoEnd + alignment - 1) / alignment * alignment

        var header = Data("GGUF".utf8)
        header.append(le: version)
        header.append(le: tensorCount)
        header.append(le: kvCount + 1)
        header.append(head[kvStart..<kvEnd])
        header.append(ggufString: key)
        header.append(le: UInt32(8))
        header.append(ggufString: value)
        header.append(head[kvEnd..<infoEnd])
        let padded = (header.count + alignment - 1) / alignment * alignment
        header.append(Data(count: padded - header.count))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: header)
        try input.seek(toOffset: UInt64(dataStart))
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
    }

    struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(_ n: Int) throws -> Data {
            guard offset + n <= data.count else { throw FormatError() }
            defer { offset += n }
            return data.subdata(in: offset..<offset + n)
        }

        mutating func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        mutating func u64() throws -> UInt64 { try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        mutating func string() throws -> String { String(decoding: try bytes(Int(try u64())), as: UTF8.self) }

        mutating func skipValue(_ type: UInt32) throws {
            switch type {
            case 0, 1, 7: offset += 1
            case 2, 3: offset += 2
            case 4, 5, 6: offset += 4
            case 10, 11, 12: offset += 8
            case 8: offset += Int(try u64())
            case 9:
                let element = try u32()
                let count = try u64()
                for _ in 0..<count { try skipValue(element) }
            default: throw FormatError()
            }
            guard offset <= data.count else { throw FormatError() }
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(ggufString: String) {
        let bytes = Data(ggufString.utf8)
        append(le: UInt64(bytes.count))
        append(bytes)
    }
}

/// A file download with progress, which URLSession's async API doesn't report.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    /// `expectedBytes` drives progress when the server sends no length.
    static func download(_ url: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = Downloader(expectedBytes: expectedBytes, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        progress(min(0.99, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
        else if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 200, let continuation {
            continuation.resume(throwing: NemotronError(message: "Model download failed (HTTP \(status))"))
            self.continuation = nil
        }
    }
}
