import CryptoKit
import Foundation

/// Saves each finished chunk of a run, so a run that fails or is cancelled can pick up where it stopped:
/// running it again with the same settings reuses the saved chunks instead of paying OpenAI for them twice.
/// The Swift side of the backend's `ChunkResults`, with the same folder, file names and contents, so a run
/// started by either one can be resumed by the other.
final class ChunkResultStore: @unchecked Sendable {
    /// Bump with the backend's RESULTS_FORMAT when what a saved result holds changes.
    static let format = 1
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    let root: URL
    private let lock = NSLock()
    private var kept: Set<URL> = []
    private(set) var reused = 0
    var total = 0

    init(root: URL) {
        self.root = root
    }

    /// Chunks of this run with a saved result, reused or new.
    var keptCount: Int { lock.withLock { kept.count } }
    var reusedCount: Int { lock.withLock { reused } }

    /// A hash of the chunk's audio and everything sent with it, as the backend computes it.
    func key(chunk: URL, request: [String: Any?]) throws -> String {
        var description = request
        description["format"] = Self.format
        description["audio"] = try Self.sha256(of: chunk)
        return Self.hex(SHA256.hash(data: Data(PythonJSON.encode(description).utf8)))
    }

    private func path(_ key: String) -> URL { root.appendingPathComponent("\(key).json") }

    func load(_ key: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: path(key)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func markReused(_ key: String) {
        lock.withLock {
            kept.insert(path(key))
            reused += 1
        }
    }

    /// Saves a result; failing to (a full disk) doesn't fail the run, since results are only kept for resuming.
    func save(_ key: String, _ data: [String: Any?]) {
        let url = path(key)
        let temp = root.appendingPathComponent("\(key).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(PythonJSON.encode(data).utf8).write(to: temp)
            // rename() swaps the file in whole, so a reader never sees half a result.
            guard rename(temp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return
        }
        lock.withLock { _ = kept.insert(url) }
    }

    /// Deletes this run's results once its output is written.
    func discard() {
        let urls = lock.withLock { () -> Set<URL> in
            defer { kept = [] }
            return kept
        }
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Removes saved results too old to be from a run anyone will resume.
    static func prune(_ root: URL, olderThan maxAge: TimeInterval = ChunkResultStore.maxAge) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// JSON written the way Python's `json.dumps(value, sort_keys=True)` writes it: `", "` and `": "` between items,
/// keys sorted, and anything outside ASCII escaped. Saved chunk results are named after a hash of this text, so
/// it has to match character for character.
enum PythonJSON {
    static func encode(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return "null"
        case let value as Bool:
            return value ? "true" : "false"
        case let value as Int:
            return String(value)
        case let value as String:
            return string(value)
        case let value as [String]:
            return "[" + value.map(string).joined(separator: ", ") + "]"
        case let value as [Any?]:
            return "[" + value.map(encode).joined(separator: ", ") + "]"
        case let value as [String: Any?]:
            return "{" + value.keys.sorted().map { "\(string($0)): \(encode(value[$0] ?? nil))" }.joined(separator: ", ") + "}"
        case let value as [String: Any]:
            return "{" + value.keys.sorted().map { "\(string($0)): \(encode(value[$0]))" }.joined(separator: ", ") + "}"
        case let value?:
            return string(String(describing: value))
        }
    }

    private static func string(_ text: String) -> String {
        var out = "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }
}
