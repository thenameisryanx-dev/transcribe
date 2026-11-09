import XCTest
@testable import LectureTranscribeNative

/// Install and Relaunch: checking a downloaded DMG and swapping the app once it has quit.
final class UpdateInstallerTests: XCTestCase {
    private var tempDirectory: URL!
    private let fileManager = FileManager.default
    /// Making a DMG takes seconds, so the tests that read one share it.
    private nonisolated(unsafe) static var sharedDMGFolder: URL?

    override class func tearDown() {
        if let sharedDMGFolder {
            try? FileManager.default.removeItem(at: sharedDMGFolder)
        }
        super.tearDown()
    }

    override func setUpWithError() throws {
        tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A read-only folder from a test can't be removed until it's writable again.
        _ = try? run("/bin/chmod", ["-R", "u+w", tempDirectory.path])
        try? fileManager.removeItem(at: tempDirectory)
    }

    // MARK: - Whether this copy can replace itself

    func testWritableAppCanInstall() throws {
        let app = try makeFolderApp(named: "Lecture Transcribe.app", marker: "old")
        XCTAssertNil(UpdateInstaller.reasonCannotInstall(appURL: app))
    }

    func testNonAppAndTranslocatedCopiesCannotInstall() {
        XCTAssertNotNil(UpdateInstaller.reasonCannotInstall(appURL: URL(fileURLWithPath: "/usr/local/bin/LectureTranscribeNative")))
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/ABC/d/Lecture Transcribe.app")
        XCTAssertEqual(
            UpdateInstaller.reasonCannotInstall(appURL: translocated),
            "macOS is running this copy from a temporary location. Move Lecture Transcribe into Applications first."
        )
    }

    func testAppInReadOnlyFolderCannotInstall() throws {
        let app = try makeFolderApp(named: "Lecture Transcribe.app", marker: "old")
        try run("/bin/chmod", ["a-w", tempDirectory.path])
        XCTAssertEqual(
            UpdateInstaller.reasonCannotInstall(appURL: app),
            "You don't have permission to replace the app in \(tempDirectory.lastPathComponent)."
        )
    }

    // MARK: - Swapping the app

    func testHelperWaitsForAppToQuitThenSwapsAndRelaunches() throws {
        let target = try makeFolderApp(named: "Lecture Transcribe.app", marker: "old")
        let work = try UpdateInstaller.makeWorkDirectory()
        let newApp = try makeFolderApp(named: "Lecture Transcribe.app", marker: "new", in: work.appendingPathComponent("new"))
        let failureFile = tempDirectory.appendingPathComponent("failure.txt")
        let relaunchLog = tempDirectory.appendingPathComponent("relaunched.txt")

        // Stands in for the running app: the swap must wait until it exits.
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["0.5"]
        try app.run()

        let helper = try UpdateInstaller.launchSwapHelper(
            newApp: newApp,
            target: target,
            waitingFor: app.processIdentifier,
            workDirectory: work,
            failureFile: failureFile,
            relaunchTool: try makeRelaunchRecorder(logging: relaunchLog)
        )
        helper.waitUntilExit()

        XCTAssertFalse(app.isRunning, "The swap happened before the app quit.")
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertEqual(try marker(of: target), "new")
        XCTAssertFalse(fileManager.fileExists(atPath: work.path), "The work folder (and the old copy) should be removed.")
        XCTAssertFalse(fileManager.fileExists(atPath: failureFile.path))
        XCTAssertEqual(try String(contentsOf: relaunchLog, encoding: .utf8), target.path + "\n")
    }

    func testHelperKeepsOldAppAndReportsWhyWhenSwapFails() throws {
        let target = try makeFolderApp(named: "Lecture Transcribe.app", marker: "old")
        let work = try UpdateInstaller.makeWorkDirectory()
        let missingNewApp = work.appendingPathComponent("new/Lecture Transcribe.app")
        let failureFile = tempDirectory.appendingPathComponent("failure.txt")
        let relaunchLog = tempDirectory.appendingPathComponent("relaunched.txt")

        let helper = try UpdateInstaller.launchSwapHelper(
            newApp: missingNewApp,
            target: target,
            waitingFor: try exitedProcessID(),
            workDirectory: work,
            failureFile: failureFile,
            relaunchTool: try makeRelaunchRecorder(logging: relaunchLog)
        )
        helper.waitUntilExit()

        XCTAssertNotEqual(helper.terminationStatus, 0)
        XCTAssertEqual(try marker(of: target), "old")
        XCTAssertEqual(try String(contentsOf: relaunchLog, encoding: .utf8), target.path + "\n", "The old copy should reopen.")
        let message = try XCTUnwrap(UpdateInstaller.takeFailureMessage(at: failureFile))
        XCTAssertTrue(message.hasPrefix("The new version couldn't be put in place, so the old version was kept."), message)
        XCTAssertFalse(fileManager.fileExists(atPath: failureFile.path), "The message is shown once.")
        XCTAssertNil(UpdateInstaller.takeFailureMessage(at: failureFile))
    }

