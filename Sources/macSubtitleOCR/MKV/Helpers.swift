//
// Helpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

public func getUInt16BE(buffer: Data, offset: Int) -> UInt16 {
    return (UInt16(buffer[offset]) << 8) | UInt16(buffer[offset + 1])
}

// Function to read a fixed length number of bytes and convert in into a (Un)signed integer
public func readFixedLengthNumber(fileHandle: FileHandle, length: Int, signed: Bool = false) -> Int64 {
    let data = fileHandle.readData(ofLength: length)
    let pos = 0

    var result: Int64 = 0
    for i in 0 ..< length {
        result = result * 0x100 + Int64(data[pos + i])
    }

    if signed {
        let signBitMask: UInt8 = 0x80
        if data[pos] & signBitMask != 0 {
            result -= Int64(1) << (8 * length) // Apply two's complement for signed numbers
        }
    }

    return result
}

// Encode the absolute timestamp as 4 bytes in big-endian format for PGS
public func encodePTSForPGS(_ timestamp: Int64) -> [UInt8] {
    let timestamp = UInt32(timestamp) // Convert to unsigned 32-bit value
    return [
        UInt8((timestamp >> 24) & 0xFF),
        UInt8((timestamp >> 16) & 0xFF),
        UInt8((timestamp >> 8) & 0xFF),
        UInt8(timestamp & 0xFF),
    ]
}

// Calculate the absolute timestamp with 90 kHz accuracy for PGS format
public func calcAbsPTSForPGS(_ clusterTimestamp: Int64, _ blockTimestamp: Int64, _ timestampScale: Double) -> Int64 {
    // The block timestamp is relative, so we add it to the cluster timestamp
    return Int64(((Double(clusterTimestamp) + Double(blockTimestamp)) / timestampScale) * 90000000)
}
