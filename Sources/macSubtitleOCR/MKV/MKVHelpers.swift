//
// MKVHelpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

/// Reads a big-endian unsigned integer `length` bytes wide, or returns `nil` if it is wider than 8 bytes or the
/// file ends first. An empty number is zero.
func readFixedLengthNumber(fileHandle: FileHandle, length: Int) -> UInt64? {
    guard (0 ... 8).contains(length) else { return nil }
    let data = fileHandle.readData(ofLength: length)
    guard data.count == length else { return nil }
    return unsignedNumber(fromBigEndian: data)
}

/// The big-endian unsigned integer `bytes` spell, or `nil` if there are more than 8 of them.
func unsignedNumber(fromBigEndian bytes: some Collection<UInt8>) -> UInt64? {
    guard bytes.count <= 8 else { return nil }
    return bytes.reduce(0) { $0 << 8 | UInt64($1) }
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

/// The private stream 1 substream ID of the subpictures in a generated VobSub: 0x20 plus the stream
/// index, which is always 0 in the idx written for an MKV track.
let vobSubSubstreamID: UInt8 = 0x20

/// The program_mux_rate written in VobSub pack headers, in units of 50 bytes/s: 10.08 Mbit/s, the
/// DVD rate.
let vobSubProgramMuxRate: UInt32 = 25200

/// Build the 14 byte MPEG-2 program stream pack header that starts each VobSub packet, with the
/// given 33-bit system clock reference base (higher bits are dropped) and an extension of zero.
///
/// The bits are laid out as ISO/IEC 13818-1 2.5.3.3 requires: the pack start code, then '01',
/// SCR[32..30], a marker bit, SCR[29..15], a marker bit, SCR[14..0], a marker bit, the 9-bit SCR
/// extension and a marker bit; then the 22-bit program_mux_rate and two marker bits; then five
/// reserved '1' bits and a pack_stuffing_length of zero.
func vobSubPackHeader(systemClockReference scr: UInt64) -> [UInt8] {
    let extensionValue: UInt64 = 0
    let muxRate = vobSubProgramMuxRate
    return [
        0x00, 0x00, 0x01, 0xBA,
        UInt8(0x44 | ((scr >> 27) & 0x38) | ((scr >> 28) & 0x03)),
        UInt8((scr >> 20) & 0xFF),
        UInt8(((scr >> 12) & 0xF8) | 0x04 | ((scr >> 13) & 0x03)),
        UInt8((scr >> 5) & 0xFF),
        UInt8(((scr << 3) & 0xF8) | 0x04 | ((extensionValue >> 7) & 0x03)),
        UInt8(((extensionValue << 1) & 0xFE) | 0x01),
        UInt8((muxRate >> 14) & 0xFF),
        UInt8((muxRate >> 6) & 0xFF),
        UInt8(((muxRate << 2) & 0xFC) | 0x03),
        0xF8
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

/// Converts a block's time, its unsigned cluster timestamp plus its signed relative timestamp, from ticks of
/// `timestampScale` nanoseconds to 90 kHz ticks, rounding down. A time before zero becomes zero, and one too
/// large to represent becomes `UInt64.max`.
func calculateAbsolutePTS(_ clusterTimestamp: UInt64, _ blockTimestamp: Int16,
                          timestampScale: UInt64 = defaultTimestampScale) -> UInt64 {
    let ticks: UInt64
    if blockTimestamp < 0 {
        let (difference, beforeZero) = clusterTimestamp.subtractingReportingOverflow(UInt64(blockTimestamp.magnitude))
        if beforeZero {
            return 0
        }
        ticks = difference
    } else {
        let (sum, sumOverflow) = clusterTimestamp.addingReportingOverflow(UInt64(blockTimestamp))
        if sumOverflow {
            return .max
        }
        ticks = sum
    }

    // ticks * scale ns * 90 kHz / 10^9 = ticks * scale * 9 / 100,000, exactly 90 per tick at the default scale.
    let (factor, factorOverflow) = timestampScale.multipliedReportingOverflow(by: 9)
    if factorOverflow {
        return .max
    }
    let product = ticks.multipliedFullWidth(by: factor)
    guard product.high < 100000 else { return .max }
    return UInt64(100000).dividingFullWidth(product).quotient
}
