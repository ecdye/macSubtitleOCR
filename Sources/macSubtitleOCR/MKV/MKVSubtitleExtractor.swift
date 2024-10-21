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
        let codecType = tracks[trackNumber].codecID
        let fileExtension = (codecType == "S_HDMV/PGS") ? "sup" : "sub"
        let trackPath = outputDirectory.appendingPathComponent("track_\(trackNumber)").appendingPathExtension(fileExtension)
            .path

        if FileManager.default.createFile(atPath: trackPath, contents: tracks[trackNumber].trackData, attributes: nil) {
            logger.debug("Created file at path: \(trackPath)")
        } else {
            logger.error("Failed to create file at path: \(trackPath)!")
        }

        if fileExtension == "sub" {
            let idxPath = outputDirectory.appendingPathComponent("track_\(trackNumber)").appendingPathExtension("idx")
            do {
                try tracks[trackNumber].idxData?.write(to: idxPath, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Failed to write idx file at path: \(idxPath)")
            }
        }
    }
}
