//
// SRT.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct SRT {
    // MARK: - Properties

    private var subtitles: [Subtitle]

    /// How long a subtitle with no end time in the stream stays on screen, in seconds.
    // TODO: Make this smarter, use length of the text to make it more dynamic
    private static let defaultDuration: TimeInterval = 5

    // MARK: - Lifecycle

    init(subtitles: [Subtitle]) {
        self.subtitles = subtitles
    }

    // MARK: - Functions

    /// Writes the SRT object to the file at the given URL
    func write(toFileAt url: URL) throws {
        try encodeSRT().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Methods

    /// Encodes the SRT object into SRT format and returns it as a string
    ///
    /// A cue with no text (OCR recognized none) or no start time cannot be written as a valid SRT
    /// cue, so it is left out and the cues written are numbered from 1. A cue left out for having no
    /// text was still on screen, so the cue before it still ends when it starts.
    private func encodeSRT() -> String {
        var srtContent = ""
        var number = 0

        for (position, subtitle) in subtitles.enumerated() {
            guard let start = subtitle.startTimestamp,
                  let text = subtitle.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            let nextStart = subtitles[(position + 1)...].lazy.compactMap(\.startTimestamp).first
            let end = endTimestamp(start: start, end: subtitle.endTimestamp, nextStart: nextStart)

            number += 1
            srtContent += "\(number)\n"
            srtContent += "\(start.srtTimestamp) --> \(end.srtTimestamp)\n"
            srtContent += "\(text)\n\n"
        }

        return srtContent
    }

    /// The time the subtitle should leave the screen.
    ///
    /// An end time from the stream is kept. Without one, the subtitle stays up for `defaultDuration`.
    /// Bitmap subtitle streams replace what is on screen, so either way it ends no later than the next
    /// subtitle starts, and never before it starts itself.
    private func endTimestamp(start: TimeInterval, end: TimeInterval?, nextStart: TimeInterval?) -> TimeInterval {
        var end = end ?? start + SRT.defaultDuration
        if let nextStart, nextStart > start {
            end = min(end, nextStart)
        }
        return max(end, start)
    }
}
