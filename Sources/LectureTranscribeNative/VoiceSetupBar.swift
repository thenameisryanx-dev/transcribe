import SwiftUI

/// The Listen pane's bottom bar until the voice is on this Mac: what the voice is and what it takes, a Download
/// Voice button, then the download's progress (with Cancel), or why it stopped (with Try Again). The text above
/// can be written, opened and pasted the whole time. Once the download is done the pane shows Play instead.
struct VoiceSetupBar: View {
    @ObservedObject var model: ListenModel
    @State private var freeSpace: Int64?

    var body: some View {
        Group {
            switch model.voiceDownload {
            case .notDownloaded, .downloaded:
                offer
            case .downloading(let progress):
                downloading(progress)
            case .failed(let failure):
                failed(failure)
            }
        }
        .task(id: model.voiceDownload == .notDownloaded) { checkFreeSpace() }
    }

    // MARK: - Not downloaded

    private var offer: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Download the voice to listen")
                    .font(.headline)
                Text("A natural voice that reads aloud on this Mac, offline. Your text never leaves it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if hasRoom {
                    Text(sizeLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Label(notEnoughSpaceLine, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            if !hasRoom {
                Button("Check Again", action: checkFreeSpace)
                    .help("Check the free space again after making room")
            }
            Button("Download Voice", action: model.downloadVoice)
                .buttonStyle(.borderedProminent)
                .disabled(!hasRoom)
                .help("Download the voice once (about \(Self.format(ListenVoiceModel.approximateDownloadSize))). It keeps downloading while you use the rest of the app.")
        }
    }

    private var sizeLine: String {
        var parts = ["About \(Self.format(ListenVoiceModel.approximateDownloadSize)), downloaded once"]
        if let freeSpace {
            parts.append("\(Self.format(freeSpace)) free on this Mac")
        }
        return parts.joined(separator: " · ")
    }

    private var notEnoughSpaceLine: String {
        let needed = Self.format(model.downloadSpaceNeeded)
        let free = freeSpace.map(Self.format) ?? "less"
        return "The voice needs about \(needed) free, and this Mac has \(free). Free up some space, then check again."
    }

    /// When the free space can't be read, the download is let try (and says so if the disk fills).
    private var hasRoom: Bool {
        guard let freeSpace else { return true }
        return freeSpace >= model.downloadSpaceNeeded
    }

    private func checkFreeSpace() {
        freeSpace = freeSpaceForSpeechModels()
    }

    // MARK: - Downloading

    private func downloading(_ progress: VoiceDownloadProgress) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Downloading the voice")
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(Self.progressLine(progress))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: progress.fraction)
                Text("Keep using the app meanwhile: it carries on in the background, and you can get the text ready above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", action: model.cancelVoiceDownload)
                .help("Stop downloading. What's downloaded is kept, so downloading again carries on from there.")
        }
    }

    static func progressLine(_ progress: VoiceDownloadProgress) -> String {
        var parts = ["\(format(progress.bytesDone)) of \(format(progress.totalBytes))"]
        if let seconds = progress.secondsLeft {
            parts.append(timeLeft(seconds))
        }
        return parts.joined(separator: " · ")
    }

    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return "about \(minutes) min left" }
        let hours = (seconds / 3600 * 2).rounded() / 2
        return "about \(hours.formatted(.number.precision(.fractionLength(0...1)))) hr left"
    }

    // MARK: - Failed

    private func failed(_ failure: VoiceDownloadFailure) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: failure.reason == .offline ? "wifi.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("The voice didn't finish downloading")
                    .font(.headline)
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button("Try Again", action: model.downloadVoice)
                .buttonStyle(.borderedProminent)
                .help("Download the rest. What's already downloaded is kept.")
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A small progress ring beside Listen in the sidebar while its voice downloads, so the download can be followed
/// from any pane.
struct ListenSidebarDownloadBadge: View {
    @ObservedObject var model: ListenModel

    var body: some View {
        if case .downloading(let progress) = model.voiceDownload {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .help("Downloading the Listen voice: \(VoiceSetupBar.progressLine(progress))")
        }
    }
}
