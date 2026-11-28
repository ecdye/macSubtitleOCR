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
        /// Why the stream could not be read, when it could not. Its subtitles are then empty, and the
        /// other streams are read all the same.
        var failure: String?
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
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for stream in streams {
                // Packets carry the stream in a 5 bit substream ID, so, as in FFmpeg, an index past 31
                // names no stream of the .sub. Only that stream is lost: the others are read as usual.
                guard stream.index < 32 else {
                    tracks.append(Track(index: stream.index, language: stream.language, subtitles: [],
                                        failure: "VobSub stream index \(stream.index) is not between 0 and 31"))
                    continue
                }
                tracks.append(Track(
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
        tracks.append(Track(
            index: stream.index,
            language: stream.language,
            subtitles: extractSubtitleImages(buffer: buffer, stream: stream, palette: idx.palette, substream: nil)))
    }

    // MARK: - Methods

    /// Decode the subtitles of `stream`, reading only packets of `substream` (any when nil).
    ///
    /// A subtitle that cannot be decoded is replaced by an empty one with its timing, with a warning, so the
    /// numbering and timing of the rest stay intact and one bad subpicture does not lose the track.
    private func extractSubtitleImages(buffer: UnsafeRawBufferPointer, stream: VobSubIDX.Stream, palette: [UInt8]?,
                                       substream: Int?) -> [Subtitle] {
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
            } catch {
                // Keep an empty subtitle in its place so the numbering and timing of the rest stay intact.
                print("Skipping VobSub subtitle \(index + 1): \(error)", to: &stderr)
                subtitles.append(Subtitle(index: index + 1, startTimestamp: timestamp))
            }
        }
        return subtitles
    }
}
