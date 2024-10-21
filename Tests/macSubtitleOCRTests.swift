//
// macSubtitleOCRTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

let goodSRTPath = Bundle.module.url(forResource: "sintel.srt", withExtension: nil)!.path
let goodJSONPath = Bundle.module.url(forResource: "sintel.json", withExtension: nil)!.path
#if GITHUB_ACTIONS // Lower thread count for CI to avoid timeouts
    let options = ["--json", "--max-threads", "1"]
#else
    let options = ["--json"]
#endif

@Test(.serialized, arguments: TestFilePaths.allCases.map(\.path))
func ffmpegDecoder(path: String) async throws {
    let outputPath = URL.temporaryDirectory.path
    let options = [path, outputPath, "--ffmpeg-decoder"] + options
    try await runTest(with: options)
}

@Test(.serialized, arguments: TestFilePaths.allCases.map(\.path))
func internalDecoder(path: String) async throws {
    let outputPath = URL.temporaryDirectory.path
    let options = [path, outputPath] + options
    try await runTest(with: options)
}

private func runTest(with options: [String]) async throws {
    let outputPath = options[1]

    // Run tests
    let runner = try macSubtitleOCR.parse(options)
    try await runner.run()

    try compareOutputs(with: outputPath, track: 0)

    // Compare output for track 1 if it's an MKV file
    if options[0].contains(".mks") {
        try compareOutputs(with: outputPath, track: 1)
    }
}

private func compareOutputs(with outputPath: String, track: Int) throws {
    let srtExpectedOutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
    let jsonExpectedOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
    let srtActualOutput = try String(contentsOfFile: "\(outputPath)/track_\(track).srt", encoding: .utf8)
    let jsonActualOutput = try String(contentsOfFile: "\(outputPath)/track_\(track).json", encoding: .utf8)

    let srtMatch = similarityPercentage(of: srtExpectedOutput, and: srtActualOutput)
    let jsonMatch = similarityPercentage(of: jsonExpectedOutput, and: jsonActualOutput)

    #expect(srtMatch >= 85.0) // Lower threshold due to timestamp differences
    #expect(jsonMatch >= 95.0)
}
