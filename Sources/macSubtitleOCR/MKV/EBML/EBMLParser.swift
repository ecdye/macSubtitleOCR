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
    /// The longest element ID Matroska allows, in bytes.
    private let maxIDLength = 4
    private let fileHandle: FileHandle

    // MARK: - Lifecycle

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    // MARK: - Functions

    /// Reads a VINT, or returns `nil` if the file ends first or the VINT is malformed.
    func readVINT(elementSize: Bool = false) -> UInt64? {
        readVINTAndLength(elementSize: elementSize)?.value
    }

    /// Reads an element header, or returns `nil` if the file ends before a whole header is read or the header
    /// is malformed: a VINT with a first byte of zero, or an ID longer than four bytes.
    ///
    /// The size is `nil` when the element declares an unknown size (every value bit set), which live and
    /// streamed muxers write for a Segment or Cluster they cannot go back and fill in.
    func readEBMLElement() -> (elementID: UInt32, elementSize: UInt64?)? {
        guard let elementID = readVINTAndLength() else { return nil }
        // Matroska IDs are at most four bytes (EBMLMaxIDLength); a longer one would not fit in a UInt32.
        guard elementID.length <= maxIDLength else {
            logger.debug("Element ID \(elementID.value.hex()) is \(elementID.length) bytes long, stopping")
            return nil
        }
        guard let elementSize = readVINTAndLength(elementSize: true) else { return nil }
        let unknownSize = (UInt64(1) << (7 * elementSize.length)) - 1
        return (UInt32(truncatingIfNeeded: elementID.value), elementSize.value == unknownSize ? nil : elementSize.value)
    }

    /// Reads a VINT and the number of bytes it takes, or returns `nil` on a short read or a first byte of zero.
    ///
    /// A VINT is at most eight bytes, so a first byte of zero, which has no length marker, is not one. Only
    /// that byte is read; callers treat `nil` as the end of the element they are reading.
    private func readVINTAndLength(elementSize: Bool = false) -> (value: UInt64, length: Int)? {
        guard let firstByte = fileHandle.readData(ofLength: 1).first else { return nil }
        guard firstByte != 0 else {
            logger.debug("VINT has a first byte of zero, stopping")
            return nil
        }

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
