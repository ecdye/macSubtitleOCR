//
// PDSTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #85: chroma offsets below 128 were clamped to zero, so every palette color with a negative
// Cr or Cb came out wrong, yellow as a pale near white.

/// The BT.709 limited range conversion the palette is expected to follow, clamped and rounded.
private func reference(y: UInt8, cr: UInt8, cb: UInt8) -> [Int] {
    let y = Double(y) - 16
    let cr = Double(cr) - 128
    let cb = Double(cb) - 128
    let rgb = [
        1.164 * y + 1.793 * cr,
        1.164 * y - 0.213 * cb - 0.533 * cr,
        1.164 * y + 2.112 * cb
    ]
    return rgb.map { Int(min(max($0, 0), 255).rounded()) }
}

/// Parses a palette definition segment holding `entries` as (index, Y, Cr, Cb, alpha).
private func palette(_ entries: [(UInt8, UInt8, UInt8, UInt8, UInt8)]) throws -> [UInt8] {
    var bytes: [UInt8] = [0x00, 0x00] // Palette ID and version
    for entry in entries {
        bytes += [entry.0, entry.1, entry.2, entry.3, entry.4]
    }
    return try bytes.withUnsafeBytes { try PDS($0, 0, bytes.count).palette }
}

private func rgba(_ palette: [UInt8], at index: Int) -> [Int] {
    palette[index * 4 ..< index * 4 + 4].map(Int.init)
}

private func expectClose(_ actual: [Int], _ expected: [Int], _ name: String) {
    for channel in 0 ..< 3 {
        #expect(abs(actual[channel] - expected[channel]) <= 1,
                "\(name): channel \(channel) is \(actual[channel]), expected \(expected[channel])")
    }
}

@Test func paletteConvertsNegativeChroma() throws {
    let entries: [(UInt8, UInt8, UInt8, UInt8, UInt8)] = [
        (0, 126, 128, 128, 0xFF), // Neutral gray
        (1, 210, 146, 16, 0xFF), // Yellow: Cb well below 128
        (2, 41, 110, 240, 0x80), // Blue: Cr below 128
        (3, 145, 34, 54, 0xFF) // Green: both below 128
    ]
    let palette = try palette(entries)

    for entry in entries {
        let actual = rgba(palette, at: Int(entry.0))
        expectClose(actual, reference(y: entry.1, cr: entry.2, cb: entry.3), "index \(entry.0)")
        #expect(actual[3] == Int(entry.4))
    }

    // Neutral chroma gives an exact gray.
    let gray = rgba(palette, at: 0)
    #expect(gray[0] == gray[1] && gray[1] == gray[2])

    // Yellow is high in red and green and low in blue, not the near white the clamped chroma gave.
    let yellow = rgba(palette, at: 1)
    #expect(yellow[0] > 220 && yellow[1] > 200 && yellow[2] < 40)

    // Blue is high in blue and low in red.
    let blue = rgba(palette, at: 2)
    #expect(blue[2] > 200 && blue[0] < 40)

    // Green is high in green only.
    let green = rgba(palette, at: 3)
    #expect(green[1] > 200 && green[0] < 40 && green[2] < 40)
}

/// Video black and white stay at the ends of the range, rounded rather than truncated.
@Test func paletteMapsLimitedRangeEndpoints() throws {
    let palette = try palette([(0, 16, 128, 128, 0xFF), (1, 235, 128, 128, 0xFF)])
    #expect(rgba(palette, at: 0) == [0, 0, 0, 255])
    #expect(rgba(palette, at: 1) == [255, 255, 255, 255])
}
