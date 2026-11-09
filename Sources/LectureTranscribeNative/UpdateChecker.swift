import AppKit
import Foundation

/// A dotted version such as "1.2" or "v1.10.0", compared numerically part by part.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else {
            return nil
        }
        components = parts.compactMap { $0 }
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct AvailableUpdate: Equatable {
    let version: String
    /// The DMG for this Mac's architecture when the release has one, otherwise the release page.
    let downloadURL: URL
    /// The DMG for this Mac's architecture, which Install and Relaunch needs; nil when the release has none.
    var dmgURL: URL? = nil
}

enum UpdateInstallState: Equatable {
    case idle
    /// Downloading the new version; the fraction done, when known.
    case downloading(Double?)
    /// Checking the download and handing over to the helper that swaps the app.
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .installing:
            return true
        case .idle, .failed:
            return false
        }
    }
}

/// Checks GitHub Releases for a newer version of the app and installs it: Install and Relaunch downloads the
/// new DMG and replaces this copy (see `UpdateInstaller`). Download opens the DMG for a manual install instead.
@MainActor
final class UpdateChecker: ObservableObject {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/thenameisryanx-dev/transcribe/releases/latest")!
    private static let dismissedVersionDefaultsKey = "dismissedUpdateVersion"

    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckMessage = ""
    @Published private(set) var isBannerDismissed = false
    @Published private(set) var installState: UpdateInstallState = .idle

    /// Nil when running from source (`swift run`), which has no Info.plist version.
    let currentVersion: AppVersion?
    private let bundle: Bundle
    private let failureFileURL: URL
    private var installTask: Task<Void, Never>?

    init(bundle: Bundle = .main, failureFileURL: URL = UpdateInstaller.defaultFailureFileURL) {
        self.bundle = bundle
        self.failureFileURL = failureFileURL
        let versionString = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let version = versionString.flatMap(AppVersion.init)
        // 0.0.0 marks an unversioned build; treat it like a development build.
        currentVersion = version.flatMap { $0.components.allSatisfy { $0 == 0 } ? nil : $0 }
    }

    var currentVersionText: String {
        currentVersion?.description ?? "Development build"
    }

    var showsBanner: Bool {
        availableUpdate != nil && !isBannerDismissed
    }

    /// True when the update can be installed in place rather than only downloaded.
    var offersInstall: Bool {
        availableUpdate?.dmgURL != nil
    }

    /// The Settings status line: install progress or a failed install, otherwise the last check's result.
    var statusMessage: String {
        switch installState {
        case .idle:
            return lastCheckMessage
        case .downloading(let fraction):
            let version = availableUpdate?.version ?? ""
            guard let fraction else { return "Downloading \(version)…" }
            return "Downloading \(version)… \(Int((fraction * 100).rounded()))%"
        case .installing:
            return "Installing… Lecture Transcribe will reopen in a moment."
        case .failed(let message):
            return "Couldn't install the update. \(message)"
        }
    }

    /// Runs on launch. Stays silent on failure so offline launches show nothing.
    func checkOnLaunch() async {
        guard currentVersion != nil else { return }
        // A failed Install and Relaunch reopens this copy and leaves a message saying why.
        let installFailure = UpdateInstaller.takeFailureMessage(at: failureFileURL)
        if let installFailure {
            installState = .failed(installFailure)
        }
        await check()
        if installFailure == nil,
           let update = availableUpdate,
           UserDefaults.standard.string(forKey: Self.dismissedVersionDefaultsKey) == update.version {
            isBannerDismissed = true
        }
    }

    func checkNow() async {
        guard !installState.isBusy else { return }
        isBannerDismissed = false
        installState = .idle
        await check()
    }

    func dismissBanner() {
        isBannerDismissed = true
        if let update = availableUpdate {
            UserDefaults.standard.set(update.version, forKey: Self.dismissedVersionDefaultsKey)
        }
    }

    func openDownload() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.downloadURL)
    }

    /// Downloads the update, checks it, and quits so a helper can swap in the new copy and reopen it.
    func installUpdate() {
        guard installTask == nil, !installState.isBusy,
              let update = availableUpdate, let dmgURL = update.dmgURL,
              let expectedVersion = AppVersion(update.version)
        else {
            return
        }
        let appURL = bundle.bundleURL
        if let reason = UpdateInstaller.reasonCannotInstall(appURL: appURL) {
            installState = .failed(reason)
            return
        }
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            installState = .failed("This copy of the app has no bundle identifier.")
            return
        }

        isBannerDismissed = false
        installState = .downloading(nil)
        let failureFileURL = failureFileURL
        installTask = Task {
            var workDirectory: URL?
            do {
                let directory = try UpdateInstaller.makeWorkDirectory()
                workDirectory = directory
                let dmgFile = directory.appendingPathComponent("update.dmg")
                try await UpdateDownload.run(from: dmgURL, to: dmgFile) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.installState else { return }
                        self.installState = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                installState = .installing
                let stagedApp = try await Task.detached {
                    try UpdateInstaller.stageApp(
                        fromDMG: dmgFile,
                        bundleIdentifier: bundleIdentifier,
                        expectedVersion: expectedVersion,
                        workDirectory: directory
                    )
                }.value
                try Task.checkCancellation()
                try UpdateInstaller.launchSwapHelper(
                    newApp: stagedApp,
                    target: appURL,
                    waitingFor: ProcessInfo.processInfo.processIdentifier,
                    workDirectory: directory,
                    failureFile: failureFileURL
                )
                // The helper owns the work directory now and swaps the app once this process exits.
                workDirectory = nil
                NSApplication.shared.terminate(nil)
            } catch is CancellationError {
                installState = .idle
            } catch let error as URLError where error.code == .cancelled {
                installState = .idle
            } catch {
                installState = .failed(error.localizedDescription)
            }
            if let workDirectory {
                try? FileManager.default.removeItem(at: workDirectory)
            }
            installTask = nil
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    private func check() async {
        guard let currentVersion else {
            lastCheckMessage = "Update checks are off when running from source."
            return
        }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                availableUpdate = nil
                lastCheckMessage = "No releases have been published yet."
                return
            }
            guard status == 200 else {
                lastCheckMessage = "Couldn't check for updates (GitHub returned \(status))."
                return
            }
            availableUpdate = Self.update(fromLatestReleaseJSON: data, currentVersion: currentVersion, arch: Self.hostArch)
            if let availableUpdate {
                lastCheckMessage = "Version \(availableUpdate.version) is available."
            } else {
                lastCheckMessage = "You're up to date."
            }
        } catch {
            lastCheckMessage = "Couldn't check for updates. Check your internet connection."
        }
    }

    static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Parses GitHub's "latest release" response. Returns nil unless the release is newer than `currentVersion`.
    nonisolated static func update(fromLatestReleaseJSON data: Data, currentVersion: AppVersion, arch: String) -> AvailableUpdate? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = object["tag_name"] as? String,
            let releaseVersion = AppVersion(tagName),
            releaseVersion > currentVersion
        else {
            return nil
        }

        let assets = object["assets"] as? [[String: Any]] ?? []
        let dmgURL = assets.lazy
            .filter { ($0["name"] as? String)?.hasSuffix("-\(arch).dmg") == true }
            .compactMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            .first
        let pageURL = (object["html_url"] as? String).flatMap(URL.init(string:))

        guard let downloadURL = dmgURL ?? pageURL else {
            return nil
        }
        return AvailableUpdate(version: releaseVersion.description, downloadURL: downloadURL, dmgURL: dmgURL)
    }
}
