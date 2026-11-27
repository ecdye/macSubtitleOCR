//
// MKVHelpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

/// Function to read a fixed length number of bytes and convert in into a (Un)signed integer
func readFixedLengthNumber(fileHandle: FileHandle, length: Int) -> Int64 {
    let data = fileHandle.readData(ofLength: length)
    var result: Int64 = 0
    for byte in data {
        result = result << 8 | Int64(byte)
    }
    return result
}

/// Encode the absolute timestamp as 4 bytes in big-endian format for PGS.
///
/// A PGS PTS is 32 bits wide, so like any PGS stream it wraps to zero after about 13.25 hours.
func encodePTSForPGS(_ timestamp: UInt64) -> [UInt8] {
    withUnsafeBytes(of: UInt32(truncatingIfNeeded: timestamp).bigEndian) { Array($0) }
}

/// Encode the absolute timestamp as the 5 PTS bytes of an MPEG-2 PES header with only a PTS
/// (PTS_DTS_flags '10'). The PTS is 33 bits wide; higher bits are dropped.
///
/// The bits are laid out as ISO/IEC 13818-1 requires: the '0010' prefix, PTS[32..30] and a marker
/// bit, then PTS[29..15] and a marker bit, then PTS[14..0] and a marker bit.
func encodePTSForVobSub(from timestamp: UInt64) -> [UInt8] {
    [
        UInt8(0x21 | ((timestamp >> 29) & 0x0E)),
        UInt8((timestamp >> 22) & 0xFF),
        UInt8(((timestamp >> 14) & 0xFE) | 1),
        UInt8((timestamp >> 7) & 0xFF),
        UInt8(((timestamp << 1) & 0xFE) | 1)
    ]
}

/// Write a 90 kHz timestamp the way a VobSub `.idx` spells one, `HH:MM:SS:mmm`,
/// rounded to the nearest millisecond.
func formatTime(_ time: UInt64) -> String {
    // Written so that it cannot overflow, unlike (time + 45) / 90.
    let total = time / 90 + (time % 90 >= 45 ? 1 : 0)
    let hours = total / 3600000
    let minutes = total / 60000 % 60
    let seconds = total / 1000 % 60
    let milliseconds = total % 1000

    return String(format: "%02llu:%02llu:%02llu:%03llu", hours, minutes, seconds, milliseconds)
}

/// The Matroska TimestampScale used when Segment Info gives none: one tick per millisecond.
let defaultTimestampScale: UInt64 = 1000000

/// Converts a block's time, its cluster timestamp plus its signed relative timestamp, from ticks of
/// `timestampScale` nanoseconds to 90 kHz ticks, rounding down. A time before zero becomes zero, and
/// one too large to represent becomes `UInt64.max`.
func calculateAbsolutePTS(_ clusterTimestamp: Int64, _ blockTimestamp: Int64,
                          timestampScale: UInt64 = defaultTimestampScale) -> UInt64 {
    let (sum, sumOverflow) = clusterTimestamp.addingReportingOverflow(blockTimestamp)
    if sumOverflow {
        return blockTimestamp < 0 ? 0 : .max
    }
    guard sum > 0 else { return 0 }

    // ticks * scale ns * 90 kHz / 10^9 = ticks * scale * 9 / 100,000, exactly 90 per tick at the default scale.
    let (factor, factorOverflow) = timestampScale.multipliedReportingOverflow(by: 9)
    if factorOverflow {
        return .max
    }
    let product = UInt64(sum).multipliedFullWidth(by: factor)
    guard product.high < 100000 else { return .max }
    return UInt64(100000).dividingFullWidth(product).quotient
}
