//
// PGS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct PGS {
    // MARK: - Properties

    private(set) var subtitles = [Subtitle]()
    private let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "PGS")
    private let pgsHeaderLength = 13

    /// Video dimensions from the most recent presentation composition segment.
    private var videoWidth = 0
    private var videoHeight = 0

    /// Where a presentation composition segment places one object on screen.
    private struct CompositionObject {
        let objectID: UInt16
        let x: Int
        let y: Int
    }

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
                if offset + pgsHeaderLength > buffer.count {
                    break
                }
                continue
            }

            // Find the next timestamp to use as our end timestamp
            subtitle.endTimestamp = getSegmentTimestamp(from: buffer, offset: offset)

            subtitles.append(subtitle)
        }
    }

    /// Reads one display set, up to and including its end segment, and returns the subtitle it shows.
    ///
    /// A display set may define several objects, such as a caption at the top of the screen and another
    /// at the bottom. They are drawn onto one image at the positions the presentation composition gives
    /// them, so OCR reads them top to bottom. Display sets that show nothing, such as the one clearing
    /// the screen, return nil.
    private mutating func parseNextSubtitle(_ buffer: UnsafeRawBufferPointer,
                                            _ offset: inout Int) throws -> Subtitle? {
        var compositionObjects: [CompositionObject] = []
        var objects: [(id: UInt16, ods: ODS)] = []
        var pendingObject: (id: UInt16, ods: ODS)?
        var pds: PDS?
        var startTimestamp: TimeInterval?

        while true {
            guard offset + pgsHeaderLength < buffer.count else {
                break // End of data
            }

            let segmentType = buffer[offset + 10]
            let segmentLength = getSegmentLength(from: buffer, offset: offset)
            let segmentTimestamp = getSegmentTimestamp(from: buffer, offset: offset)
            offset += pgsHeaderLength

            // End of display set
            guard segmentType != 0x80 else { break }
            guard segmentLength != 0 else { return nil }

            guard offset + segmentLength <= buffer.count else {
                print("Segment of length \(segmentLength) extends past the end of the stream, " +
                    "abandoning remaining segments!", to: &stderr)
                offset = buffer.count
                break
            }

            // Parse the segment based on the type (0x14 for PDS, 0x15 for ODS, 0x16 for PCS, 0x17 for WDS)
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
                    guard segmentLength >= 4 else {
                        throw macSubtitleOCRError.invalidODSDataLength(length: segmentLength)
                    }
                    let objectID = buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian
                    let sequenceFlag = buffer[offset + 3]
                    var isComplete = sequenceFlag & 0x40 != 0
                    if sequenceFlag & 0x80 == 0, var object = pendingObject, object.id == objectID {
                        // A later fragment of the object being read.
                        try object.ods.appendSegment(buffer, offset, segmentLength)
                        pendingObject = object
                    } else {
                        pendingObject = try (objectID, ODS(buffer, offset, segmentLength))
                        // A segment that continues nothing is taken as a whole object, as it always was.
                        isComplete = isComplete || sequenceFlag & 0x80 == 0
                    }
                    offset += segmentLength
                    if isComplete, let object = pendingObject {
                        objects.append(object)
                        pendingObject = nil
                    }
                } catch let macSubtitleOCRError.invalidODSDataLength(length) {
                    print("Invalid ODS length: \(length), abandoning remaining segments!", to: &stderr)
                    offset = buffer.count
                    continue
                }
            case 0x16:
                // Presentation Composition Segment: the video descriptor bounds the size of every object in
                // the display set, and the composition objects place them on screen.
                if segmentLength >= 4 {
                    videoWidth = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian)
                    videoHeight = Int(buffer.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self).bigEndian)
                }
                compositionObjects = parseCompositionObjects(buffer, offset, segmentLength)
                offset += segmentLength
            case 0x17:
                offset += segmentLength
            default:
                logger.warning("Unknown segment type: \(segmentType.hex()), skipping...")
                offset += segmentLength
                continue
            }

            if startTimestamp == nil, pds != nil, !objects.isEmpty {
                startTimestamp = segmentTimestamp
            }
        }

        guard let pds, !objects.isEmpty else { return nil }
        for object in objects {
            try checkObjectDimensions(of: object.ods)
        }
        return try makeSubtitle(objects, compositionObjects, pds, startTimestamp)
    }

    /// Rejects an object that is too large to belong to the video it is composited onto.
    ///
    /// Decoding fills a buffer of `objectWidth * objectHeight`, both of which are 16 bit fields, so an
    /// object claiming dimensions the video cannot hold would reserve far more memory than the stream
    /// could ever describe. Empty objects are left to the placeholder path that already handles them.
    private func checkObjectDimensions(of ods: ODS) throws {
        guard videoWidth > 0, videoHeight > 0 else { return }
        guard ods.objectWidth <= videoWidth, ods.objectHeight <= videoHeight else {
            throw macSubtitleOCRError.invalidODSDimensions(
                "Object of \(ods.objectWidth)x\(ods.objectHeight) does not fit the " +
                    "\(videoWidth)x\(videoHeight) video")
        }
    }

    /// Builds the subtitle for a display set from its complete objects.
    ///
    /// Several objects are drawn onto one image at their composition positions. A single object, or
    /// objects the composition does not place within the video, keep the image of the first object alone.
    private func makeSubtitle(_ objects: [(id: UInt16, ods: ODS)], _ compositionObjects: [CompositionObject],
                              _ pds: PDS, _ startTimestamp: TimeInterval?) throws -> Subtitle {
        if objects.count > 1 {
            var rects: [DecodedSubtitleFrame.Rect] = []
            for composition in compositionObjects {
                guard let object = objects.last(where: { $0.id == composition.objectID })?.ods,
                      object.objectWidth > 0, object.objectHeight > 0,
                      composition.x + object.objectWidth <= videoWidth,
                      composition.y + object.objectHeight <= videoHeight
                else { continue }
                let indices = try object.decodeRLEData()
                guard indices.count >= object.objectWidth * object.objectHeight else { continue }
                rects.append(DecodedSubtitleFrame.Rect(x: composition.x, y: composition.y,
                                                       width: object.objectWidth, height: object.objectHeight,
                                                       indices: indices, palette: pds.palette))
            }
            if !rects.isEmpty {
                let subtitle = SubtitleTimeline.composite(rects)
                subtitle.index = subtitles.count + 1
                subtitle.startTimestamp = startTimestamp
                return subtitle
            }
        }

        let ods = objects[0].ods
        return try Subtitle(
            index: subtitles.count + 1,
            startTimestamp: startTimestamp,
            imageWidth: ods.objectWidth,
            imageHeight: ods.objectHeight,
            imageData: ods.decodeRLEData(),
            imagePalette: pds.palette,
            numberOfColors: 256)
    }

    /// Reads where the presentation composition segment at `offset` places each object.
    ///
    /// The payload is the video width (2 bytes), height (2), frame rate (1), composition number (2),
    /// composition state (1), palette update flag (1), palette ID (1) and number of composition objects
    /// (1), followed by each composition object: object ID (2), window ID (1), cropped flag (1), x (2)
    /// and y (2), plus 8 bytes of cropping rectangle when the cropped flag has 0x40 set.
    private func parseCompositionObjects(_ buffer: UnsafeRawBufferPointer, _ offset: Int,
                                         _ segmentLength: Int) -> [CompositionObject] {
        guard segmentLength >= 11 else { return [] }
        let count = Int(buffer[offset + 10])
        var position = offset + 11
        let end = offset + segmentLength
        var compositionObjects: [CompositionObject] = []
        for _ in 0 ..< count {
            guard position + 8 <= end else { break }
            compositionObjects.append(CompositionObject(
                objectID: buffer.loadUnaligned(fromByteOffset: position, as: UInt16.self).bigEndian,
                x: Int(buffer.loadUnaligned(fromByteOffset: position + 4, as: UInt16.self).bigEndian),
                y: Int(buffer.loadUnaligned(fromByteOffset: position + 6, as: UInt16.self).bigEndian)))
            position += buffer[position + 3] & 0x40 != 0 ? 16 : 8
        }
        return compositionObjects
    }

    /// Reads the presentation timestamp from the segment header at `offset`, or nil if the header is
    /// not fully present. A missing end timestamp is filled in from the following subtitle when the SRT
    /// is written.
    private func getSegmentTimestamp(from pointer: UnsafeRawBufferPointer, offset: Int) -> TimeInterval? {
        guard offset >= 0, offset + 6 <= pointer.count else { return nil }
        return TimeInterval(pointer.loadUnaligned(fromByteOffset: offset + 2, as: UInt32.self).bigEndian) / 90000
    }

    private func getSegmentLength(from pointer: UnsafeRawBufferPointer, offset: Int) -> Int {
        Int(pointer.loadUnaligned(fromByteOffset: offset + 11, as: UInt16.self).bigEndian)
    }
}
