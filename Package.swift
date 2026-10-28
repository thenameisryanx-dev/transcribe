// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let deploymentTarget = "13.0"

// SwiftPM's default build system links without telling clang which SDK it is
// using, so the binary records the deployment target (13.0) as its SDK version.
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
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "LectureTranscribeNative",
            targets: ["LectureTranscribeNative"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "LectureTranscribeNative",
            linkerSettings: sdkVersionLinkerSettings
        ),
        .testTarget(
            name: "LectureTranscribeNativeTests",
            dependencies: ["LectureTranscribeNative"]
        ),
    ]
)
