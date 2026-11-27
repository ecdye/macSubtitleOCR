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
    /// interval is written as zero.
    var srtTimestamp: String {
        let total = isFinite ? max(0, Int((self * 1000).rounded())) : 0
        let hours = total / 3600000
        let minutes = total / 60000 % 60
        let seconds = total / 1000 % 60
        let milliseconds = total % 1000

        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}
