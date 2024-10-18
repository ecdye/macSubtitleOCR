//
// ODS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

struct ODS {
    // MARK: - Properties

    private(set) var objectWidth: Int = 0
    private(set) var objectHeight: Int = 0
    private var rawImageData: Data = .init()
    private(set) var imageData: Data = .init()

    // MARK: - Lifecycle

    init(_ data: UnsafeRawBufferPointer, _ offset: Int, _ segmentLength: Int) throws {
        try parseODS(data, offset, segmentLength)
    }

    mutating func appendSegment(_ data: UnsafeRawBufferPointer, _ offset: Int, _ segmentLength: Int) throws {
        try parseODS(data, offset, segmentLength)
    }

    // MARK: - Methods

    // Parses the Object Definition Segment (ODS) to extract the subtitle image bitmap.
    // ODS structure (simplified):
    //   0x17: Segment Type; already checked by the caller
    //   2 bytes: Object ID (unused by us)
    //   1 byte: Version number (unused by us)
    //   1 byte: Sequence flag (0x80: First in sequence, 0x40: Last in sequence,
    //                          0xC0: First and last in sequence (0x40 | 0x80))
    //   3 bytes: Object data length (unused by us)
    //   2 bytes: Object width
    //   2 bytes: Object height
    //   Rest: Image data (run-length encoded, RLE)
    private mutating func parseODS(_ data: UnsafeRawBufferPointer, _ offset: Int, _ segmentLength: Int) throws {
        let sequenceFlag = data[offset + 3]
        if sequenceFlag != 0x40 {
            objectWidth = Int(data.loadUnaligned(fromByteOffset: offset + 7, as: UInt16.self).bigEndian)
            objectHeight = Int(data.loadUnaligned(fromByteOffset: offset + 9, as: UInt16.self).bigEndian)
        }

        // PGS includes the width and height as part of the image data length calculations
        guard data.count - offset > 7 else {
            throw macSubtitleOCRError.invalidODSDataLength(length: data.count - offset)
        }

        switch sequenceFlag {
        case 0x40:
            rawImageData.append(contentsOf: data[(offset + 4)..<(offset + segmentLength)])
            imageData = decodeRLEData()
        case 0x80:
            rawImageData.append(contentsOf: data[(offset + 11)..<(offset + segmentLength)])
        default:
            rawImageData.append(contentsOf: data[(offset + 11)..<(offset + segmentLength)])
            imageData = decodeRLEData()
        }
    }

    private func decodeRLEData() -> Data {
        let rleImageData = RLEData(data: rawImageData, width: objectWidth, height: objectHeight)
        return rleImageData.decodePGS()
    }
}
