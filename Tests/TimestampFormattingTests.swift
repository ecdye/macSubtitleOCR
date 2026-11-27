//
// TimestampFormattingTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

/// Spell a whole number of milliseconds as `HH:MM:SS` followed by `separator` and `mmm`.
private func spelled(_ milliseconds: Int, separator: String) -> String {
    let hours = milliseconds / 3600000
    let minutes = milliseconds / 60000 % 60
    let seconds = milliseconds / 1000 % 60
    return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, separator, milliseconds % 1000)
}

@Test func srtTimestampKeepsEveryMillisecondFromA90kHzClock() {
    let wrong = (0 ..< 100000).filter { milliseconds in
        let time = TimeInterval(milliseconds * 90) / 90000
        return time.srtTimestamp != spelled(milliseconds, separator: ",")
    }
    #expect(wrong.isEmpty, "\(wrong.count) misspelled, first \(wrong.prefix(5))")
}

@Test(arguments: [
    (0, "00:00:00,000"),
    (1.001, "00:00:01,001"),
    (59.9996, "00:01:00,000"),
    (3599.9994, "00:59:59,999"),
    (3599.9996, "01:00:00,000"),
    (3661.5, "01:01:01,500"),
    (-0.5, "00:00:00,000")
] as [(TimeInterval, String)])
func srtTimestampRoundsToTheNearestMillisecond(time: TimeInterval, expected: String) {
    #expect(time.srtTimestamp == expected)
}

@Test(arguments: [
    (0, "00:00:00:000"),
    (90, "00:00:00:001"),
    (44, "00:00:00:000"),
    (45, "00:00:00:001"),
    (90090, "00:00:01:001"),
    (323999955, "01:00:00:000"),
    (329490000, "01:01:01:000")
] as [(UInt64, String)])
func formatTimeRoundsTicksToTheNearestMillisecond(ticks: UInt64, expected: String) {
    #expect(formatTime(ticks) == expected)
}

@Test func idxTimestampsRoundTripToTheSameSRTTimestamp() throws {
    let milliseconds = Array(0 ..< 100000)
    let idx = milliseconds.enumerated()
        .map { "timestamp: \(formatTime(UInt64($1 * 90))), filepos: \(String($0, radix: 16))" }
        .joined(separator: "\n")
    let parsed = try VobSubIDX(idx)

    #expect(parsed.timestamps.count == milliseconds.count)
    let wrong = zip(parsed.timestamps, milliseconds).filter { $0.srtTimestamp != spelled($1, separator: ",") }
    #expect(wrong.isEmpty, "\(wrong.count) misspelled, first \(wrong.prefix(5).map(\.1))")
}
