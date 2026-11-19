import Foundation
import Testing
@testable import ImlaCore

@Test func rulesReplaceVocabularyAsWholeWordsOnly() {
    let vocab = [VocabularyEntry(term: "MR", soundsLike: ["em are"]),
                 VocabularyEntry(term: "Kubernetes", soundsLike: ["cube"])]
    let out = TextRules.apply("open an em are for cube, not the cubes or a Rubik's cube-ish thing", vocabulary: vocab)
    #expect(out == "Open an MR for Kubernetes, not the cubes or a Rubik's Kubernetes-ish thing")
}

@Test func rulesDropFillersAndStutterButKeepRealWords() {
    let out = TextRules.apply("um, so I I think the the umbrella is, uh, in Umer's car hmm", vocabulary: [])
    #expect(out == "So I think the umbrella is, in Umer's car")
}

@Test func acceptRejectsAnswersAndUnwrapsQuotes() {
    #expect(CleanupPrompt.accept("\"Ship it Friday.\"", input: "ship it uh friday") == "Ship it Friday.")
    let question = "what is the capital of France"
    let answer = String(repeating: "The capital of France is Paris, a city known for many things. ", count: 3)
    #expect(CleanupPrompt.accept(answer, input: question) == nil)
}

@Test func configDecodesOlderFilesWithDefaults() throws {
    // "boost" is a removed per-term setting; files that still have it must load.
    let json = #"{"ollamaModel":"qwen3:4b","vocabulary":[{"term":"Jira","boost":false},{"term":" jira "},{"term":"MR"}]}"#
    let config = try JSONDecoder().decode(ImlaConfig.self, from: Data(json.utf8))
    #expect(config.ollamaModel == "qwen3:4b")
    #expect(config.llmCleanup == true)
    #expect(config.cleanupEngine == .builtIn)
    #expect(config.boostTerms == ["Jira", "MR"])
}

@Test func s1MiniPromptIsTheTrainedFormat() {
    // The model card says any other wording, or a missing empty think block, garbles its output.
    #expect(S1MiniEngine.prompt(for: "ship it friday") == """
        <|im_start|>system
        You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.<|im_end|>
        <|im_start|>user
        [Styling: semi-formal] [Structure: prose] [Context: general]
        ship it friday<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """)
}

@Test func s1MiniChunksKeepEveryWordAndWholeSentences() {
    let text = "Ship it Friday. No, actually, Thursday! Is that okay? This last sentence is far too long to fit on its own and has no end"
    let chunks = S1MiniEngine.chunks(of: text, fitting: { $0.count <= 40 })
    #expect(chunks == ["Ship it Friday. No, actually, Thursday!", "Is that okay?",
                       "This last sentence is far too long to fit on its own and has no end"])
    #expect(chunks.joined(separator: " ") == text)
}

/// A minimal GGUF v3: one u32 key, one 1-D F32 tensor of `count` floats.
private func syntheticGGUF(alignment: UInt32, floats: [Float]) -> Data {
    func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func str(_ s: String) -> Data { le(UInt64(s.utf8.count)) + Data(s.utf8) }
    var d = Data("GGUF".utf8) + le(UInt32(3)) + le(UInt64(1)) + le(UInt64(1))
    d += str("general.alignment") + le(UInt32(4)) + le(alignment)
    d += str("w") + le(UInt32(1)) + le(UInt64(floats.count)) + le(UInt32(0)) + le(UInt64(0))
    d += Data(count: (d.count + Int(alignment) - 1) / Int(alignment) * Int(alignment) - d.count)
    for f in floats { d += le(f.bitPattern) }
    return d
}

@Test func ggufAppendKeepsTensorsAligned() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let floats: [Float] = [1.5, -2, 3.25, 42]
    // An alignment of 64 and a 5-byte value force new padding, which a naive copy gets wrong.
    try syntheticGGUF(alignment: 64, floats: floats).write(to: dir.appendingPathComponent("in.gguf"))
    try GGUF.appendString(key: "k", value: "hello", from: dir.appendingPathComponent("in.gguf"),
                          to: dir.appendingPathComponent("out.gguf"))
    let out = try Data(contentsOf: dir.appendingPathComponent("out.gguf"))
    var r = GGUF.Reader(data: out)
    #expect(try r.bytes(4) == Data("GGUF".utf8))
    _ = try r.u32()
    #expect(try r.u64() == 1)
    #expect(try r.u64() == 2)
    #expect(try r.string() == "general.alignment")
    #expect(try r.u32() == 4 && r.u32() == 64)
    #expect(try r.string() == "k")
    #expect(try r.u32() == 8 && r.string() == "hello")
    #expect(try r.string() == "w")
    r.offset += 4 + 8 + 4 + 8
    let dataStart = (r.offset + 63) / 64 * 64
    #expect(out.count == dataStart + floats.count * 4)
    let tensor = out[dataStart...].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(tensor == floats)
}

@Test func tarFindsMemberAfterOthers() {
    func entry(_ name: String, _ body: Data) -> Data {
        var header = Data(name.utf8) + Data(count: 100 - name.utf8.count)
        header += Data(count: 24)
        header += Data(String(format: "%011o\0", body.count).utf8)
        header += Data(count: 512 - header.count)
        return header + body + Data(count: (512 - body.count % 512) % 512)
    }
    let archive = entry("./a.yaml", Data(repeating: 7, count: 700)) + entry("./tok.model", Data("spm".utf8)) + Data(count: 1024)
    #expect(Tar.member(named: "./tok.model", in: archive) == Data("spm".utf8))
    #expect(Tar.member(named: "./missing", in: archive) == nil)
}
