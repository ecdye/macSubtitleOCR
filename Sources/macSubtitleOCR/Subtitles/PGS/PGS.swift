//
// PGS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct PGS {
    // MARK: - Properties

    private(set) var subtitles = [Subtitle]()
    private let logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "PGS")
    private let pgsHeaderLength = 13

    // MARK: - Lifecycle

    init(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            try parseData(buffer)
        }
    }

    init(_ buffer: UnsafeRawBufferPointer) throws {
        try parseData(buffer)
    }

    // MARK: - Methods

    private mutating func parseData(_ buffer: UnsafeRawBufferPointer) throws {
        var offset = 0
        guard buffer.count > pgsHeaderLength else {
            print("Found empty PGS buffer, skipping track!")
            return
        }
        while offset + pgsHeaderLength < buffer.count {
            logger.debug("Parsing subtitle at offset: \(offset)")
            guard let subtitle = try parseNextSubtitle(buffer, &offset)
            else {
                if offset + pgsHeaderLength > buffer.count { break }
                continue
            }

            // Find the next timestamp to use as our end timestamp
            subtitle.endTimestamp = getSegmentTimestamp(from: buffer, offset: offset)

            subtitles.append(subtitle)
        }
    }

    private func parseNextSubtitle(_ buffer: UnsafeRawBufferPointer, _ offset: inout Int) throws -> Subtitle? {
        var hasMultipleODS = false
        var ods: ODS?
        var pds: PDS?

        while true {
            guard offset + pgsHeaderLength < buffer.count else {
                return nil // End of data
            }

            let segmentType = buffer[offset + 10]
            let segmentLength = getSegmentLength(from: buffer, offset: offset)
            let startTimestamp = getSegmentTimestamp(from: buffer, offset: offset)
            offset += pgsHeaderLength

            // End of stream check
            guard segmentType != 0x80, segmentLength != 0 else { return nil }

            // Parse the segment based on the type (0x14 for PCS, 0x15 for WDS, 0x16 for PDS, 0x17 for ODS)
            switch segmentType {
            case 0x14:
                do {
                    pds = try PDS(buffer, offset, segmentLength)
                    offset += segmentLength
                } catch let macSubtitleOCRError.invalidPDSDataLength(length) {
                    print("Invalid PDS length: \(length), abandoning remaining segments!", to: &stderr)
                    offset = buffer.count
                    return nil
                }
            case 0x15:
                do {
                    if buffer[offset + 3] == 0x80 {
                        ods = try ODS(buffer, offset, segmentLength)
                        offset += segmentLength
                        hasMultipleODS = true
                        continue
                    } else if hasMultipleODS {
                        try ods!.appendSegment(buffer, offset, segmentLength)
                        offset += segmentLength
                        if buffer[offset - 10] != 0x40 { break }
                    } else {
                        ods = try ODS(buffer, offset, segmentLength)
                        offset += segmentLength
                    }
                } catch let macSubtitleOCRError.invalidODSDataLength(length) {
                    print("Invalid ODS length: \(length), abandoning remaining segments!", to: &stderr)
                    offset = buffer.count
                    continue
                }
            case 0x16, 0x17:
                offset += segmentLength
            default:
                logger.warning("Unknown segment type: \(segmentType.hex()), skipping...")
                offset += segmentLength
                continue
            }

            guard let pds, let ods else { continue }
            offset += pgsHeaderLength // Skip the end segment
            return try Subtitle(
                index: subtitles.count + 1,
                startTimestamp: startTimestamp,
                imageWidth: ods.objectWidth,
                imageHeight: ods.objectHeight,
                imageData: ods.decodeRLEData(),
                imagePalette: pds.palette,
                numberOfColors: 256)
        }
    }

    private func getSegmentTimestamp(from pointer: UnsafeRawBufferPointer, offset: Int) -> TimeInterval {
        TimeInterval(pointer.loadUnaligned(fromByteOffset: offset + 2, as: UInt32.self).bigEndian) / 90000
    }

    private func getSegmentLength(from pointer: UnsafeRawBufferPointer, offset: Int) -> Int {
        Int(pointer.loadUnaligned(fromByteOffset: offset + 11, as: UInt16.self).bigEndian)
    }
}
