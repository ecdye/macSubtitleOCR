//
// MKVSubtitleExtractor.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/12/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

class MKVSubtitleExtractor: MKVTrackParser {
    func saveSubtitleTrackData(_ track: MKVTrack, outputDirectory: URL) throws {
        let fileExtension = (track.codecID == "S_HDMV/PGS") ? "sup" : "sub"
        let trackURL = outputDirectory.appendingPathComponent("track_\(track.trackNumber)")

        let dataURL = trackURL.appendingPathExtension(fileExtension)
        try track.trackData.write(to: dataURL)
        logger.debug("Created file at path: \(dataURL.path)")

        if fileExtension == "sub" {
            try track.idxData?.write(to: trackURL.appendingPathExtension("idx"), atomically: true, encoding: .utf8)
        }
    }
}
