// swift-tools-version: 6.0

import Foundation
import PackageDescription

let hasFFmpeg = ProcessInfo.processInfo.environment["USE_FFMPEG"] == "1"

#if arch(arm64)
let includePath = "-I/opt/homebrew/include"
let libPath = "-L/opt/homebrew/lib"
#else
let includePath = "-I/usr/local/include"
let libPath = "-L/usr/local/lib"
#endif
let cSettings: [CSetting] = (hasFFmpeg ? [CSetting.unsafeFlags([includePath])] : [CSetting.unsafeFlags([])])
let linkerSettings: [LinkerSetting] = (hasFFmpeg ? [LinkerSetting.unsafeFlags([libPath])] : [LinkerSetting.unsafeFlags([])])

let package = Package(
    name: "macSubtitleOCR",
    platforms: [
        .macOS("14.0")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "macSubtitleOCR",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ] + (hasFFmpeg ? ["CFFmpeg"] : []),
            cSettings: cSettings,
            linkerSettings: linkerSettings),
        .testTarget(
            name: "macSubtitleOCRTests",
            dependencies: [
                .target(name: "macSubtitleOCR")
            ],
            resources: [
                .process("Resources")
            ])
    ] + (hasFFmpeg ? [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavformat libavcodec libavutil",
            providers: [
                .brew(["ffmpeg"])
            ])
    ] : []))
