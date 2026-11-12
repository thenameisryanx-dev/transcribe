// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let deploymentTarget = "15.0"

// SwiftPM's default build system links without telling clang which SDK it is
// using, so the binary records the deployment target (15.0) as its SDK version.
// macOS then runs the app in legacy appearance mode instead of the current
// system design (Liquid Glass). Record the real SDK version from SDKROOT, which
// the `swift` shim exports via xcrun.
let sdkVersionLinkerSettings: [LinkerSetting] = {
    guard
        let sdkRoot = Context.environment["SDKROOT"],
        let data = FileManager.default.contents(atPath: sdkRoot + "/SDKSettings.json"),
        let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let sdkVersion = settings["Version"] as? String
    else {
        return []
    }
    return [
        .unsafeFlags([
            "-Xlinker", "-platform_version",
            "-Xlinker", "macos",
            "-Xlinker", deploymentTarget,
            "-Xlinker", sdkVersion,
        ]),
    ]
}()

let package = Package(
    name: "LectureTranscribeNative",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "LectureTranscribeNative",
            targets: ["LectureTranscribeNative"]
        ),
    ],
    dependencies: [
        // On-device text to speech (Qwen3-TTS) and word timing (Qwen3-ForcedAligner) for the Listen pane,
        // run on the GPU with MLX. Pinned exactly: the package is pre-1.0 and its API changes between releases.
        // It needs macOS 15, which is why the app does.
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.29"),
    ],
    targets: [
        .executableTarget(
            name: "LectureTranscribeNative",
            dependencies: [
                .product(name: "Qwen3TTS", package: "speech-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ],
            linkerSettings: sdkVersionLinkerSettings
        ),
        .testTarget(
            name: "LectureTranscribeNativeTests",
            dependencies: ["LectureTranscribeNative"]
        ),
    ]
)
