//
// TimeIntervalExtensions.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/24/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

extension TimeInterval {
    /// This timestamp written the way SubRip spells one, `HH:MM:SS,mmm`.
    ///
    /// Rounded to the nearest millisecond. SubRip has no negative times, so a negative
    /// interval is written as zero. One too long to count in an `Int` of milliseconds is
    /// written as the longest that fits.
    var srtTimestamp: String {
        let rounded = (self * 1000).rounded()
        let total = isFinite ? Int(min(max(0, rounded), Self.largestMilliseconds)) : 0
        let hours = total / 3600000
        let minutes = total / 60000 % 60
        let seconds = total / 1000 % 60
        let milliseconds = total % 1000

        return String(format: "%02ld:%02ld:%02ld,%03ld", hours, minutes, seconds, milliseconds)
    }

    /// The largest whole number of milliseconds that converts to an `Int` without trapping.
    /// `Double(Int.max)` rounds up to 2^63, one past `Int.max`.
    private static let largestMilliseconds = Double(Int.max).nextDown
}
