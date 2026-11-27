//
// VobSubDelayTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// MARK: - Out-of-range delays

@Test(arguments: [
    "delay: 9999999999999999:00:00:000",
    "delay: -9999999999999999:00:00:000",
    "delay: 00:00:00:99999999999999999999",
    "delay: 2147483648:00:00:000",
    "delay: -00:-2147483649:00:000"
])
func vobSubIDXIgnoresAnOutOfRangeDelay(line: String) throws {
    // FFmpeg reads each field into a C int, so a field past 32 bits has no defined value. The
    // line is ignored and the delay before it stays in effect.
    let idx = try VobSubIDX("""
    delay: 00:00:01:500
    timestamp: 00:00:10:000, filepos: 000000000
    \(line)
    timestamp: 00:00:20:000, filepos: 000000800
    """)
    #expect(idx.timestamps == [11.5, 21.5])
    #expect(idx.streams.map(\.delays) == [[1.5, 1.5]])
}

@Test func vobSubIDXAcceptsTheLargestDelayFFmpegCanRead() throws {
    let idx = try VobSubIDX("""
    delay: -2147483647:2147483647:2147483647:2147483647
    timestamp: 00:00:00:000, filepos: 000000000
    """)
    let milliseconds = (2147483647 * 3600 + 2147483647 * 60 + 2147483647) * 1000 + 2147483647
    #expect(idx.streams.map(\.delays) == [[-TimeInterval(milliseconds) / 1000]])
}

@Test func vobSubIDXHugeNegativeDelayIsWrittenAsZero() throws {
    let idx = try VobSubIDX("""
    delay: -2147483647:00:00:000
    timestamp: 00:00:00:500, filepos: 000000000
    """)
    let timestamp = try #require(idx.timestamps.first)
    #expect(timestamp < 0)
    #expect(timestamp.srtTimestamp == "00:00:00,000")
}

// MARK: - Out-of-range timestamps

@Test(arguments: [
    "timestamp: inf:00:00:000, filepos: 000000000",
    "timestamp: 00:-inf:00:000, filepos: 000000000",
    "timestamp: nan:00:00:000, filepos: 000000000",
    "timestamp: 00:00:00:1e999, filepos: 000000000",
    "timestamp: 1e305:1e305:00:000, filepos: 000000000"
])
func vobSubIDXSkipsANonFiniteTimestamp(line: String) throws {
    let idx = try VobSubIDX("""
    \(line)
    timestamp: 00:00:20:000, filepos: 000000800
    """)
    #expect(idx.timestamps == [20])
    #expect(idx.offsets == [0x800])
}

@Test func vobSubIDXKeepsAHugeFiniteTimestampWithADelay() throws {
    let idx = try VobSubIDX("""
    delay: 2147483647:00:00:000
    timestamp: 99999999999999999999:00:00:000, filepos: 000000000
    """)
    let timestamp = try #require(idx.timestamps.first)
    #expect(timestamp.isFinite)
    #expect(timestamp.srtTimestamp == "2562047788015:12:54,784")
}

// MARK: - SubRip timestamps past Int

@Test(arguments: [1e300, Double.greatestFiniteMagnitude, 9.3e15, Double(Int.max) / 1000])
func srtTimestampClampsTimesTooLongForAnInt(time: TimeInterval) {
    // Int.max rounded down to a Double is 9223372036854774784 ms.
    #expect(time.srtTimestamp == "2562047788015:12:54,784")
}

@Test func srtTimestampWritesHoursPast32Bits() {
    #expect(TimeInterval(9000000000000).srtTimestamp == "2500000000:00:00,000")
}
