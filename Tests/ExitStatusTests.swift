//
// ExitStatusTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import ArgumentParser
import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #80: a failed run printed its error and exited 0, and a failed write of the SRT or JSON
// output was not reported at all, so a script could not tell failure from success.

@Test func nonexistentInputExitsWithFailure() async throws {
    let directory = try makeOutputDirectory()
    var runner = try macSubtitleOCR.parse(["\(directory)/missing.sup", directory])
    await #expect(throws: ExitCode.failure) { try await runner.run() }
}

@Test func unsupportedInputExitsWithFailure() async throws {
    let directory = try makeOutputDirectory()
    let input = "\(directory)/input.txt"
    try Data("not a subtitle".utf8).write(to: URL(fileURLWithPath: input))
    var runner = try macSubtitleOCR.parse([input, directory])
    await #expect(throws: ExitCode.failure) { try await runner.run() }
}

/// A regular file where the output directory should be cannot be written into.
@Test func unwritableOutputDirectoryExitsWithFailure() async throws {
    let directory = try makeOutputDirectory()
    let output = "\(directory)/output"
    try Data().write(to: URL(fileURLWithPath: output))
    var runner = try macSubtitleOCR.parse([TestFilePaths.sup.path, output])
    await #expect(throws: ExitCode.failure) { try await runner.run() }
}

/// A failed SRT or JSON write reaches the caller instead of being dropped.
@Test func failedOutputWritesThrow() throws {
    let directory = try makeOutputDirectory()
    // A directory where each output file belongs makes its write fail.
    for name in ["track_0.srt", "track_0.json"] {
        try FileManager.default.createDirectory(atPath: "\(directory)/\(name)", withIntermediateDirectories: false)
    }
    let subtitle = Subtitle(index: 1, text: "Hello", startTimestamp: 0, endTimestamp: 1)
    let result = macSubtitleOCRResult(trackNumber: 0, srt: [subtitle], json: [])
    let handler = try macSubtitleOCRFileHandler(outputDirectory: directory)

    #expect(throws: (any Error).self) { try handler.saveSRTFile(for: result) }
    #expect(throws: (any Error).self) { try handler.saveJSONFile(for: result) }
}
