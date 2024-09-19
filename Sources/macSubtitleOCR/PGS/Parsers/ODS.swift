//
// ODS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/12/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

public class ODS {
    // MARK: - Properties

    private var objectID: Int = 0
    private var version: Int = 0
    private var sequenceFlag: Int = 0
    private var objectDataLength: Int = 0
    private var objectWidth: Int = 0
    private var objectHeight: Int = 0
    private var imageData: Data = .init()

    // MARK: - Lifecycle

    init(_ data: Data) throws {
        (objectWidth, objectHeight, imageData) = try parseODS(data)
        objectID = 0
        version = 0
        sequenceFlag = 0
    }

    // MARK: - Getters

    public func getObjectID() -> Int {
        objectID
    }

    public func getVersion() -> Int {
        version
    }

    public func getSequenceFlag() -> Int {
        sequenceFlag
    }

    public func getObjectDataLength() -> Int {
        objectDataLength
    }

    public func getObjectWidth() -> Int {
        objectWidth
    }

    public func getObjectHeight() -> Int {
        objectHeight
    }

    public func getImageData() -> Data {
        imageData
    }

    // MARK: - Parser

    // Parses the Object Definition Segment (ODS) to extract the subtitle image bitmap.
    // ODS structure (simplified):
    //   0x17: Segment Type; already checked by the caller
    //   2 bytes: Object ID
    //   1 byte: Version number
    //   1 byte: Sequence flag (should be 0x80 for new object, 0x00 for continuation)
    //   3 bytes: Object data length
    //   2 bytes: Object width
    //   2 bytes: Object height
    //   Rest: Image data (run-length encoded, RLE)
    private func parseODS(_ data: Data) throws -> (width: Int, height: Int, imageData: Data) {
        // let objectID = Int(data[0]) << 8 | Int(data[1])
        let objectDataLength =
            Int(data[4]) << 16 | Int(data[5]) << 8 | Int(data[6])

        // PGS includes the width and height as part of the image data length calculations
        guard objectDataLength <= data.count - 7 else {
            throw macSubtitleOCRError.invalidFormat
        }

        let width = Int(data[7]) << 8 | Int(data[8])
        let height = Int(data[9]) << 8 | Int(data[10])
        let rleImageData = RLEData(data: data.subdata(in: 11 ..< data.endIndex), width: width, height: height)
        let imageData = try rleImageData.decode()

        return (width: width, height: height, imageData: imageData)
    }
}
