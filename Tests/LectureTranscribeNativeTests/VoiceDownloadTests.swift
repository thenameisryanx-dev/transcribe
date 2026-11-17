import AudioCommon
import Foundation
import XCTest

@testable import LectureTranscribeNative

/// A voice download that goes as far as `stopsAt`, then waits for `finish()` (or `fail(with:)`) before it's done,
/// so each state of the Listen pane's download can be seen. Records how often it was started and removed.
final class FakeDownloader: SpeechModelDownloader, @unchecked Sendable {
    private let state: Locked<(downloaded: Bool, starts: Int, removals: Int, finish: Bool, failure: Error?)>
    let stopsAt: Double

    init(downloaded: Bool = false, stopsAt: Double = 0.4) {
        state = Locked((downloaded, 0, 0, false, nil))
        self.stopsAt = stopsAt
    }

    var starts: Int { state.value.starts }
    var removals: Int { state.value.removals }

    func finish() { state.update { $0.finish = true } }
    func fail(with error: Error) { state.update { $0.failure = error } }

    func isDownloaded() -> Bool { state.value.downloaded }
    func bytesStillNeeded() -> Int64 { isDownloaded() ? 0 : 1_000 }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        state.update {
            $0.starts += 1
            $0.finish = false
        }
        progress(stopsAt)
        while true {
            try await Task.sleep(for: .milliseconds(10))
            let now = state.value
            if let failure = now.failure {
                state.update { $0.failure = nil }
                throw failure
            }
            if now.finish { break }
        }
        state.update { $0.downloaded = true }
        progress(1)
    }

    func size() -> Int64 { isDownloaded() ? 3_000 : 0 }

    func removeAll() throws {
        state.update {
            $0.downloaded = false
            $0.removals += 1
        }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// The voice is downloaded on its own, before Play is offered, rather than by the first Play.
final class VoiceDownloadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func downloadFraction(_ model: ListenModel) -> Double? {
        if case .downloading(let progress) = model.voiceDownload { return progress.fraction }
        return nil
    }

    @MainActor
    func testPlayDoesNothingUntilTheVoiceIsDownloaded() async {
        let synthesizer = FakeSynthesizer()
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, downloader: FakeDownloader())
        XCTAssertEqual(model.voiceDownload, .notDownloaded)
        XCTAssertFalse(model.modelsDownloaded)
        model.text = "Nothing is read yet."
        model.play()
        XCTAssertEqual(model.stage, .editing, "Play doesn't download the voice or make speech any more")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(synthesizer.spoken.isEmpty)
        XCTAssertFalse(synthesizer.isLoaded)
    }

    @MainActor
    func testDownloadingShowsProgressThenOffersPlayWithoutLoadingTheVoice() async {
        let synthesizer = FakeSynthesizer()
        let downloader = FakeDownloader(stopsAt: 0.4)
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, downloader: downloader)
        model.text = "Ready when you are."
        model.downloadVoice()
        XCTAssertTrue(model.voiceDownload.isDownloading)
        await waitUntil { self.downloadFraction(model) == 0.4 }
        guard case .downloading(let progress) = model.voiceDownload else {
            return XCTFail("Expected the download to be going, got \(model.voiceDownload)")
        }
        XCTAssertEqual(progress.fraction, 0.4)
        XCTAssertEqual(progress.totalBytes, ListenVoiceModel.approximateDownloadSize)
        XCTAssertEqual(progress.bytesDone, Int64(Double(ListenVoiceModel.approximateDownloadSize) * 0.4))
        XCTAssertEqual(model.stage, .editing, "The text can still be edited while it downloads")

        // Asking again while it downloads doesn't start a second download.
        model.downloadVoice()
        downloader.finish()
        await waitUntil { model.voiceDownload == .downloaded }
        XCTAssertEqual(model.voiceDownload, .downloaded)
        XCTAssertTrue(model.modelsDownloaded)
        XCTAssertTrue(model.voiceJustDownloaded, "The pane says the voice is ready")
        XCTAssertEqual(downloader.starts, 1)
        XCTAssertFalse(synthesizer.isLoaded, "Downloading only puts the files on disk; Play loads them")
        XCTAssertEqual(model.stage, .editing, "Reading doesn't start by itself")

        model.play()
        XCTAssertFalse(model.voiceJustDownloaded)
        await waitUntil { model.isReading }
        XCTAssertTrue(model.isReading)
        XCTAssertFalse(synthesizer.spoken.isEmpty)
        model.editText()
    }

    @MainActor
    func testCancellingGoesBackToTheOfferAndDownloadingAgainCarriesOn() async {
        let downloader = FakeDownloader()
        let model = makeTestListenModel(directory: directory, downloader: downloader)
        model.downloadVoice()
        await waitUntil { self.downloadFraction(model) != nil && self.downloadFraction(model)! > 0 }
        model.cancelVoiceDownload()
        XCTAssertEqual(model.voiceDownload, .notDownloaded)

        // A download cancelled and started again straight away isn't confused with the old one.
        model.downloadVoice()
        XCTAssertTrue(model.voiceDownload.isDownloading)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.voiceDownload.isDownloading, "The cancelled download ending doesn't stop the new one")
        await waitUntil { downloader.starts == 2 }
        downloader.finish()
        await waitUntil { model.voiceDownload == .downloaded }
        XCTAssertEqual(model.voiceDownload, .downloaded)
        XCTAssertEqual(downloader.starts, 2)
    }

    @MainActor
    func testAFailedDownloadSaysWhyAndCanBeTriedAgain() async {
        let downloader = FakeDownloader()
        let model = makeTestListenModel(directory: directory, downloader: downloader)
        model.downloadVoice()
        await waitUntil { downloader.starts == 1 }
        downloader.fail(with: URLError(.notConnectedToInternet))
        await waitUntil {
            if case .failed = model.voiceDownload { return true }
            return false
        }
        guard case .failed(let failure) = model.voiceDownload else {
            return XCTFail("Expected the download to have failed, got \(model.voiceDownload)")
        }
        XCTAssertEqual(failure.reason, .offline)
        XCTAssertEqual(failure.message, VoiceDownloadFailure.offlineMessage)
        XCTAssertNil(model.errorMessage, "The failure is shown where the download is, not in a banner")

        model.downloadVoice()
        XCTAssertTrue(model.voiceDownload.isDownloading)
        await waitUntil { downloader.starts == 2 }
        downloader.finish()
        await waitUntil { model.voiceDownload == .downloaded }
        XCTAssertEqual(model.voiceDownload, .downloaded)
    }

    @MainActor
    func testDeletingTheVoiceGoesBackToTheDownloadOffer() async {
        let synthesizer = FakeSynthesizer()
        let downloader = FakeDownloader(downloaded: true)
        let model = makeTestListenModel(directory: directory, synthesizer: synthesizer, downloader: downloader)
        XCTAssertEqual(model.voiceDownload, .downloaded)
        model.text = "First sentence. Second sentence."
        model.play()
        await waitUntil { model.isReading }

        model.deleteVoiceModels()
        XCTAssertEqual(downloader.removals, 1)
        XCTAssertEqual(model.voiceDownload, .notDownloaded)
        XCTAssertEqual(model.stage, .editing)
        model.play()
        XCTAssertEqual(model.stage, .editing)
    }

    @MainActor
    func testDeletingWhileDownloadingStopsTheDownload() async {
        let downloader = FakeDownloader()
        let model = makeTestListenModel(directory: directory, downloader: downloader)
        model.downloadVoice()
        await waitUntil { downloader.starts == 1 }
        model.deleteVoiceModels()
        XCTAssertEqual(model.voiceDownload, .notDownloaded)
        downloader.finish()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.voiceDownload, .notDownloaded)
    }

    @MainActor
    func testFilesRemovedOutsideTheAppAreNoticed() {
        let downloader = FakeDownloader(downloaded: true)
        let model = makeTestListenModel(directory: directory, downloader: downloader)
        try? downloader.removeAll()
        model.refreshVoiceDownload()
        XCTAssertEqual(model.voiceDownload, .notDownloaded)
    }

    func testFailuresAreSaidInWordsPeopleCanActOn() {
        XCTAssertEqual(VoiceDownloadFailure(DownloadError.networkUnavailable(modelId: "m", detail: "offline")).reason, .offline)
        XCTAssertEqual(VoiceDownloadFailure(DownloadError.stalled(modelId: "m", seconds: 60)).reason, .offline)
        XCTAssertEqual(VoiceDownloadFailure(URLError(.timedOut)).reason, .offline)
        XCTAssertEqual(VoiceDownloadFailure(DownloadError.checksumMismatch(file: "f", expected: "a", actual: "b")).reason, .damaged)
        XCTAssertEqual(VoiceDownloadFailure(CocoaError(.fileWriteOutOfSpace)).reason, .diskFull)
        XCTAssertEqual(VoiceDownloadFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).reason, .diskFull)
        let other = VoiceDownloadFailure(DownloadError.failedToDownload("config.json"))
        XCTAssertEqual(other.reason, .other)
        XCTAssertTrue(other.message.contains("config.json"))
    }

    @MainActor
    func testTimeLeftWaitsForEnoughToGoBy() {
        let estimate = DownloadTimeEstimate()
        let start = Date()
        XCTAssertNil(estimate.secondsLeft(at: 0.2, now: start), "Bytes already on disk took no time")
        XCTAssertNil(estimate.secondsLeft(at: 0.3, now: start.addingTimeInterval(1)), "Too soon to tell")
        // 0.2 → 0.4 in 10 seconds, so the 0.6 left takes about 30.
        XCTAssertEqual(estimate.secondsLeft(at: 0.4, now: start.addingTimeInterval(10)) ?? 0, 30, accuracy: 0.001)
    }

    func testProgressIsDescribedInBytesAndTime() {
        XCTAssertEqual(VoiceSetupBar.timeLeft(20), "under a minute left")
        XCTAssertEqual(VoiceSetupBar.timeLeft(4 * 60), "about 4 min left")
        XCTAssertEqual(VoiceSetupBar.timeLeft(3 * 3600), "about 3 hr left")
        let progress = VoiceDownloadProgress(fraction: 0.5, totalBytes: 2_000_000_000, secondsLeft: 120)
        XCTAssertEqual(
            VoiceSetupBar.progressLine(progress),
            "\(VoiceSetupBar.format(1_000_000_000)) of \(VoiceSetupBar.format(2_000_000_000)) · about 2 min left"
        )
    }

    /// The download fetches exactly what each model's loader looks for, so loading on Play downloads nothing.
    func testABundleIsCompleteOnlyWithItsWeightsAndFiles() throws {
        let bundle = SpeechModelBundle(id: "test/model", extraFiles: ["vocab.json"], approximateBytes: 1)
        let folder = directory.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(bundle.isComplete(in: folder))
        try Data().write(to: folder.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        XCTAssertFalse(bundle.isComplete(in: folder), "vocab.json is still missing")
        try Data("{}".utf8).write(to: folder.appendingPathComponent("vocab.json"))
        XCTAssertTrue(bundle.isComplete(in: folder))
    }

    func testTheBundlesAddUpToTheSizeShownBeforeDownloading() {
        let total = SpeechModelBundle.listen.reduce(0) { $0 + $1.approximateBytes }
        XCTAssertEqual(Double(total), Double(ListenVoiceModel.approximateDownloadSize), accuracy: Double(ListenVoiceModel.approximateDownloadSize) * 0.02)
        XCTAssertEqual(Set(SpeechModelBundle.listen.map(\.id)), Set(ListenVoiceModel.modelIDs))
    }
}
