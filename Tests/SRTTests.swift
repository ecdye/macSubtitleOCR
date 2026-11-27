//
// SRTTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// These cover the end times the SRT writer gives each cue. Issue #78 found every cue cut to 5 s even
// when the stream gave a longer end time, a 100 ms gap forced before the next cue, and end times
// before the start when cues overlapped.

private struct Cue: Equatable {
    let index: Int
    let start: String
    let end: String
}

/// Writes `subtitles` with the SRT writer and reads back the index and times of each cue.
private func encode(_ subtitles: [Subtitle]) throws -> [Cue] {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SRTTests-\(UUID().uuidString).srt")
    defer { try? FileManager.default.removeItem(at: url) }
    try SRT(subtitles: subtitles).write(toFileAt: url)
    let blocks = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n\n")
    return try blocks.filter { !$0.isEmpty }.map { block in
        let lines = block.components(separatedBy: "\n")
        let times = lines[1].components(separatedBy: " --> ")
        return try Cue(index: #require(Int(lines[0])), start: times[0], end: times[1])
    }
}

private func subtitle(_ index: Int, _ start: TimeInterval, _ end: TimeInterval? = nil) -> Subtitle {
    Subtitle(index: index, text: "Line \(index)", startTimestamp: start, endTimestamp: end)
}

/// A long sign or lyric keeps the end time the stream gave it.
@Test func knownEndTimeIsKept() throws {
    let cues = try encode([subtitle(1, 1, 10), subtitle(2, 20, 30)])
    #expect(cues[0] == Cue(index: 1, start: "00:00:01,000", end: "00:00:10,000"))
    #expect(cues[1] == Cue(index: 2, start: "00:00:20,000", end: "00:00:30,000"))
}

/// Without an end time a cue stays up for 5 s, or until the next cue starts if that is sooner.
@Test func unknownEndTimeDefaultsToFiveSecondsOrNextStart() throws {
    let cues = try encode([subtitle(1, 1), subtitle(2, 4), subtitle(3, 20)])
    #expect(cues[0].end == "00:00:04,000")
    #expect(cues[1].end == "00:00:09,000")
    #expect(cues[2].end == "00:00:25,000")
}

/// A new bitmap subtitle replaces the one on screen, so a known end time stops at the next start.
@Test func knownEndTimeStopsAtNextStart() throws {
    let cues = try encode([subtitle(1, 1, 12), subtitle(2, 8, 14)])
    #expect(cues[0].end == "00:00:08,000")
    #expect(cues[1].end == "00:00:14,000")
}

/// Cues out of time order, or an end time before the start, never give an end before the start.
@Test func endTimeIsNeverBeforeStart() throws {
    let cues = try encode([subtitle(1, 10, 15), subtitle(2, 5), subtitle(3, 6, 2)])
    #expect(cues[0] == Cue(index: 1, start: "00:00:10,000", end: "00:00:15,000"))
    #expect(cues[1] == Cue(index: 2, start: "00:00:05,000", end: "00:00:06,000"))
    #expect(cues[2] == Cue(index: 3, start: "00:00:06,000", end: "00:00:06,000"))
}

/// The next cue is the next one written, whatever the indexes are.
@Test func nextCueIsFoundByPosition() throws {
    let cues = try encode([subtitle(3, 1), subtitle(7, 3), subtitle(8, 30)])
    #expect(cues.map(\.index) == [3, 7, 8])
    #expect(cues[0].end == "00:00:03,000")
    #expect(cues[1].end == "00:00:08,000")
    #expect(cues[2].end == "00:00:35,000")
}

/// Writing does not change the subtitles it was given.
@Test func writingLeavesSubtitlesUnchanged() throws {
    let subtitles = [subtitle(1, 1), subtitle(2, 3, 20)]
    _ = try encode(subtitles)
    #expect(subtitles[0].endTimestamp == nil)
    #expect(subtitles[1].endTimestamp == 20)
}
