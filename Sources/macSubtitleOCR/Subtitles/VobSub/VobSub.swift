//
// VobSub.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/4/24.
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
        let subFile = try FileHandle(forReadingFrom: URL(filePath: sub))
        let subData = try subFile.readToEnd()!
        subFile.closeFile()
        let idx = VobSubIDX(URL(filePath: idx))
        subData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            var pointer = pointer
            extractSubtitleImages(subData: &pointer, idx: idx)
        }
        // extractSubtitleImages(subData: subData, idx: idx)
    }

    // MARK: - Methods

    private mutating func extractSubtitleImages(subData: inout UnsafeRawBufferPointer, idx: VobSubIDX) {
        for index in idx.offsets.indices {
            logger.debug("Index \(index), offset: \(idx.offsets[index]), timestamp: \(idx.timestamps[index])")
            let offset = idx.offsets[index]
            let timestamp = idx.timestamps[index]
            let nextOffset: UInt64 = if index + 1 < idx.offsets.count {
                idx.offsets[index + 1]
            } else {
                UInt64(subData.count)
            }
            let subtitle = VobSubParser(
                index: index + 1,
                subData: &subData,
                timestamp: timestamp,
                offset: offset,
                nextOffset: nextOffset,
                idxPalette: idx.palette).subtitle
            subtitles.append(subtitle)
        }
    }
}
