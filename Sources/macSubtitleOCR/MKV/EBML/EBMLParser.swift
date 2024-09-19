//
// EBMLParser.swift
// macSup2Srt
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

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
//    print("length: \(length)")

    // Extract the value
//    print(String(format: "mask: 0x%08X", mask))
    if mask - 1 == 0x0F {
        mask = 0xFF
    } else if (length == 1) && !unmodified {
        mask = firstByte
    } else {
        mask = mask - 1
    }
//    print(String(format: "Byte: 0x%08X", firstByte))
//    print(String(format: "Res: 0x%08X", firstByte & mask))
    var value = UInt64(firstByte & mask)

    if length > 1 {
        let data = fileHandle.readData(ofLength: Int(length - 1))
        for byte in data {
            value <<= 8
            value |= UInt64(byte)
        }
    }
//    print(String(format: "VINT: 0x%08X", value))
    return value
}

// Helper function to read a specified number of bytes
func readBytes(from fileHandle: FileHandle, length: Int) -> Data? {
    return fileHandle.readData(ofLength: length)
}

// Helper function to read an EBML element's ID and size
func readEBMLElement(from fileHandle: FileHandle,
                     unmodified: Bool = false) -> (elementID: UInt32, elementSize: UInt64)
{
    let elementID = readVINT(from: fileHandle, unmodified: unmodified) // Read element ID
    let elementSize = readVINT(from: fileHandle, unmodified: true) // Read element size
//    print(String(format: "elementID: 0x%08X, elementSize: \(elementSize)", elementID))
    return (UInt32(elementID), elementSize)
}
