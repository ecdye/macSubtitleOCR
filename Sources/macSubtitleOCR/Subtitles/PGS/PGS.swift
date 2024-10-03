//
// PGS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
import ImageIO
import os

struct PGS {
    // MARK: - Properties

    private(set) var subtitles = [Subtitle]()
    private let logger: Logger = .init(subsystem: "github.ecdye.macSubtitleOCR", category: "PGS")

    // MARK: - Lifecycle

    init(_ url: URL) throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }

        let fileLength = try fileHandle.seekToEnd()
        fileHandle.seek(toFileOffset: 0) // Ensure the file handle is at the start
        var headerData = fileHandle.readData(ofLength: 13)

        while fileHandle.offsetInFile < fileLength {
            guard let subtitle = try parseNextSubtitle(fileHandle: fileHandle, headerData: &headerData)
            else {
                headerData = fileHandle.readData(ofLength: 13)
                continue
            }

            // Find the next timestamp to use as our end timestamp
            while subtitle.endTimestamp == nil {
                headerData = fileHandle.readData(ofLength: 13)
                subtitle.endTimestamp = parseTimestamp(headerData)
            }

            subtitles.append(subtitle)
        }
    }

    // MARK: - Methods

    private func parseTimestamp(_ data: Data) -> TimeInterval {
        let pts = data.value(ofType: UInt32.self, at: 2)!
        return TimeInterval(pts) / 90000.0 // 90 kHz clock
    }

    private func parseNextSubtitle(fileHandle: FileHandle, headerData: inout Data) throws -> Subtitle? {
        var multipleODS = false
        var ods: ODS?
        var pds: PDS?
        while true {
            guard headerData.count == 13 else {
                fatalError("Failed to read PGS header correctly, got header length: \(headerData.count) expected: 13")
            }

            let segmentType = headerData[10]
            let segmentLength = Int(headerData.value(ofType: UInt16.self, at: 11)!)

            // Check for the end of the subtitle stream (0x80 segment type and 0 length)
            guard segmentType != 0x80, segmentLength != 0 else { return nil }

            // Read the rest of the segment
            let segmentData = fileHandle.readData(ofLength: segmentLength)
            guard segmentData.count == segmentLength else {
                fatalError(
                    "Error: Failed to read the full segment data, got: \(segmentData.count) expected: \(segmentLength)")
            }

            // Parse the segment based on the type (0x14 for PCS, 0x15 for WDS, 0x16 for PDS, 0x17 for ODS)
            switch segmentType {
            case 0x14: // PDS (Palette Definition Segment)
                do {
                    pds = try PDS(segmentData)
                } catch let PGSError.invalidPDSDataLength(length) {
                    fatalError("Error: Invalid Palette Data Segment length: \(length)")
                }
            case 0x15: // ODS (Object Definition Segment)
                if segmentData[3] == 0x80 {
                    ods = try ODS(segmentData)
                    multipleODS = true
                    break
                } else if multipleODS {
                    try ods?.appendSegment(segmentData)
                    if segmentData[3] != 0x40 { break }
                } else {
                    ods = try ODS(segmentData)
                }
            case 0x16, 0x17: // PCS (Presentation Composition Segment), WDS (Window Definition Segment)
                break // PCS and WDS parsing not required for basic rendering
            default:
                logger.warning("Unknown segment type: \(segmentType, format: .hex), skipping...")
                return nil
            }
            headerData = fileHandle.readData(ofLength: 13)
            guard let pds, let ods else { continue }
            let startTimestamp = parseTimestamp(headerData)
            return Subtitle(
                startTimestamp: startTimestamp,
                imageWidth: ods.objectWidth,
                imageHeight: ods.objectHeight,
                imageData: ods.imageData,
                imagePalette: pds.palette)
        }
    }
}
