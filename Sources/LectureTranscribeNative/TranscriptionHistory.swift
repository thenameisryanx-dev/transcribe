import Foundation

struct TranscriptionHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case running
        case success
        case failed
        case cancelled

        var displayName: String {
            switch self {
            case .running:
                return "Running"
            case .success:
                return "Success"
            case .failed:
                return "Failed"
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    let id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var inputPath: String
    var outputPath: String?
    var outputDirectory: String
    var diarize: Bool
    var status: Status
    var errorMessage: String?
}

private struct TranscriptionHistoryPayload: Codable {
    var schemaVersion: Int
    var entries: [TranscriptionHistoryEntry]
}

struct TranscriptionHistoryStore {
    private let fileManager: FileManager
    private let historyFileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        let containerURL = applicationSupportURL.appendingPathComponent("LectureTranscribe", isDirectory: true)
        historyFileURL = containerURL.appendingPathComponent("history.json", isDirectory: false)
    }

    func loadEntries() throws -> [TranscriptionHistoryEntry] {
        guard fileManager.fileExists(atPath: historyFileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: historyFileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let payload = try? decoder.decode(TranscriptionHistoryPayload.self, from: data) {
            return payload.entries
        }

        // Backward-compatible fallback in case we ever persisted a raw array.
        return try decoder.decode([TranscriptionHistoryEntry].self, from: data)
    }

    func saveEntries(_ entries: [TranscriptionHistoryEntry]) throws {
        try fileManager.createDirectory(
            at: historyFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = TranscriptionHistoryPayload(schemaVersion: 1, entries: entries)
        let data = try encoder.encode(payload)
        try data.write(to: historyFileURL, options: .atomic)
    }
}
