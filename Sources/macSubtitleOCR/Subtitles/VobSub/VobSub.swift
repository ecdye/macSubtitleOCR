//
// VobSub.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/4/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct VobSub {
    /// The subtitles of one stream of a VobSub, such as one language of a VobSubRip `.idx`/`.sub`.
    struct Track {
        /// The stream's `index:` in the idx.
        let index: Int
        let language: String?
        var subtitles: [Subtitle]
    }

    // MARK: - Properties

    private var logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "VobSub")
    /// One track per stream of the idx that lists any subtitles, in the order the idx lists them.
    /// There is always at least one, which may be empty.
    private(set) var tracks = [Track]()

    /// The subtitles of the first track, for a VobSub holding a single one.
    var subtitles: [Subtitle] {
        tracks.first?.subtitles ?? []
    }

    /// The language of the first track, for a VobSub holding a single one.
    var language: String? {
        tracks.first?.language
    }

    // MARK: - Lifecycle

    /// Read every stream of a `.sub` and the `.idx` that indexes it.
    init(_ sub: URL, _ idx: URL) throws {
        let data = try Data(contentsOf: sub)
        let idx = try VobSubIDX(idx)
        var streams = idx.streams.filter { !$0.offsets.isEmpty }
        if streams.isEmpty {
            streams = [idx.streams.first ?? VobSubIDX.Stream(index: 0)]
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for stream in streams {
                try tracks.append(Track(
                    index: stream.index,
                    language: stream.language,
                    subtitles: extractSubtitleImages(buffer: buffer, stream: stream, palette: idx.palette,
                                                     substream: stream.index)))
            }
        }
    }

    /// Read the single stream of a VobSub track extracted from an MKV.
    ///
    /// Every packet of the buffer belongs to the track, so their substream IDs are not checked.
    init(_ buffer: UnsafeRawBufferPointer, _ idxData: String) throws {
        let idx = try VobSubIDX(idxData)
        let stream = idx.streams.first { !$0.offsets.isEmpty } ?? idx.streams.first ?? VobSubIDX.Stream(index: 0)
        try tracks.append(Track(
            index: stream.index,
            language: stream.language,
            subtitles: extractSubtitleImages(buffer: buffer, stream: stream, palette: idx.palette, substream: nil)))
    }

    // MARK: - Methods

    /// Decode the subtitles of `stream`, reading only packets of `substream` (any when nil).
    private func extractSubtitleImages(buffer: UnsafeRawBufferPointer, stream: VobSubIDX.Stream, palette: [UInt8]?,
                                       substream: Int?) throws -> [Subtitle] {
        if buffer.count == 0 {
            print("Found empty VobSub buffer, skipping track!")
            return []
        }
        var subtitles = [Subtitle]()
        for index in stream.offsets.indices {
            let offset = stream.offsets[index]
            let timestamp = stream.timestamps[index]
            logger.debug("Parsing subtitle \(index + 1), offset: \(offset), timestamp: \(timestamp)")

            let nextOffset: UInt64 = if index + 1 < stream.offsets.count {
                stream.offsets[index + 1]
            } else {
                UInt64(buffer.count)
            }
            do {
                let subtitle = try VobSubParser(
                    index: index + 1,
                    buffer: buffer,
                    timestamp: timestamp,
                    offset: offset,
                    nextOffset: nextOffset,
                    idxPalette: palette,
                    substream: substream,
                    delay: stream.delays[index]).subtitle
                subtitles.append(subtitle)
            } catch let macSubtitleOCRError.invalidVobSubSubpicture(reason) {
                // Keep an empty subtitle in its place so the numbering and timing of the rest stay intact.
                print("Skipping VobSub subtitle \(index + 1): \(reason)", to: &stderr)
                subtitles.append(Subtitle(index: index + 1, startTimestamp: timestamp))
            }
        }
        return subtitles
    }
}
