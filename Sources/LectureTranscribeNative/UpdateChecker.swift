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
}

/// Checks GitHub Releases for a newer version of the app. Updating stays manual: the user downloads
/// the new DMG and replaces the app in Applications.
@MainActor
final class UpdateChecker: ObservableObject {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/thenameisryanx-dev/transcribe/releases/latest")!
    private static let dismissedVersionDefaultsKey = "dismissedUpdateVersion"

    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckMessage = ""
    @Published private(set) var isBannerDismissed = false

    /// Nil when running from source (`swift run`), which has no Info.plist version.
    let currentVersion: AppVersion?

    init(bundle: Bundle = .main) {
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

    /// Runs on launch. Stays silent on failure so offline launches show nothing.
    func checkOnLaunch() async {
        guard currentVersion != nil else { return }
        await check()
        if let update = availableUpdate,
           UserDefaults.standard.string(forKey: Self.dismissedVersionDefaultsKey) == update.version {
            isBannerDismissed = true
        }
    }

    func checkNow() async {
        isBannerDismissed = false
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
        return AvailableUpdate(version: releaseVersion.description, downloadURL: downloadURL)
    }
}
