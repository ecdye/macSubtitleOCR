//
// ODS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

class ODS {
    // MARK: - Properties

    private var objectWidth: Int = 0
    private var objectHeight: Int = 0
    private var rawImageData: Data = .init()
    private var imageData: Data = .init()

    // MARK: - Lifecycle

    init(_ data: Data) throws {
        try parseODS(data)
    }

    // MARK: - Getters / Setters

    func getObjectWidth() -> Int {
        objectWidth
    }

    func getObjectHeight() -> Int {
        objectHeight
    }

    func getImageData() -> Data {
        imageData
    }

    func appendSegment(_ data: Data) throws {
        try parseODS(data)
    }

    // MARK: - Methods

    // Parses the Object Definition Segment (ODS) to extract the subtitle image bitmap.
    private func parseODS(_ data: Data) throws {
        let sequenceFlag = data[3]
        if sequenceFlag != 0x40 {
            objectWidth = Int(data[7]) << 8 | Int(data[8])
            objectHeight = Int(data[9]) << 8 | Int(data[10])
        }

        guard data.count > 7 else {
            throw PGSError.invalidODSDataLength
        }

        switch sequenceFlag {
        case 0x40:
            rawImageData.append(data.subdata(in: 4 ..< data.count))
            imageData = try decodeRLEData()
        case 0x80:
            rawImageData.append(data.subdata(in: 11 ..< data.count))
        default:
            rawImageData.append(data.subdata(in: 11 ..< data.count))
            imageData = try decodeRLEData()
        }
    }

    private func decodeRLEData() throws -> Data {
        let rleImageData = RLEData(data: rawImageData, width: objectWidth, height: objectHeight)
        return try rleImageData.decode()
    }
}
