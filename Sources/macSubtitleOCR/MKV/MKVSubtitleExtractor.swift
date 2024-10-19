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
    func saveSubtitleTrackData(trackNumber: Int, outputDirectory: URL) {
        let trackPath = outputDirectory.appendingPathComponent("\(trackNumber)").appendingPathExtension("sup").path

        if FileManager.default.createFile(atPath: trackPath, contents: tracks[trackNumber].trackData, attributes: nil) {
            logger.debug("Created file at path: \(trackPath)")
        } else {
            logger.error("Failed to create file at path: \(trackPath)!")
        }
    }
}
