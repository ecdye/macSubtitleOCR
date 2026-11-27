//
// SubtitleTimeline.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/26/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

/// One subtitle as a decoder hands it over: when it is presented, and the bitmaps shown at that time.
///
/// This mirrors FFmpeg's `AVSubtitle` without depending on it, so the rules that turn decoded frames
/// into cues can be tested in builds without FFmpeg.
struct DecodedSubtitleFrame {
    struct Rect {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        /// Tightly packed palette indices, `width * height` of them.
        var indices: Data
        /// RGBA entries, four bytes per color.
        var palette: [UInt8]
    }

    /// Presentation time of the frame, in seconds.
    var presentationTime: TimeInterval
    /// Offsets from `presentationTime`, in milliseconds, as `AVSubtitle` counts them whatever the
    /// stream's time base. `UInt32.max` means the frame stays until something replaces it, and
    /// `unknownEnd` that the stream gives no real end time.
    var startDisplayTime: UInt32 = 0
    var endDisplayTime: UInt32 = .max
    /// Every bitmap on screen at once. Empty clears the screen.
    var rects: [Rect]
}

/// Turns the frames a subtitle decoder produces into one cue per screenful.
///
/// Bitmap subtitle formats describe the screen, not cues. DVB subtitles place each line of a caption
/// in its own region, so one caption arrives as several bitmaps; a caption is taken down by a frame
/// with nothing in it rather than by an end time; and a page may be sent again unchanged to let a
/// receiver tune in mid-caption. Treating each bitmap as a cue splits captions into lines whose order
/// is whatever the decoder listed its regions in, and loses when they end.
enum SubtitleTimeline {
    static func subtitles(from frames: [DecodedSubtitleFrame]) -> [Subtitle] {
        var subtitles: [Subtitle] = []
        // The cue on screen, when it times out if nothing replaces it first, and whether its end is
        // unknown, which leaves it to the SRT writer unless an empty frame clears the screen.
        var showing: (subtitle: Subtitle, timeout: TimeInterval?, unknownEnd: Bool)?

        let ordered = frames.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)

        for frame in ordered {
            let start = frame.start
            let image = frame.rects.isEmpty ? nil : composite(frame.rects)

            if let current = showing {
                if let image, current.subtitle.hasSameImage(as: image), current.timeout.map({ start < $0 }) ?? true {
                    // The same page sent again: the caption is still up, only its timeout moves.
                    if let timeout = frame.timeout {
                        showing = (current.subtitle, timeout, false)
                    }
                    continue
                }
                // Anything else on screen, or nothing at all, takes the current caption down. With no
                // known end, only an empty frame says when it went; the SRT writer times the rest.
                if !current.unknownEnd || image == nil {
                    current.subtitle.endTimestamp = min(current.timeout ?? start, start)
                }
                showing = nil
            }

            guard let image else { continue }
            image.index = subtitles.count + 1
            image.startTimestamp = start
            subtitles.append(image)
            showing = (image, frame.timeout, frame.endDisplayTime == DecodedSubtitleFrame.unknownEnd)
        }

        // The last caption has nothing after it to end it, so only its own timeout can.
        if let current = showing {
            current.subtitle.endTimestamp = current.timeout
        }

        return subtitles
    }

    /// Draws every rect of a frame onto one bitmap, in its place on screen.
    ///
    /// OCR then reads the lines top to bottom as they are displayed, whatever order they were listed in.
    /// Each rect may bring its own palette, so the colors are merged into one.
    static func composite(_ rects: [DecodedSubtitleFrame.Rect]) -> Subtitle {
        let minX = rects.map(\.x).min()!
        let minY = rects.map(\.y).min()!
        let width = rects.map { $0.x + $0.width }.max()! - minX
        let height = rects.map { $0.y + $0.height }.max()! - minY

        var palette = MergedPalette()
        var pixels = Data(count: width * height) // Index 0 is transparent.

        for rect in rects {
            let colors = rect.palette.count / 4
            var mapped = [UInt8?](repeating: nil, count: colors)
            for row in 0 ..< rect.height {
                for column in 0 ..< rect.width {
                    let source = Int(rect.indices[rect.indices.startIndex + row * rect.width + column])
                    guard source < colors else { continue }
                    if mapped[source] == nil {
                        mapped[source] = palette.index(for: Array(rect.palette[source * 4 ..< source * 4 + 4]))
                    }
                    let index = mapped[source]!
                    // Transparent pixels never overwrite another rect's ink.
                    guard index != 0 else { continue }
                    pixels[(rect.y - minY + row) * width + rect.x - minX + column] = index
                }
            }
        }

        return Subtitle(index: 0, imageXOffset: minX, imageYOffset: minY, imageWidth: width, imageHeight: height,
                        imageData: pixels, imagePalette: palette.colors, numberOfColors: palette.colors.count / 4)
    }
}

extension DecodedSubtitleFrame {
    /// The end time FFmpeg's DVD subtitle decoder reports for a stop command with the largest
    /// delay, 0xFFFF units of 1024/90000 s: `(0xFFFF << 10) / 90` = 745642 ms. VobSub streams use
    /// that delay for a subpicture with no set end, left up until the next one replaces it. Like the
    /// internal VobSub decoder, the timeline leaves its end unknown, so the SRT writer gives it the
    /// default duration, cut short by the next cue. No other decoder reports this value: DVB page
    /// timeouts are whole seconds up to 255, and PGS frames have no end time.
    static let unknownEnd = UInt32((0xFFFF << 10) / 90)
}

private extension DecodedSubtitleFrame {
    var start: TimeInterval {
        presentationTime + TimeInterval(startDisplayTime) / 1000
    }

    /// When the frame comes down on its own, or nil when it stays until replaced or its end is unknown.
    var timeout: TimeInterval? {
        guard endDisplayTime != .max, endDisplayTime != Self.unknownEnd,
              endDisplayTime > startDisplayTime else { return nil }
        return presentationTime + TimeInterval(endDisplayTime) / 1000
    }
}

private extension Subtitle {
    func hasSameImage(as other: Subtitle) -> Bool {
        imageXOffset == other.imageXOffset && imageYOffset == other.imageYOffset
            && imageWidth == other.imageWidth && imageHeight == other.imageHeight
            && imagePalette == other.imagePalette && imageData == other.imageData
    }
}

/// A palette of at most 256 RGBA colors, built up from the colors of several rects.
private struct MergedPalette {
    private(set) var colors: [UInt8] = [0, 0, 0, 0]
    private var lookup: [[UInt8]: UInt8] = [:]

    mutating func index(for color: [UInt8]) -> UInt8 {
        // Fully transparent is transparent whatever color it carries.
        if color[3] == 0 {
            return 0
        }
        if let index = lookup[color] {
            return index
        }
        let count = colors.count / 4
        guard count < 256 else {
            return nearest(to: color)
        }
        colors += color
        lookup[color] = UInt8(count)
        return UInt8(count)
    }

    /// Rects holding more than 256 colors between them share the closest one already in the palette.
    private func nearest(to color: [UInt8]) -> UInt8 {
        var best = 1
        var bestDistance = Int.max
        for index in 1 ..< colors.count / 4 {
            let distance = (0 ..< 4).reduce(0) { sum, channel in
                let delta = Int(colors[index * 4 + channel]) - Int(color[channel])
                return sum + delta * delta
            }
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return UInt8(best)
    }
}