    // MARK: - Checking the download

    func testStagesMatchingAppFromDMG() throws {
        let dmg = try fakeDMG()
        let work = try UpdateInstaller.makeWorkDirectory()
        defer { try? fileManager.removeItem(at: work) }

        let staged = try UpdateInstaller.stageApp(
            fromDMG: dmg, bundleIdentifier: "com.example.fake", expectedVersion: AppVersion("2.0.0")!, workDirectory: work
        )
        XCTAssertEqual(staged.lastPathComponent, "Fake.app")
        XCTAssertTrue(staged.path.hasPrefix(work.path))
        XCTAssertTrue(fileManager.isExecutableFile(atPath: staged.appendingPathComponent("Contents/MacOS/Fake").path))
        XCTAssertNoThrow(try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]))
        XCTAssertFalse(try isMounted(work.appendingPathComponent("mount")), "The DMG should be ejected.")
    }

    func testRejectsDMGWithWrongVersionOrApp() throws {
        let dmg = try fakeDMG()
        let work = try UpdateInstaller.makeWorkDirectory()
        defer { try? fileManager.removeItem(at: work) }

        XCTAssertThrowsError(try UpdateInstaller.stageApp(
            fromDMG: dmg, bundleIdentifier: "com.example.fake", expectedVersion: AppVersion("2.1")!, workDirectory: work
        )) { error in
            XCTAssertEqual(error.localizedDescription, "The download isn't version 2.1.")
        }
        XCTAssertThrowsError(try UpdateInstaller.stageApp(
            fromDMG: dmg, bundleIdentifier: "com.example.other", expectedVersion: AppVersion("2.0")!, workDirectory: work
        )) { error in
            XCTAssertEqual(error.localizedDescription, "The download doesn't contain Lecture Transcribe.")
        }
        XCTAssertFalse(try isMounted(work.appendingPathComponent("mount")), "The DMG should be ejected after a failure too.")
    }

    func testRejectsAppChangedAfterSigning() throws {
        let app = try makeSignedApp(bundleIdentifier: "com.example.fake", version: "2.0", in: tempDirectory)
        try Data("#!/bin/sh\necho changed\n".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Fake"))

        XCTAssertThrowsError(try UpdateInstaller.validateApp(
            at: app, bundleIdentifier: "com.example.fake", expectedVersion: AppVersion("2.0")!
        )) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("The downloaded app is damaged or was changed"), error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// A folder named like an app holding a marker file, enough to see which copy ends up where.
    private func makeFolderApp(named name: String, marker: String, in folder: URL? = nil) throws -> URL {
        let app = (folder ?? tempDirectory).appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
        return app
    }

    private func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8)
    }

    /// A stand-in for `open` that writes the path it was given to `log`.
    private func makeRelaunchRecorder(logging log: URL) throws -> String {
        let script = tempDirectory.appendingPathComponent("relaunch.sh")
        try Data("#!/bin/sh\necho \"$1\" >> '\(log.path)'\n".utf8).write(to: script)
        try run("/bin/chmod", ["+x", script.path])
        return script.path
    }

    private func exitedProcessID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func makeSignedApp(bundleIdentifier: String, version: String, in folder: URL) throws -> URL {
        let app = folder.appendingPathComponent("Fake.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleExecutable": "Fake",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Fake",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Fake")
        try Data("#!/bin/sh\necho fake\n".utf8).write(to: executable)
        try run("/bin/chmod", ["+x", executable.path])
        try run("/usr/bin/codesign", ["--sign", "-", "--force", app.path])
        return app
    }

    /// A DMG laid out like a release: Fake.app (com.example.fake, version 2.0) and an Applications shortcut.
    private func fakeDMG() throws -> URL {
        if let folder = Self.sharedDMGFolder {
            return folder.appendingPathComponent("Fake.dmg")
        }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("UpdateInstallerDMG-\(UUID().uuidString)", isDirectory: true)
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try makeSignedApp(bundleIdentifier: "com.example.fake", version: "2.0", in: source)
        try fileManager.createSymbolicLink(atPath: source.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let dmg = folder.appendingPathComponent("Fake.dmg")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Fake", "-srcfolder", source.path, "-format", "UDZO", "-ov", dmg.path])
        Self.sharedDMGFolder = folder
        return dmg
    }

    private func isMounted(_ mountPoint: URL) throws -> Bool {
        try run("/usr/bin/hdiutil", ["info"]).contains(mountPoint.path)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError("\(tool) \(arguments.joined(separator: " ")) failed: \(text)")
        }
        return text
    }
}
