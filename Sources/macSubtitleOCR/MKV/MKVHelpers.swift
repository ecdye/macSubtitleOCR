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

/// Encode the absolute timestamp as 4 bytes in big-endian format for PGS
func encodePTSForPGS(_ timestamp: UInt64) -> [UInt8] {
    withUnsafeBytes(of: UInt32(timestamp).bigEndian) { Array($0) }
}

func encodePTSForVobSub(from timestamp: UInt64) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: 5) // 5-byte buffer

    buffer[0] = (buffer[0] & 0xF1) | UInt8((timestamp >> 29) & 0x0E)
    buffer[1] = UInt8((timestamp >> 22) & 0xFF)
    buffer[2] = UInt8(((timestamp >> 14) & 0xFE) | 1)
    buffer[3] = UInt8((timestamp >> 7) & 0xFF)
    buffer[4] = UInt8((timestamp << 1) & 0xFF)
    return buffer
}

/// Write a 90 kHz timestamp the way a VobSub `.idx` spells one, `HH:MM:SS:mmm`,
/// rounded to the nearest millisecond.
func formatTime(_ time: UInt64) -> String {
    let total = (time + 45) / 90
    let hours = total / 3600000
    let minutes = total / 60000 % 60
    let seconds = total / 1000 % 60
    let milliseconds = total % 1000

    return String(format: "%02llu:%02llu:%02llu:%03llu", hours, minutes, seconds, milliseconds)
}

/// Calculate the absolute timestamp with 90 kHz accuracy
func calculateAbsolutePTS(_ clusterTimestamp: Int64, _ blockTimestamp: Int64) -> UInt64 {
    // The block timestamp is relative, so we add it to the cluster timestamp
    UInt64(clusterTimestamp + blockTimestamp) * 90
}
