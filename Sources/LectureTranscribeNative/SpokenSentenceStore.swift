import CryptoKit
import Foundation

/// A sentence turned into speech: its audio and when each of its words is spoken.
struct SpokenSentence: Equatable, Sendable {
    var samples: [Float]
    var sampleRate: Int
    var wordTimes: [WordTime]

    var duration: Double { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }
}

/// Saves sentences once they've been spoken, so reading the same text again (reopening a document, going back a
/// sentence, changing the speed) plays at once instead of making the speech again. A sentence is saved under a
/// hash of its text and everything that changes how it sounds: the engine, the voice and the language.
final class SpokenSentenceStore: @unchecked Sendable {
    /// Bump when what a saved sentence holds changes, so sentences saved by an older version aren't reused.
    static let format = 1
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
    }

    /// `~/Library/Caches/LectureTranscribe/listen_audio`, beside the transcription scratch files.
    static var defaultRoot: URL {
        let override = (ProcessInfo.processInfo.environment["TRANSCRIBE_WORKDIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base: URL
        if !override.isEmpty {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
            base = caches.appendingPathComponent("LectureTranscribe", isDirectory: true)
        }
        return base.appendingPathComponent("listen_audio", isDirectory: true)
    }

    static func key(text: String, engine: String, voice: String, language: String) -> String {
        let description = ["format=\(format)", "engine=\(engine)", "voice=\(voice)", "language=\(language)", "text=\(text)"]
            .joined(separator: "\n")
        return SHA256.hash(data: Data(description.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Header: Codable {
        var sampleRate: Int
        var sampleCount: Int
        var wordTimes: [WordTime]
    }

    private func audioURL(_ key: String) -> URL { root.appendingPathComponent("\(key).f32") }
    private func headerURL(_ key: String) -> URL { root.appendingPathComponent("\(key).json") }

    func load(_ key: String) -> SpokenSentence? {
        guard let headerData = try? Data(contentsOf: headerURL(key)),
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              let audio = try? Data(contentsOf: audioURL(key)),
              audio.count == header.sampleCount * MemoryLayout<Float>.size
        else { return nil }
        let samples = audio.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // Reading it counts as use, so sentences that keep being read aren't pruned.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: headerURL(key).path)
        return SpokenSentence(samples: samples, sampleRate: header.sampleRate, wordTimes: header.wordTimes)
    }

    /// Saves a sentence; failing to (a full disk) only means it gets spoken afresh next time.
    func save(_ sentence: SpokenSentence, key: String) {
        let header = Header(sampleRate: sentence.sampleRate, sampleCount: sentence.samples.count, wordTimes: sentence.wordTimes)
        let audio = sentence.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            // The audio goes first and the header last: a sentence is only found once both are complete.
            try audio.write(to: audioURL(key), options: .atomic)
            try JSONEncoder().encode(header).write(to: headerURL(key), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: headerURL(key))
        }
    }

    /// Space the saved sentences take, in bytes.
    func size() -> Int64 {
        let files = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func removeAll() {
        try? fileManager.removeItem(at: root)
    }

    /// Removes sentences nobody has listened to for a month.
    func prune(olderThan maxAge: TimeInterval = SpokenSentenceStore.maxAge) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let files = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for header in files where header.pathExtension == "json" {
            guard let modified = try? header.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: header)
            try? fileManager.removeItem(at: header.deletingPathExtension().appendingPathExtension("f32"))
        }
    }
}
