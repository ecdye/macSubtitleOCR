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

class PGS {
    // MARK: - Properties

    private var subtitles = [Subtitle]()

    // MARK: - Lifecycle

    init(_ url: URL) throws {
        try parseSupFile(fromFileAt: url)
    }

    // MARK: - Getters

    func getSubtitles() -> [Subtitle] {
        subtitles
    }

    // MARK: - Methods

    // Parses a `.sup` file and populates the subtitles array
    private func parseSupFile(fromFileAt url: URL) throws {
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
            while subtitle.endTimestamp <= subtitle.timestamp {
                headerData = fileHandle.readData(ofLength: 13)
                subtitle.endTimestamp = parseTimestamp(headerData)
            }

            subtitles.append(subtitle)
        }
    }

    private func parseTimestamp(_ data: Data) -> TimeInterval {
        let pts = (Int(data[2]) << 24 | Int(data[3]) << 16 | Int(data[4]) << 8 | Int(data[5]))
        return TimeInterval(pts) / 90000.0 // 90 kHz clock
    }

    private func parseNextSubtitle(fileHandle: FileHandle, headerData: inout Data) throws -> Subtitle? {
        let subtitle = Subtitle()
        var p1 = false
        var p2 = false
        var multipleODS = false
        var ods: ODS?
        while true {
            guard headerData.count == 13 else {
                print("Failed to read PGS header correctly.")
                return nil
            }

            let segmentType = headerData[10]

            // Read segment length (2 bytes, big-endian)
            let segmentLength = Int(headerData[11]) << 8 | Int(headerData[12])

            if segmentType == 0x80 { // END (End of Display Set Segment)
                return nil
            } else if segmentLength == 0 {
                print("Invalid segment found! Skipping...")
                return nil
            }

            // Read the rest of the segment
            let segmentData = fileHandle.readData(ofLength: segmentLength)

            guard segmentData.count == segmentLength else {
                print("Failed to read the full segment data, got: \(segmentData.count) expected: \(segmentLength)")
                return nil
            }

            // Parse the segment based on the type (0x14 for PCS, 0x15 for WDS, 0x16 for PDS, 0x17 for ODS)
            switch segmentType {
            case 0x14: // PDS (Palette Definition Segment)
                subtitle.imagePalette = try PDS(segmentData).getPalette()
                p1 = true
            case 0x15: // ODS (Object Definition Segment)
                if segmentData[3] == 0x80 {
                    ods = try ODS(segmentData)
                    multipleODS = true
                    break
                } else if multipleODS {
                    try ods?.appendSegment(segmentData)
                    if segmentData[3] != 0x40 { break } else { multipleODS = false }
                } else {
                    ods = try ODS(segmentData)
                }
                p2 = true
                subtitle.imageWidth = ods!.getObjectWidth()
                subtitle.imageHeight = ods!.getObjectHeight()
                subtitle.imageData = ods!.getImageData()
            case 0x16, 0x17: // PCS (Presentation Composition Segment), WDS (Window Definition Segment)
                break // PCS and WDS parsing not required for basic rendering
            default:
                return nil
            }
            headerData = fileHandle.readData(ofLength: 13)
            if p1, p2 {
                p1 = false
                p2 = false
                subtitle.timestamp = parseTimestamp(headerData)
                return subtitle
            }
        }
    }
}
