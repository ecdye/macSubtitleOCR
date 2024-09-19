//
// ODS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/12/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

class ODS {
    // MARK: - Properties

    private var objectDataLength: Int = 0
    private var objectWidth: Int = 0
    private var objectHeight: Int = 0
    private var imageData: Data = .init()

    // MARK: - Lifecycle

    init(_ data: Data) throws {
        try parseODS(data)
    }

    // MARK: - Getters

    func getObjectWidth() -> Int {
        objectWidth
    }

    func getObjectHeight() -> Int {
        objectHeight
    }

    func getImageData() -> Data {
        imageData
    }

    // MARK: - Methods

    // Parses the Object Definition Segment (ODS) to extract the subtitle image bitmap.
    // ODS structure (simplified):
    //   0x17: Segment Type; already checked by the caller
    //   2 bytes: Object ID (unused by us)
    //   1 byte: Version number (unused by us)
    //   1 byte: Sequence flag (should be 0x80 for new object, 0x00 for continuation) (unused by us)
    //   3 bytes: Object data length
    //   2 bytes: Object width
    //   2 bytes: Object height
    //   Rest: Image data (run-length encoded, RLE)
    private func parseODS(_ data: Data) throws {
        // let objectID = Int(data[0]) << 8 | Int(data[1])
        objectDataLength = Int(data[4]) << 16 | Int(data[5]) << 8 | Int(data[6])

        // PGS includes the width and height as part of the image data length calculations
        guard objectDataLength <= data.count - 7 else {
            throw macSubtitleOCRError.invalidFormat
        }

        objectWidth = Int(data[7]) << 8 | Int(data[8])
        objectHeight = Int(data[9]) << 8 | Int(data[10])

        let rleImageData = RLEData(data: data.subdata(in: 11 ..< data.endIndex), width: objectWidth, height: objectHeight)
        imageData = try rleImageData.decode()
    }
}
