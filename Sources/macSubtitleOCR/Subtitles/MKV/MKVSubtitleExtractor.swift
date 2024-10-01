//
// MKVSubtitleExtractor.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/22/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

class MKVSubtitleExtractor: MKVTrackParser {
    private var stderr = StandardErrorOutputStream()

    func getSubtitleTrackData(trackNumber: Int) throws -> String? {
        let tmpFilePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(trackNumber)")
            .appendingPathExtension("sup")
            .path

        if FileManager.default.createFile(atPath: tmpFilePath, contents: tracks[trackNumber].trackData, attributes: nil) {
            logger.debug("Created file at path: \(tmpFilePath).")
            return tmpFilePath
        } else {
            print("Failed to create file at path: \(tmpFilePath).", to: &stderr)
            throw PGSError.fileReadError
        }
    }
}
