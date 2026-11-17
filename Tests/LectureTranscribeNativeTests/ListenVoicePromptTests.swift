import MLX
import XCTest

@testable import LectureTranscribeNative
@testable import Qwen3TTSLocal

/// How sentences reach the Qwen voice: with their whole text in the prompt, several at once, the shorter prompts
/// padded at the front and the padding masked out. (`ListenBenchmarkTests` checks the same with the real model.)
final class ListenVoicePromptTests: XCTestCase {
    /// Whether MLX's compiled shaders (`default.metallib`) came with the tests. MLX stops the whole test run, with no
    /// way to catch it, when it starts without them, and Xcode 26's `swift build` (GitHub's runner) doesn't compile
    /// them; Xcode 27's does, as does the app's DMG build.
    static var mlxShadersBuilt: Bool {
        let bundle = Bundle(for: ListenVoicePromptTests.self)
        let places = [bundle.resourceURL, bundle.bundleURL.deletingLastPathComponent()].compactMap { $0 }
        return places.contains {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib").path)
        }
    }

    private func skipWithoutMLXShaders() throws {
        try XCTSkipUnless(Self.mlxShadersBuilt, "MLX's Metal shaders weren't built with these tests (Xcode 26's swift build).")
    }

    /// Speech saved before whole-text prompts and whole decoding (made a word at a time, or decoded in 2-second pieces
    /// that each lost a little) isn't reused.
    func testSpeechMadeAWordAtATimeIsMadeAgain() {
        let identifier = Qwen3Synthesizer().identifier
        XCTAssertTrue(identifier.hasSuffix("|whole-text|whole-decode"), identifier)
        XCTAssertNotEqual(identifier, "qwen3-tts|\(SpeechModelFiles.ttsModelID)")
    }

    /// Each row sees neither later positions nor its own padding at the front.
    func testThePromptMaskHidesLaterPositionsAndPadding() throws {
        try skipWithoutMLXShaders()
        let mask = Qwen3TTSModel.paddedCausalMask(padding: [0, 2], length: 4, dtype: .float32)
        XCTAssertEqual(mask.shape, [2, 1, 4, 4])
        let hidden = (mask .< MLXArray(Float(-1))).asArray(Bool.self)
        func row(_ batch: Int, _ query: Int) -> [Bool] {
            Array(hidden[(batch * 16 + query * 4)..<(batch * 16 + query * 4 + 4)])
        }
        XCTAssertEqual(row(0, 0), [false, true, true, true])
        XCTAssertEqual(row(0, 3), [false, false, false, false])
        XCTAssertEqual(row(1, 2), [true, true, false, true])
        XCTAssertEqual(row(1, 3), [true, true, false, false])
    }

    /// A step's mask hides each row's padding and has the attention scores' full shape (rows, heads, 1, keys), which
    /// MLX needs to replay the compiled step as the keys grow.
    func testTheStepMaskHasTheScoresShape() throws {
        try skipWithoutMLXShaders()
        let mask = Qwen3TTSModel.paddingMask(padding: [0, 3], heads: 16, keys: 5, dtype: .float32)
        XCTAssertEqual(mask.shape, [2, 16, 1, 5])
        let hidden = (mask .< MLXArray(Float(-1))).asArray(Bool.self)
        XCTAssertEqual(Array(hidden[0..<5]), [false, false, false, false, false])
        XCTAssertEqual(Array(hidden[(16 * 5)..<(16 * 5 + 5)]), [true, true, true, false, false])
        XCTAssertEqual(Array(hidden[(31 * 5)..<(31 * 5 + 5)]), [true, true, true, false, false])
    }

    /// Pieces of codes are decoded padded to a multiple of 25 frames with at least two over, so the decoder gives out
    /// the last frame's last samples and is compiled for only a few lengths.
    func testDecodedPiecesArePaddedToAFewLengths() {
        XCTAssertEqual(SpeechTokenizerDecoder.paddedLength(frames: 1), 25)
        XCTAssertEqual(SpeechTokenizerDecoder.paddedLength(frames: 23), 25)
        XCTAssertEqual(SpeechTokenizerDecoder.paddedLength(frames: 24), 50)
        XCTAssertEqual(SpeechTokenizerDecoder.paddedLength(frames: 101), 125)
        XCTAssertEqual(SpeechTokenizerDecoder.paddedLength(frames: 325), 350)
        let lengths = Set((1...325).map(SpeechTokenizerDecoder.paddedLength(frames:)))
        XCTAssertEqual(lengths.count, 14)
    }

}
