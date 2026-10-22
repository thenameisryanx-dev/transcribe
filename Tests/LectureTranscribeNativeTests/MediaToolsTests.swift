import Foundation
import XCTest

@testable import LectureTranscribeNative

final class MediaToolsTests: XCTestCase {
    /// The installed app uses the ffmpeg inside it, where the DMG build puts it.
    func testTheAppUsesItsOwnFFmpeg() throws {
        let vendor = try MediaTools.located(environment: [:])
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/Lecture Transcribe.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let tools = app.appendingPathComponent("Contents/Resources/python/ffmpeg_bin")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: vendor.ffmpeg, to: tools.appendingPathComponent("ffmpeg"))
        try FileManager.default.copyItem(at: vendor.ffprobe, to: tools.appendingPathComponent("ffprobe"))

        let located = try MediaTools.located(environment: [:], executable: app.appendingPathComponent("Contents/MacOS/LectureTranscribeNative"))
        XCTAssertEqual(located.ffmpeg.path, tools.appendingPathComponent("ffmpeg").path)
        XCTAssertEqual(located.ffprobe.path, tools.appendingPathComponent("ffprobe").path)
    }

    func testFFMPEGBINChoosesTheTools() throws {
        let vendor = try MediaTools.located(environment: [:])
        let located = try MediaTools.located(environment: ["FFMPEG_BIN": vendor.ffmpeg.path, "FFPROBE_BIN": vendor.ffprobe.path],
                                             executable: URL(fileURLWithPath: "/nowhere/app"))
        XCTAssertEqual(located.ffmpeg, vendor.ffmpeg)
    }

    /// Like the backend's ChunkCutTests: the cut moves back into the pause before the nominal cut.
    func testCutsLandInThePause() throws {
        let tools = try MediaTools.located()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("lecture.m4a")
        let result = try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=300:duration=52",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=0.6",
            "-f", "lavfi", "-i", "sine=frequency=300:duration=37.4",
            "-filter_complex", "[0:a]aformat=sample_rates=44100:channel_layouts=mono[a];[1:a]aformat=sample_rates=44100:channel_layouts=mono[b];"
                + "[2:a]aformat=sample_rates=44100:channel_layouts=mono[c];[a][b][c]concat=n=3:v=0:a=1",
            "-c:a", "aac", audio.path,
        ])
        XCTAssertEqual(result.status, 0)
        let cuts = try tools.chunkCuts(audio, chunkSeconds: 60)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertGreaterThanOrEqual(cuts[0], 52.0)
        XCTAssertLessThanOrEqual(cuts[0], 52.6)
        let parts = try tools.split(audio, into: directory.appendingPathComponent("chunks"), chunkSeconds: 60)
        XCTAssertEqual(parts.map(\.lastPathComponent), ["part_000.m4a", "part_001.m4a"])
        XCTAssertEqual(tools.duration(parts[0]), 52.3, accuracy: 0.3)
    }
}
