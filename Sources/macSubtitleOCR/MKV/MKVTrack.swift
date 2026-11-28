//
// MKVTrack.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

struct MKVTrack {
    var trackNumber: Int
    var codecID: String
    var trackData: Data
    var idxData: String?
    var language: String?
    /// The time of each of the track's blocks, in the order they were read, with the display duration its
    /// BlockGroup gives, if any.
    var blockTimes: [MKVBlockTime] = []

    /// Decodes the track's subtitles, ending any that the stream gives no end with its block's duration.
    func subtitles() throws -> [Subtitle] {
        let subtitles = try trackData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            if codecID == "S_HDMV/PGS" {
                try PGS(buffer).subtitles
            } else {
                try VobSub(buffer, idxData ?? "").subtitles
            }
        }
        applyBlockDurations(to: subtitles)
        return subtitles
    }

    /// Gives each subtitle with no end time from its stream the end its block's BlockDuration sets, if the
    /// block has one. An end time from the stream is always kept.
    ///
    /// A subtitle belongs to the last block at or before its start: a VobSub start command may delay the
    /// start past the block's time. As in FFmpeg, which turns the duration into the end display time of a
    /// subtitle its decoder gave none, the end is counted from the block's time. An end that does not come
    /// after the subtitle's start is not used.
    func applyBlockDurations(to subtitles: [Subtitle]) {
        let blocks = blockTimes.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        guard blocks.contains(where: { $0.duration != nil }) else { return }

        for subtitle in subtitles where subtitle.endTimestamp == nil {
            guard let start = subtitle.startTimestamp else { continue }
            let latest = start + MKVBlockTime.tolerance
            var low = 0
            var high = blocks.count
            while low < high {
                let middle = (low + high) / 2
                if blocks[middle].start <= latest {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low > 0, let duration = blocks[low - 1].duration else { continue }
            let end = blocks[low - 1].start + duration
            if end.isFinite, end > start {
                subtitle.endTimestamp = end
            }
        }
    }
}

/// When one block of a subtitle track is presented, and for how long its BlockGroup says to show it.
struct MKVBlockTime: Equatable {
    /// How far a block's time may come after a subtitle's start, from rounding, and still be its block.
    static let tolerance: TimeInterval = 0.001

    /// Seconds, as the decoder reads the timestamp the block was written with.
    var start: TimeInterval
    /// Seconds, or `nil` if the block has no BlockDuration.
    var duration: TimeInterval?
}
