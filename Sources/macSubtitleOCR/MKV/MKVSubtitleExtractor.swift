//
// MKVSubtitleExtractor.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/20/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

class MKVSubtitleExtractor: MKVTrackParser {
    func getSubtitleTrackData(trackNumber: Int, outPath: String) throws -> String? {
        let tmpSup = URL(fileURLWithPath: outPath).deletingPathExtension().appendingPathExtension("sup").lastPathComponent
        let manager = FileManager.default
        let tmpFilePath = (manager.temporaryDirectory.path + "/\(trackNumber)" + tmpSup)

        if manager.createFile(atPath: tmpFilePath, contents: tracks[trackNumber].trackData, attributes: nil) {
            logger.debug("Created file at path: \(tmpFilePath).")
            return tmpFilePath
        } else {
            logger.debug("Failed to create file at path: \(tmpFilePath).")
            throw PGSError.fileReadError
        }
    }
}
