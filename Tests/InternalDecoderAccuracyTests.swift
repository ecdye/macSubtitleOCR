//
// InternalDecoderAccuracyTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

/// Runs the CLI with the internal decoder over each bundled input and holds every track's SRT to the
/// internal decoder's entry in `decoder-baseline.json`, as `decoderComparison` does without FFmpeg.
///
/// Scored against `sintel.srt`, the cue count must equal the baseline's, every reference cue that was
/// matched must still be, start and end time errors may be no more than 1 ms beyond the recorded ones
/// (which keep the start times, and the end times of every input but `sintel.sub`, within a frame of
/// the reference), and at most one cue fewer than recorded may be read exactly, for Vision's sake. See
/// `Tests/Resources/README.md`.
@Test(.serialized, arguments: TestFilePaths.allCases)
func internalDecoderMatchesBaseline(file: TestFilePaths) async throws {
    let input = URL(fileURLWithPath: file.path).lastPathComponent
    let outputPath = try makeOutputDirectory()
    defer { try? FileManager.default.removeItem(atPath: outputPath) }

    #if GITHUB_ACTIONS // As the other tests do in CI, to avoid timeouts.
    let arguments = [file.path, outputPath, "--max-threads", "1"]
    #else
    let arguments = [file.path, outputPath]
    #endif
    var runner = try macSubtitleOCR.parse(arguments)
    try await runner.run()

    var tracks: [Int: [SRTCue]] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: outputPath) {
        guard name.hasPrefix("track_"), name.hasSuffix(".srt"),
              let track = Int(name.dropFirst("track_".count).dropLast(".srt".count)) else { continue }
        tracks[track] = try SRTReader.cues(fromFileAt: URL(fileURLWithPath: outputPath).appendingPathComponent(name))
    }

    let reference = try SRTReader.cues(fromFileAt: URL(fileURLWithPath: goodSRTPath))
    let baselineURL = try #require(Bundle.module.url(forResource: "decoder-baseline.json", withExtension: nil))
    let baseline = try DecoderBaseline.load(from: baselineURL)
    let recorded = try #require(baseline.inputs[input], "\(input) has no baseline entry")

    #expect(Set(tracks.keys) == Set(recorded.keys.compactMap { Int($0) }), "\(input): tracks written")
    for (track, cues) in tracks.sorted(by: { $0.key < $1.key }) {
        for failure in baseline.failures(for: CueScore(cues, against: reference), input: input, track: track) {
            Issue.record(Comment(rawValue: failure))
        }
    }
}
