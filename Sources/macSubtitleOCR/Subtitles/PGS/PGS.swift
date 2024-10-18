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
    private var data: Data
    private let pgsHeaderLength = 13

    // MARK: - Lifecycle

    init(_ url: URL) throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }
        data = try fileHandle.readToEnd() ?? Data()
        guard data.count > pgsHeaderLength else {
            fatalError("Failed to read file data from: \(url.path)")
        }
        fileHandle.closeFile()
        try data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            try parseData(pointer)
        }

        // try parseData()
    }

    init(_ pointer: UnsafeRawBufferPointer) throws {
        self.data = Data()
        try parseData(pointer)
    }

    // MARK: - Methods

    private mutating func parseData(_ pointer: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset + pgsHeaderLength < pointer.count {
            guard let subtitle = try parseNextSubtitle(pointer, &offset)
            else {
                if offset + pgsHeaderLength > pointer.count { break }
                continue
            }

            // Find the next timestamp to use as our end timestamp
            subtitle.endTimestamp = parseTimestamp(pointer.loadUnaligned(fromByteOffset: offset + 2, as: UInt32.self).bigEndian)

            subtitles.append(subtitle)
        }
    }

    private func parseTimestamp(_ timestamp: UInt32) -> TimeInterval {
        return TimeInterval(timestamp) / 90000 // 90 kHz clock
    }

    private mutating func parseNextSubtitle(_ pointer: UnsafeRawBufferPointer, _ offset: inout Int) throws -> Subtitle? {
        var multipleODS = false
        var ods: ODS?
        var pds: PDS?

        while true {
            guard offset + pgsHeaderLength < pointer.count else {
                return nil // End of data
            }

            let segmentType = pointer[offset + 10]
            let segmentLength = Int(pointer.loadUnaligned(fromByteOffset: offset + 11, as: UInt16.self).bigEndian)
            let startTimestamp = parseTimestamp(pointer.loadUnaligned(fromByteOffset: offset + 2, as: UInt32.self).bigEndian)
            offset += pgsHeaderLength

            // Check for the end of the subtitle stream (0x80 segment type and 0 length)
            guard segmentType != 0x80, segmentLength != 0 else { return nil }

            // Parse the segment based on the type (0x14 for PCS, 0x15 for WDS, 0x16 for PDS, 0x17 for ODS)
            switch segmentType {
            case 0x14: // PDS (Palette Definition Segment)
                do {
                    pds = try PDS(pointer, offset, segmentLength)
                    offset += segmentLength
                } catch let macSubtitleOCRError.invalidPDSDataLength(length) {
                    fatalError("Invalid Palette Data Segment length: \(length)")
                }
            case 0x15: // ODS (Object Definition Segment)
                do {
                    if pointer[offset + 3] == 0x80 {
                        ods = try ODS(pointer, offset, segmentLength)
                        offset += segmentLength
                        multipleODS = true
                        break
                    } else if multipleODS {
                        try ods?.appendSegment(pointer, offset, segmentLength)
                        if pointer[offset + 3] != 0x40 { break }
                        offset += segmentLength
                    } else {
                        ods = try ODS(pointer, offset, segmentLength)
                        offset += segmentLength
                    }
                } catch let macSubtitleOCRError.invalidODSDataLength(length) {
                    fatalError("Invalid Object Data Segment length: \(length)")
                }
            case 0x16, 0x17: // PCS (Presentation Composition Segment), WDS (Window Definition Segment)
                offset += segmentLength
                break // PCS and WDS parsing not required for basic rendering
            default:
                logger.warning("Unknown segment type: \(segmentType, format: .hex), skipping...")
                offset += segmentLength
                return nil
            }
            guard let pds, let ods else { continue }
            offset += pgsHeaderLength // Skip the end segment
            return Subtitle(
                index: subtitles.count + 1,
                startTimestamp: startTimestamp,
                imageWidth: ods.objectWidth,
                imageHeight: ods.objectHeight,
                imageData: ods.imageData,
                imagePalette: pds.palette,
                numberOfColors: 256)
        }
    }
}
