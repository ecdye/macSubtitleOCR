//
// EBMLParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

private let logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "ebml")

// Helper function to read variable-length integers (VINT) from MKV (up to 8 bytes)
func readVINT(from fileHandle: FileHandle, unmodified: Bool = false) -> UInt64 {
    guard let firstByte = fileHandle.readData(ofLength: 1).first else {
        return 0
    }
    var length: UInt8 = 1
    var mask: UInt8 = 0x80

    // Find how many bytes are needed for the VINT (variable integer)
    while (firstByte & UInt8(mask)) == 0 {
        length += 1
        mask >>= 1
    }

    // Extract the value
    if mask - 1 == 0x0F {
        mask = 0xFF // Hacky workaround that I still don't understand why is needed
    } else if length == 1, !unmodified {
        mask = firstByte
    } else {
        mask = mask - 1
    }

    var value = UInt64(firstByte & mask)

    if length > 1 {
        let data = fileHandle.readData(ofLength: Int(length - 1))
        for byte in data {
            value <<= 8
            value |= UInt64(byte)
        }
    }
    logger.debug("VINT: 0x\(String(format: "%08X", value))")

    return value
}

// Helper function to read a specified number of bytes
func readBytes(from fileHandle: FileHandle, length: Int) -> Data? {
    fileHandle.readData(ofLength: length)
}

// Helper function to read an EBML element's ID and size
func readEBMLElement(from fileHandle: FileHandle, unmodified: Bool = false) -> (elementID: UInt32, elementSize: UInt64) {
    let elementID = readVINT(from: fileHandle, unmodified: unmodified)
    let elementSize = readVINT(from: fileHandle, unmodified: true)
    return (UInt32(elementID), elementSize)
}
