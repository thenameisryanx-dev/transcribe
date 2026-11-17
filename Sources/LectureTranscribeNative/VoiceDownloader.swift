import AudioCommon
import Foundation

/// Puts the voice model's files on disk, and nothing more: loading them into memory happens when speech is made.
/// Behind a protocol so the Listen pane's download states can be tested without the network.
protocol SpeechModelDownloader: AnyObject, Sendable {
    /// Whether every file the voice needs is on disk.
    func isDownloaded() -> Bool
    /// About how many more bytes the download needs, for checking there's room before it starts.
    func bytesStillNeeded() -> Int64
    /// Downloads whatever isn't on disk yet. `progress` gets the fraction of the whole download that's done.
    /// Files already complete aren't fetched again, and a large file that was cut off resumes where it stopped.
    /// Throws `CancellationError` soon after the task is cancelled.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Bytes the downloaded files take up.
    func size() -> Int64
    func removeAll() throws
}

/// One of the models the voice downloads: the files its loader needs, and about how big it is.
struct SpeechModelBundle: Sendable {
    let id: String
    /// Besides `config.json` and the weights, which every bundle has.
    let extraFiles: [String]
    let approximateBytes: Int64

    /// The ones Listen reads with, in the order they're fetched. The extra files are the ones each model's
    /// `fromPretrained` asks for, so it finds everything on disk and downloads nothing.
    static let listen: [SpeechModelBundle] = [
        SpeechModelBundle(
            id: SpeechModelFiles.ttsModelID,
            extraFiles: ["merges.txt", "tokenizer_config.json", "vocab.json"],
            approximateBytes: 1_822_000_000
        ),
        SpeechModelBundle(id: SpeechModelFiles.ttsTokenizerID, extraFiles: [], approximateBytes: 682_300_000),
        SpeechModelBundle(
            id: SpeechModelFiles.alignerModelID,
            extraFiles: ["vocab.json", "merges.txt", "tokenizer_config.json", "quantize_config.json"],
            approximateBytes: 983_200_000
        ),
    ]

    func isComplete(in directory: URL) -> Bool {
        guard HuggingFaceDownloader.weightsExist(in: directory) else { return false }
        return (["config.json"] + extraFiles).allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}

/// Downloads the voice from Hugging Face into `SpeechModelFiles.root`.
final class HubSpeechModelDownloader: SpeechModelDownloader, @unchecked Sendable {
    let bundles: [SpeechModelBundle]

    init(bundles: [SpeechModelBundle] = SpeechModelBundle.listen) {
        self.bundles = bundles
    }

    func isDownloaded() -> Bool {
        bundles.allSatisfy(isComplete)
    }

    func bytesStillNeeded() -> Int64 {
        bundles.filter { !isComplete($0) }.reduce(0) { $0 + $1.approximateBytes }
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let total = Double(max(bundles.reduce(0) { $0 + $1.approximateBytes }, 1))
        var before = 0.0
        progress(0)
        for bundle in bundles {
            try Task.checkCancellation()
            let share = Double(bundle.approximateBytes) / total
            if !isComplete(bundle) {
                let start = before
                try await HuggingFaceDownloader.downloadWeights(
                    modelId: bundle.id,
                    to: try SpeechModelFiles.directory(for: bundle.id),
                    additionalFiles: bundle.extraFiles,
                    progressHandler: { fraction in progress(start + min(max(fraction, 0), 1) * share) }
                )
            }
            before += share
            progress(min(before, 1))
        }
    }

    func size() -> Int64 {
        SpeechModelFiles.size()
    }

    func removeAll() throws {
        try SpeechModelFiles.removeAll()
    }

    private func isComplete(_ bundle: SpeechModelBundle) -> Bool {
        guard let directory = try? SpeechModelFiles.directory(for: bundle.id) else { return false }
        return bundle.isComplete(in: directory)
    }
}

/// How the voice's download is going, shown in the Listen pane and Settings ▸ Listen.
enum VoiceDownload: Equatable {
    case notDownloaded
    case downloading(VoiceDownloadProgress)
    case failed(VoiceDownloadFailure)
    case downloaded

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

struct VoiceDownloadProgress: Equatable {
    /// Of the whole download, from 0 to 1.
    var fraction: Double
    var totalBytes: Int64
    /// Nil until enough has downloaded to go by.
    var secondsLeft: Double?

    var bytesDone: Int64 { Int64(Double(totalBytes) * fraction) }
}

/// Why the download stopped, in words people can act on.
struct VoiceDownloadFailure: Equatable {
    enum Reason: Equatable {
        case offline
        case diskFull
        case damaged
        case other
    }

    var reason: Reason
    var message: String

    init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }

    init(_ error: Error) {
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let isDiskFull = [nsError, underlying].contains { error in
            guard let error else { return false }
            return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
        }
        if isDiskFull {
            self.init(reason: .diskFull, message: "This Mac ran out of space. Free up some room, then try again.")
            return
        }
        switch error {
        case DownloadError.networkUnavailable, DownloadError.stalled:
            self.init(reason: .offline, message: Self.offlineMessage)
        case DownloadError.checksumMismatch:
            self.init(reason: .damaged, message: "Part of the download arrived damaged. Try again to fetch it once more.")
        default:
            if nsError.domain == NSURLErrorDomain || underlying?.domain == NSURLErrorDomain {
                self.init(reason: .offline, message: Self.offlineMessage)
            } else {
                self.init(reason: .other, message: "Something went wrong: \(error.localizedDescription)")
            }
        }
    }

    static let offlineMessage = "Couldn't reach the download server. Check that this Mac is online, then try again."
}

/// Free space on the disk the voice is saved to, as macOS counts it for things people asked for.
func freeSpaceForSpeechModels() -> Int64? {
    // The models' folder may not exist yet; its nearest existing parent is on the same disk.
    var url = SpeechModelFiles.root
    while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
    }
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
}

/// Estimates the time a download has left from how fast it has gone since it started (bytes already on disk from
/// before don't count, as they took no time).
@MainActor
final class DownloadTimeEstimate {
    /// Below these, the estimate would jump about too much to be worth showing.
    static let minimumSeconds = 3.0
    static let minimumFraction = 0.005

    private var start: (date: Date, fraction: Double)?

    func secondsLeft(at fraction: Double, now: Date = Date()) -> Double? {
        guard let start else {
            start = (now, fraction)
            return nil
        }
        let elapsed = now.timeIntervalSince(start.date)
        let gained = fraction - start.fraction
        guard elapsed >= Self.minimumSeconds, gained >= Self.minimumFraction else { return nil }
        return elapsed / gained * max(1 - fraction, 0)
    }
}
