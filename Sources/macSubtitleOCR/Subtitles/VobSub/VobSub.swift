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

    init(_ sub: URL, _ idx: URL) throws {
        let data = try Data(contentsOf: sub)
        let idx = VobSubIDX(idx)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            extractSubtitleImages(buffer: buffer, idx: idx)
        }
    }

    init(_ buffer: UnsafeRawBufferPointer, _ idxData: String) throws {
        let idx = VobSubIDX(idxData)
        extractSubtitleImages(buffer: buffer, idx: idx)
    }

    // MARK: - Methods

    private mutating func extractSubtitleImages(buffer: UnsafeRawBufferPointer, idx: VobSubIDX) {
        if buffer.count == 0 {
            print("Found empty VobSub buffer, skipping track!")
            return
        }
        for index in idx.offsets.indices {
            let offset = idx.offsets[index]
            let timestamp = idx.timestamps[index]
            logger.debug("Parsing subtitle \(index + 1), offset: \(offset), timestamp: \(timestamp)")

            let nextOffset: UInt64 = if index + 1 < idx.offsets.count {
                idx.offsets[index + 1]
            } else {
                UInt64(buffer.count)
            }
            let subtitle = VobSubParser(
                index: index + 1,
                buffer: buffer,
                timestamp: timestamp,
                offset: offset,
                nextOffset: nextOffset,
                idxPalette: idx.palette).subtitle
            subtitles.append(subtitle)
        }
    }
}
