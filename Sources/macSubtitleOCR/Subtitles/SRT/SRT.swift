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
    private func encodeSRT() -> String {
        var srtContent = ""

        for (position, subtitle) in subtitles.enumerated() {
            let start = subtitle.startTimestamp!
            let nextStart = position + 1 < subtitles.count ? subtitles[position + 1].startTimestamp : nil
            let end = endTimestamp(of: subtitle, nextStart: nextStart)

            srtContent += "\(subtitle.index)\n"
            srtContent += "\(start.srtTimestamp) --> \(end.srtTimestamp)\n"
            srtContent += "\(subtitle.text!)\n\n"
        }

        return srtContent
    }

    /// The time the subtitle should leave the screen.
    ///
    /// An end time from the stream is kept. Without one, the subtitle stays up for `defaultDuration`.
    /// Bitmap subtitle streams replace what is on screen, so either way it ends no later than the next
    /// subtitle starts, and never before it starts itself.
    private func endTimestamp(of subtitle: Subtitle, nextStart: TimeInterval?) -> TimeInterval {
        let start = subtitle.startTimestamp!
        var end = subtitle.endTimestamp ?? start + SRT.defaultDuration
        if let nextStart, nextStart > start {
            end = min(end, nextStart)
        }
        return max(end, start)
    }
}
