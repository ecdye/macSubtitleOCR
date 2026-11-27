//
// DecoderMetricsTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
import Testing

@Test func srtReaderReadsCuesWithBOMAndCRLF() {
    let srt = "\u{FEFF}1\r\n00:01:47,250 --> 00:01:49,220\r\nThis blade\r\nhas a dark past.\r\n\r\n" +
        "2\r\n01:00:00.500 --> 01:00:01,000 X1:0\r\nOK.\r\n"
    let cues = SRTReader.cues(from: srt)
    #expect(cues == [
        SRTCue(start: 107.25, end: 109.22, text: "This blade\nhas a dark past."),
        SRTCue(start: 3600.5, end: 3601, text: "OK.")
    ])
    #expect(cues[0].normalizedText == "This blade has a dark past.")
}

@Test func cuesAreMatchedByOverlapThenNearestStart() {
    let reference = [
        SRTCue(start: 10, end: 12, text: "a"),
        SRTCue(start: 20, end: 22, text: "b"),
        SRTCue(start: 30, end: 30.1, text: "c"),
        SRTCue(start: 40, end: 42, text: "d")
    ]
    let output = [
        // Overlaps the first cue a little and the second a lot, so it stands for the second.
        SRTCue(start: 11.9, end: 21.5, text: "b"),
        SRTCue(start: 10, end: 11.9, text: "a"),
        // Does not overlap the third cue but starts within a second of it.
        SRTCue(start: 30.5, end: 31, text: "c"),
        // Too far from anything to be matched.
        SRTCue(start: 50, end: 52, text: "d")
    ]
    let pairs = CueMatcher.pairs(output, reference)
    #expect(pairs.map(\.reference.text) == ["a", "b", "c"])
    #expect(pairs.map(\.output.text) == ["a", "b", "c"])
}

@Test func cueScoreCountsExactTextAndTimingError() {
    let reference = [
        SRTCue(start: 1, end: 2, text: "one"),
        SRTCue(start: 3, end: 4, text: "two\nlines")
    ]
    let output = [
        SRTCue(start: 1.017, end: 2, text: "one"),
        SRTCue(start: 3, end: 4.04, text: "two lines!")
    ]
    let score = CueScore(output, against: reference)
    #expect(score.cues == 2)
    #expect(score.matched == 2)
    #expect(score.exact == 1)
    #expect(score.maxStartErrorMs == 17)
    #expect(score.meanStartErrorMs == 8.5)
    #expect(score.maxEndErrorMs == 40)
}

@Test func baselineAllowsOneFewerExactCueAndNoWorseTiming() {
    let reference = (0 ..< 4).map { SRTCue(start: Double($0) * 10, end: Double($0) * 10 + 2, text: "cue \($0)") }
    let recorded = CueScore(reference, against: reference)
    let baseline = DecoderBaseline(inputs: ["in.sup": ["0": DecoderBaseline.Entry(recorded)]])
    #expect(baseline.failures(for: recorded, input: "in.sup", track: 0).isEmpty)

    var oneMisread = reference
    oneMisread[0] = SRTCue(start: 0, end: 2, text: "cue O")
    #expect(baseline.failures(for: CueScore(oneMisread, against: reference), input: "in.sup", track: 0).isEmpty)

    var twoMisread = oneMisread
    twoMisread[1] = SRTCue(start: 10, end: 12, text: "cue l")
    #expect(baseline.failures(for: CueScore(twoMisread, against: reference), input: "in.sup", track: 0).count == 1)

    var late = reference
    late[2] = SRTCue(start: 20.04, end: 22, text: "cue 2")
    #expect(!baseline.failures(for: CueScore(late, against: reference), input: "in.sup", track: 0).isEmpty)

    #expect(baseline.failures(for: recorded, input: "in.sup", track: 1).count == 1)
}

@Test func internalDecoderMayNotTrailFFmpeg() {
    let reference = [SRTCue(start: 1, end: 2, text: "one"), SRTCue(start: 3, end: 4, text: "two")]
    let both = CueScore(reference, against: reference)
    #expect(DecoderComparison.failures(internal: both, ffmpeg: both, label: "x").isEmpty)

    let misread = CueScore([reference[0], SRTCue(start: 3, end: 4, text: "tw0")], against: reference)
    #expect(DecoderComparison.failures(internal: misread, ffmpeg: both, label: "x").count == 1)
    #expect(DecoderComparison.failures(internal: both, ffmpeg: misread, label: "x").isEmpty)

    #expect(DecoderComparison.allowedCueShortfall(ffmpegCues: 26) == 1)
    #expect(DecoderComparison.allowedCueShortfall(ffmpegCues: 2590) == 25)
}
