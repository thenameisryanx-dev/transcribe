import Foundation
import XCTest

@testable import LectureTranscribeNative

final class MediaToolsTests: XCTestCase {
    /// The installed app uses the ffmpeg inside it, where the DMG build puts it.
    func testTheAppUsesItsOwnFFmpeg() throws {
        let vendor = try MediaTools.located(environment: [:])
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/Lecture Transcribe.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let tools = app.appendingPathComponent("Contents/Resources/ffmpeg_bin")
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

    /// AAC in a .qta is copied as is; audio an .m4a can't hold (uncompressed PCM) is re-encoded to AAC.
    func testQTAAudioIsCopiedOrReencoded() throws {
        let tools = try MediaTools.located()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for codec in ["aac", "pcm_s16le"] {
            let qta = directory.appendingPathComponent("\(codec).qta")
            let made = try tools.run(tools.ffmpeg, [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "sine=duration=2", "-f", "lavfi", "-i", "sine=frequency=660:duration=3",
                "-map", "0:a", "-map", "1:a", "-c:a", codec, "-f", "mov", qta.path,
            ])
            XCTAssertEqual(made.status, 0, made.errors)
            let output = directory.appendingPathComponent("converted/\(codec).m4a")
            try tools.convertQTA(qta, to: output, audioTrack: 1)
            XCTAssertEqual(tools.audioTracks(output).count, 1, codec)
            XCTAssertEqual(tools.codecName(output), "aac", codec)
            XCTAssertEqual(tools.duration(output), 3, accuracy: 0.1, "The chosen (second) track, \(codec)")
        }
    }

    /// Chunks are shared out in order over up to four stretches, each starting at a cut.
    func testChunksAreSharedOutOverStretches() {
        XCTAssertEqual(MediaTools.encodeStretches(cuts: [], total: 50), [.init(firstChunk: 0, start: 0, end: nil, cuts: [])])
        XCTAssertEqual(MediaTools.encodeStretches(cuts: [10, 20], total: 30, parallel: 1),
                       [.init(firstChunk: 0, start: 0, end: nil, cuts: [10, 20])])
        XCTAssertEqual(MediaTools.encodeStretches(cuts: [10], total: 25), [
            .init(firstChunk: 0, start: 0, end: 10, cuts: []),
            .init(firstChunk: 1, start: 10, end: nil, cuts: []),
        ])
        // Sixteen chunks, as a 2.5-hour movie makes: four stretches of four.
        let cuts = (1...15).map { Double($0) * 600 }
        let stretches = MediaTools.encodeStretches(cuts: cuts, total: 9_000)
        XCTAssertEqual(stretches.map(\.firstChunk), [0, 4, 8, 12])
        XCTAssertEqual(stretches.map(\.start), [0, 2_400, 4_800, 7_200])
        XCTAssertEqual(stretches.map(\.end), [2_400, 4_800, 7_200, nil])
        XCTAssertEqual(stretches[1].cuts, [600, 1_200, 1_800])
        XCTAssertEqual(stretches.map(\.cuts.count).reduce(0, +) + stretches.count, 16)
        // Seven chunks over four stretches: none empty, in order.
        let uneven = MediaTools.encodeStretches(cuts: [1, 2, 3, 4, 5, 6], total: 7)
        XCTAssertEqual(uneven.map(\.firstChunk), [0, 1, 3, 5])
        XCTAssertEqual(uneven.map(\.cuts), [[], [1], [1], [1]])
    }

    /// Surround audio re-encoded by several ffmpegs at once comes out as the same chunks, cut at the same times,
    /// as when one ffmpeg does it all.
    func testParallelReencodingMakesTheSameChunks() throws {
        let tools = try MediaTools.located()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Five minutes of 5.1 tone with a short pause every 50 seconds, in a Matroska file like a movie's.
        let video = directory.appendingPathComponent("movie.mkv")
        let made = try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=300:sample_rate=48000:duration=300",
            "-af", "volume='if(lt(mod(t,50),49.4),1,0)':eval=frame,pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0",
            "-c:a", "flac", video.path,
        ])
        XCTAssertEqual(made.status, 0, made.errors)
        XCTAssertEqual(tools.channelCount(video), 6)

        var progress: [Double] = []
        let parallel = try tools.split(video, into: directory.appendingPathComponent("parallel"), chunkSeconds: 60) {
            progress.append($0)
        }
        let single = try tools.split(video, into: directory.appendingPathComponent("single"), chunkSeconds: 60, parallel: 1)
        XCTAssertEqual(parallel.count, 6)
        XCTAssertEqual(parallel.map(\.lastPathComponent), single.map(\.lastPathComponent))
        for (a, b) in zip(parallel, single) {
            XCTAssertEqual(tools.duration(a), tools.duration(b), accuracy: 0.05, a.lastPathComponent)
            XCTAssertEqual(tools.codecName(a), "aac")
            XCTAssertEqual(tools.channelCount(a), 1)
        }
        XCTAssertEqual(parallel.map(tools.duration).reduce(0, +), 300, accuracy: 0.2)
        XCTAssertEqual(progress, progress.sorted(), "Progress never moves backwards")
        XCTAssertEqual(progress.last ?? 0, 1, accuracy: 0.01)
    }

    /// Cancelling stops every ffmpeg re-encoding at once, not just the last one started.
    func testCancellingStopsEveryParallelEncode() throws {
        let tools = try MediaTools.located()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("movie.mkv")
        let made = try tools.run(tools.ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "anoisesrc=d=1500:c=pink:r=48000:a=0.1",
            "-af", "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0", "-c:a", "flac", video.path,
        ])
        XCTAssertEqual(made.status, 0, made.errors)

        // Cancelled once the chunks are being written (past the share spent finding pauses).
        var cancelledAt: Date?
        XCTAssertThrowsError(try tools.split(video, into: directory.appendingPathComponent("chunks"), chunkSeconds: 300) { fraction in
            if cancelledAt == nil, fraction > MediaTools.splitPlanShare + 0.05 {
                cancelledAt = Date()
                tools.cancel()
            }
        }) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
        let stopped = try XCTUnwrap(cancelledAt, "Cancelled while writing")
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 2, "Every ffmpeg stopped when cancelled")
    }
}
