import Foundation
import XCTest

@testable import LectureTranscribeNative

/// Which of the Transcribe pane's options a run actually sends.
final class RunRequestTests: XCTestCase {
    private func options(
        model: TranscriptionModel = .gptTranscribe,
        diarize: Bool = false,
        subtitles: Bool = false,
        embedSubtitles: Bool = false,
        context: String = "  Organic chemistry, week 3 \n",
        consistencyMode: Bool = true,
        keywords: String = "SN2, Grignard reagent"
    ) -> RunRequest.Options {
        RunRequest.Options(
            model: model,
            diarize: diarize,
            subtitles: subtitles,
            embedSubtitles: embedSubtitles,
            audioTrack: 1,
            languages: ["en"],
            contextPrompt: context,
            consistencyMode: consistencyMode,
            chunkLength: .tenMinutes,
            keywordsText: keywords
        )
    }

    private func request(_ options: RunRequest.Options) -> RunRequest {
        RunRequest(inputPath: "/tmp/lecture.mp4", outputDirectory: "/tmp/out", options: options)
    }

    func testAPlainRunSendsEveryOptionTheModelTakes() {
        let run = request(options())
        XCTAssertFalse(run.diarize)
        XCTAssertEqual(run.context, "Organic chemistry, week 3")
        XCTAssertTrue(run.carryContext)
        XCTAssertEqual(run.chunkSeconds, 600)
        XCTAssertEqual(run.keywords, ["SN2", "Grignard reagent"])
        XCTAssertEqual(run.audioTrack, 1)
        XCTAssertEqual(run.languages, ["en"])
    }

    func testOptionsTheModelDoesntTakeAreDropped() {
        let run = request(options(model: .gpt4oTranscribe))
        XCTAssertEqual(run.context, "Organic chemistry, week 3")
        XCTAssertFalse(run.carryContext, "Only GPT Transcribe uses consistency mode")
        XCTAssertEqual(run.keywords, [], "Only GPT Transcribe takes keywords")
    }

    func testSpeakerLabelsUseTheDiarizeModelsOwnSettings() {
        let run = request(options(model: .gpt4oTranscribe, diarize: true))
        XCTAssertTrue(run.diarize)
        XCTAssertEqual(run.context, "")
        XCTAssertFalse(run.carryContext)
        XCTAssertNil(run.chunkSeconds)
        XCTAssertEqual(run.keywords, [])
    }

    func testSpeakerLabelsNeedAModelThatSupportsThem() {
        XCTAssertFalse(request(options(model: .gpt4oMiniTranscribe, diarize: true)).diarize)
    }

    func testSubtitlesTurnSpeakerLabelsOffAndPromptsOff() {
        let run = request(options(model: .gpt4oTranscribe, diarize: true, subtitles: true, embedSubtitles: true))
        XCTAssertTrue(run.subtitles)
        XCTAssertTrue(run.embedSubtitles)
        XCTAssertFalse(run.diarize)
        XCTAssertEqual(run.context, "")
        XCTAssertNil(run.chunkSeconds)
    }

    func testASubtitledCopyIsOnlyMadeWithSubtitles() {
        XCTAssertFalse(request(options(embedSubtitles: true)).embedSubtitles)
    }

    func testHistoryRecordsWhatTheRunSent() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = request(options(model: .gpt4oTranscribe)).historyEntry(startedAt: started)
        XCTAssertEqual(entry.status, .running)
        XCTAssertEqual(entry.startedAt, started)
        XCTAssertEqual(entry.model, "gpt-4o-transcribe")
        XCTAssertEqual(entry.context, "Organic chemistry, week 3")
        XCTAssertNil(entry.keywords)
        XCTAssertEqual(entry.consistencyMode, false)
        XCTAssertEqual(entry.chunkSeconds, 600)
        XCTAssertEqual(entry.audioTrack, 1)
        XCTAssertNil(entry.subtitles)
    }

    func testBackendArgumentsCarryTheRequest() {
        let args = request(options()).backendArguments
        XCTAssertEqual(Array(args.prefix(7)), ["run", "--input", "/tmp/lecture.mp4", "--output", "/tmp/out", "--model", "gpt-transcribe"])
        XCTAssertTrue(args.contains("--carry-context"))
        XCTAssertEqual(args.firstIndex(of: "--chunk-seconds").map { args[$0 + 1] }, "600")
        XCTAssertEqual(args.firstIndex(of: "--audio-track").map { args[$0 + 1] }, "1")
    }

    @MainActor
    func testTheViewModelSendsWhatThePaneShows() {
        let viewModel = TranscribeViewModel()
        let model = viewModel.selectedTranscriptionModel
        let consistency = viewModel.consistencyModeEnabled
        let chunkLength = viewModel.chunkLengthPreference
        defer {
            viewModel.selectedTranscriptionModel = model
            viewModel.consistencyModeEnabled = consistency
            viewModel.chunkLengthPreference = chunkLength
        }
        viewModel.selectedTranscriptionModel = .gptTranscribe
        viewModel.contextPrompt = "Cell biology"
        viewModel.keywordsText = "mitochondria"
        viewModel.consistencyModeEnabled = true
        viewModel.chunkLengthPreference = .fiveMinutes
        viewModel.subtitlesEnabled = true
        viewModel.embedSubtitlesEnabled = true

        let options = viewModel.runOptions
        XCTAssertEqual(options.model, .gptTranscribe)
        XCTAssertEqual(options.contextPrompt, "Cell biology")
        XCTAssertEqual(options.keywordsText, "mitochondria")
        XCTAssertTrue(options.consistencyMode)
        XCTAssertEqual(options.chunkLength, .fiveMinutes)
        XCTAssertTrue(options.subtitles)
        XCTAssertTrue(options.embedSubtitles)
        XCTAssertEqual(options.languages, viewModel.spokenLanguageCodesForRun)
    }
}
