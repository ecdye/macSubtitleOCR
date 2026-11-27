//
// EBMLParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct EBMLParser {
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "EBML")
    private let fileHandle: FileHandle

    // MARK: - Lifecycle

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    // MARK: - Functions

    func readVINT(elementSize: Bool = false) -> UInt64 {
        readVINTAndLength(elementSize: elementSize)?.value ?? 0
    }

    /// Reads an element header, or returns `nil` if the file ends before a whole header is read.
    ///
    /// The size is `nil` when the element declares an unknown size (every value bit set), which live and
    /// streamed muxers write for a Segment or Cluster they cannot go back and fill in.
    func readEBMLElement() -> (elementID: UInt32, elementSize: UInt64?)? {
        guard let elementID = readVINTAndLength(),
              let elementSize = readVINTAndLength(elementSize: true)
        else { return nil }
        let unknownSize = (UInt64(1) << (7 * elementSize.length)) - 1
        return (UInt32(truncatingIfNeeded: elementID.value), elementSize.value == unknownSize ? nil : elementSize.value)
    }

    /// Reads a VINT and the number of bytes it takes, or returns `nil` on a short read.
    private func readVINTAndLength(elementSize: Bool = false) -> (value: UInt64, length: Int)? {
        guard let firstByte = fileHandle.readData(ofLength: 1).first else { return nil }

        var length = 1
        var mask: UInt8 = 0x80

        // Find how many bytes are needed for the VINT (variable integer)
        while mask != 0, firstByte & mask == 0 {
            length += 1
            mask >>= 1
        }

        var value = UInt64(firstByte)
        if elementSize {
            value &= ~UInt64(mask)
        }

        let rest = fileHandle.readData(ofLength: length - 1)
        guard rest.count == length - 1 else { return nil }
        for byte in rest {
            value = (value << 8) | UInt64(byte)
        }
        logger.debug("VINT: \(value.hex())")

        return (value, length)
    }
}
