import Foundation
import XCTest

@testable import LectureTranscribeNative

/// Saved chunk results are named and stored exactly as the app's earlier Python backend stored them, so a run it
/// saved can still be resumed.
final class ChunkResultStoreTests: XCTestCase {
    private var directory: URL!
    private var chunk: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chunk = directory.appendingPathComponent("part_000.m4a")
        try Data("not really audio".utf8).write(to: chunk)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The backend's `json.dumps(..., sort_keys=True)` for the same request.
    func testJSONIsWrittenLikePython() {
        let request: [String: Any?] = [
            "kind": "transcript", "model": "gpt-transcribe", "languages": ["en", "fr"],
            "context": "Café — week 3, \"SN2\"\nline two\t/ path 😀", "keywords": ["SN2", "Grignard"],
            "previous_tail": nil, "format": 1,
        ]
        XCTAssertEqual(
            PythonJSON.encode(request),
            #"{"context": "Caf\u00e9 \u2014 week 3, \"SN2\"\nline two\t/ path \ud83d\ude00", "format": 1, "keywords": ["SN2", "Grignard"], "kind": "transcript", "languages": ["en", "fr"], "model": "gpt-transcribe", "previous_tail": null}"#
        )
    }

    /// Keys the backend's `ChunkResults.key` gave for this file and these requests.
    func testKeysMatchTheBackends() throws {
        let store = ChunkResultStore(root: directory)
        XCTAssertEqual(try store.key(chunk: chunk, request: [
            "kind": "transcript", "model": "gpt-transcribe", "languages": ["en", "fr"],
            "context": "Café — week 3, \"SN2\"\nline two\t/ path 😀", "keywords": ["SN2", "Grignard"], "previous_tail": nil,
        ]), "e8ca84927d2cfd58cba397f70fb79ca71087a0728b32934ac486635f630cb950")
        XCTAssertEqual(try store.key(chunk: chunk, request: [
            "kind": "transcript", "model": "gpt-4o-transcribe", "languages": nil, "context": nil, "keywords": nil,
            "previous_tail": "the leaving group departs.",
        ]), "2894fc265be54ca6946a7f1a06d3c8e012823ec6c8030412933b0b2be1008cbe")
    }

    func testSavedResultsAreReadBackAndDiscardedAfterSuccess() throws {
        let store = ChunkResultStore(root: directory.appendingPathComponent("chunk_results"))
        let key = try store.key(chunk: chunk, request: ["kind": "transcript"])
        XCTAssertNil(store.load(key))
        store.save(key, ["text": "Hello — world."])
        XCTAssertEqual(store.load(key)?["text"] as? String, "Hello — world.")
        XCTAssertEqual(store.keptCount, 1)
        store.discard()
        XCTAssertNil(store.load(key))
    }

    func testOldResultsArePruned() throws {
        let root = directory.appendingPathComponent("chunk_results")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("old.json"), recent = root.appendingPathComponent("recent.json")
        try Data("{}".utf8).write(to: old)
        try Data("{}".utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: old.path)
        ChunkResultStore.prune(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }
}
