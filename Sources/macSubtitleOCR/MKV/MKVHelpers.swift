//
// MKVHelpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

// Function to read a fixed length number of bytes and convert in into a (Un)signed integer
func readFixedLengthNumber(fileHandle: FileHandle, length: Int, signed: Bool = false) -> Int64 {
    let data = fileHandle.readData(ofLength: length)
    var result: Int64 = 0

    for byte in data {
        result = result << 8 | Int64(byte)
    }

    if signed, data.first! & 0x80 != 0 {
        result -= Int64(1) << (8 * length) // Apply two's complement for signed integers
    }

    return result
}

// Encode the absolute timestamp as 4 bytes in big-endian format for PGS
func encodePTSForPGS(_ timestamp: Int64) -> [UInt8] {
    withUnsafeBytes(of: UInt32(timestamp).bigEndian) { Array($0) }
}

func encodePTSForVobSub(_ timestamp: Int64) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: 5) // 5-byte buffer
    var presentationTimestamp = timestamp * 90 * 1000 // Reversing the division done in the original code

    // Now, apply the inverse bit-shifting to break down the value
    buffer[4] = UInt8((presentationTimestamp & 0x7F) << 1) // Get the least significant 7 bits, shift left 1
    presentationTimestamp >>= 7

    buffer[3] = UInt8(presentationTimestamp & 0x7F) // Next 7 bits
    presentationTimestamp >>= 7

    buffer[2] =
        UInt8((presentationTimestamp & 0x7F) |
            0x01) // Get next 7 bits, set the least significant bit (0xFE in original becomes 0x01 here)
    presentationTimestamp >>= 7

    buffer[1] = UInt8(presentationTimestamp & 0x7F) // Next 7 bits
    presentationTimestamp >>= 7

    buffer[0] = UInt8((presentationTimestamp & 0x07) << 1) // Finally, get the 3 most significant bits, shift left 1

    return buffer
}

// Calculate the absolute timestamp with 90 kHz accuracy
func calcAbsPTS(_ clusterTimestamp: Int64, _ blockTimestamp: Int64) -> Int64 {
    // The block timestamp is relative, so we add it to the cluster timestamp
    Int64((Double(clusterTimestamp) + Double(blockTimestamp)) * 90)
}
