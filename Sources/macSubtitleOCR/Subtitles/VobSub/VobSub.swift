//
// VobSub.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/30/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct VobSub {
    // MARK: - Properties

    private var logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "VobSub")
    private(set) var subtitles = [Subtitle]()

    // MARK: - Lifecycle

    init(_ sub: String, _ idx: String) throws {
        logger.debug("Extracting VobSub subtitles from \(sub) and \(idx)")
        let subFile = try FileHandle(forReadingFrom: URL(filePath: sub))
        defer { subFile.closeFile() }
        let idx = VobSubIDX(URL(filePath: idx))
        try extractSubtitleImages(subFile: subFile, idx: idx)
    }

    // MARK: - Methods

    private mutating func extractSubtitleImages(subFile: FileHandle, idx: VobSubIDX) throws {
        for index in idx.offsets.indices {
            logger
                .debug("Reading image at index \(index), offset: \(idx.offsets[index]), timestamp: \(idx.timestamps[index])")
            let offset = idx.offsets[index]
            let timestamp = idx.timestamps[index]
            let nextOffset: UInt64 = if index + 1 < idx.offsets.count {
                idx.offsets[index + 1]
            } else {
                subFile.seekToEndOfFile()
            }
            let subtitle = try VobSubParser(
                subFile: subFile,
                timestamp: timestamp,
                offset: offset,
                nextOffset: nextOffset,
                idxPalette: idx.palette).subtitle
            logger.debug("Found image at offset \(offset) with timestamp \(timestamp)")
            logger.debug("Image size: \(subtitle.imageWidth!) x \(subtitle.imageHeight!)")
            subtitles.append(subtitle)
        }
    }
}
