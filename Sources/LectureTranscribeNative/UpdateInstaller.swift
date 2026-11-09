import Foundation

struct UpdateInstallError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Replaces the running app with a newer release ("Install and Relaunch"). The app can't overwrite itself while
/// it runs, so it stages the new copy, starts a small helper that waits for the app to quit, swaps the two
/// copies and reopens the app, and then quits.
enum UpdateInstaller {
    /// Where the helper leaves a message when a swap fails, for the reopened app to show.
    static var defaultFailureFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LectureTranscribe", isDirectory: true)
            .appendingPathComponent("last-update-failure.txt")
    }

    /// Why the app at `appURL` can't replace itself, or nil when it can.
    static func reasonCannotInstall(appURL: URL, fileManager: FileManager = .default) -> String? {
        guard appURL.pathExtension == "app" else {
            return "This copy of the app isn't a packaged app."
        }
        if appURL.path.contains("/AppTranslocation/") {
            return "macOS is running this copy from a temporary location. Move Lecture Transcribe into Applications first."
        }
        let folder = appURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: folder.path), fileManager.isWritableFile(atPath: appURL.path) else {
            return "You don't have permission to replace the app in \(folder.lastPathComponent)."
        }
        return nil
    }

    /// A new, empty folder for one install's files, on the same disk as the user's temporary files.
    static func makeWorkDirectory(fileManager: FileManager = .default) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("LectureTranscribeUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Opens the downloaded DMG, checks the app inside, and copies it into `workDirectory`. Returns the copy.
    static func stageApp(
        fromDMG dmgURL: URL,
        bundleIdentifier: String,
        expectedVersion: AppVersion,
        workDirectory: URL
    ) throws -> URL {
        let mountPoint = workDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, dmgURL.path],
                failure: "The download couldn't be opened")
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"], failure: "")
        }

        let candidates = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let appInDMG = candidates.first(where: {
            $0.pathExtension == "app" && infoValue("CFBundleIdentifier", ofAppAt: $0) == bundleIdentifier
        }) else {
            throw UpdateInstallError("The download doesn't contain Lecture Transcribe.")
        }
        try validateApp(at: appInDMG, bundleIdentifier: bundleIdentifier, expectedVersion: expectedVersion)

        let staged = workDirectory.appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent(appInDMG.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [appInDMG.path, staged.path], failure: "The new version couldn't be copied")
        return staged
    }

    /// Checks that the app at `appURL` is this app, at `expectedVersion`, and that its files match its signature.
    static func validateApp(at appURL: URL, bundleIdentifier: String, expectedVersion: AppVersion) throws {
        guard infoValue("CFBundleIdentifier", ofAppAt: appURL) == bundleIdentifier else {
            throw UpdateInstallError("The download doesn't contain Lecture Transcribe.")
        }
        guard let versionString = infoValue("CFBundleShortVersionString", ofAppAt: appURL),
              let version = AppVersion(versionString),
              version == expectedVersion
        else {
            throw UpdateInstallError("The download isn't version \(expectedVersion).")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path],
                failure: "The downloaded app is damaged or was changed")
    }

    /// Starts the helper that waits for process `pid` to exit, swaps `newApp` into `target`, and reopens it.
    /// On failure it puts the old copy back, writes why to `failureFile`, and reopens the old copy.
    static func launchSwapHelper(
        newApp: URL,
        target: URL,
        waitingFor pid: Int32,
        workDirectory: URL,
        failureFile: URL,
        relaunchTool: String = "/usr/bin/open"
    ) throws -> Process {
        try FileManager.default.createDirectory(at: failureFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: failureFile)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", swapScript, "lecture-transcribe-update",
                             String(pid), newApp.path, target.path, workDirectory.path, failureFile.path, relaunchTool]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Reads and removes the message a failed swap left, if any.
    static func takeFailureMessage(at url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// Arguments: pid, new app, target app, work directory, failure file, relaunch tool.
    static let swapScript = #"""
    pid="$1"; new_app="$2"; target="$3"; work_dir="$4"; failure_file="$5"; relaunch="$6"
    backup="$work_dir/previous.app"
    errors="$work_dir/errors.txt"

    fail() {
      { echo "$1"; cat "$errors" 2>/dev/null; } > "$failure_file"
    }

    # Wait up to a minute for the app to quit.
    tries=0
    while kill -0 "$pid" 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -gt 600 ]; then
        fail "The app didn't quit, so the update wasn't installed."
        exit 1
      fi
      sleep 0.1
    done

    if ! mv "$target" "$backup" 2>"$errors"; then
      fail "The old version couldn't be moved aside."
      rm -rf "$work_dir"
      "$relaunch" "$target"
      exit 1
    fi

    if ! mv "$new_app" "$target" 2>"$errors"; then
      if mv "$backup" "$target" 2>>"$errors"; then
        fail "The new version couldn't be put in place, so the old version was kept."
        rm -rf "$work_dir"
      else
        fail "The new version couldn't be put in place. The old version is at $backup."
      fi
      "$relaunch" "$target"
      exit 1
    fi

    rm -rf "$work_dir"
    "$relaunch" "$target"
    """#

    private static func infoValue(_ key: String, ofAppAt appURL: URL) -> String? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }
        return plist[key] as? String
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], failure: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateInstallError("\(failure): \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let detail = text.split(separator: "\n").last.map(String.init) ?? ""
            throw UpdateInstallError(detail.isEmpty ? "\(failure)." : "\(failure) (\(detail)).")
        }
        return text
    }
}

/// Downloads a file with progress, for the update's DMG.
final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var isCancelled = false
    private var finishError: Error?
    private var lastReported = -1.0

    private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Downloads `url` to `destination`, reporting progress from 0 to 1 as it goes.
    static func run(from url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let download = UpdateDownload(destination: destination, onProgress: onProgress)
        try await download.start(url)
    }

    private func start(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: 60))
                let cancelled = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    return isCancelled
                }
                if cancelled {
                    task.cancel()
                }
                task.resume()
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            let task = lock.withLock {
                isCancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let shouldReport = lock.withLock {
            guard fraction - lastReported >= 0.01 || fraction >= 1 else { return false }
            lastReported = fraction
            return true
        }
        if shouldReport {
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so it's moved now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let error: Error?
        if status != 200 {
            error = UpdateInstallError("The download failed (GitHub returned \(status)).")
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                error = nil
            } catch let moveError {
                error = moveError
            }
        }
        lock.withLock { finishError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, finishError, cancelled) = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return (continuation, self.finishError, isCancelled)
        }
        if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error = error ?? finishError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
