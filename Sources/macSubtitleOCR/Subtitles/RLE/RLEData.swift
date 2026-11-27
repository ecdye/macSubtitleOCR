//
// RLEData.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct RLEData {
    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "RLE")

    private var width: Int
    private var height: Int
    private var data: Data
    private var evenOffset: Int?
    private var oddOffset: Int?

    // MARK: - Lifecycle

    init(data: Data, width: Int, height: Int, evenOffset: Int? = nil, oddOffset: Int? = nil) {
        self.width = width
        self.height = height
        self.data = data
        self.evenOffset = evenOffset
        self.oddOffset = oddOffset
    }

    // MARK: - Functions

    /// Decodes a PGS object's run-length encoded bitmap into one palette index per pixel.
    ///
    /// Each line is a series of runs ended by an end-of-line code. A well formed bitmap decodes exactly as
    /// it always has. A malformed one is decoded as far as possible rather than rejected, as FFmpeg
    /// does, so the subtitle is not lost: a line that ends early is padded with index 0, a run past the end
    /// of its line is cut off there, lines past the object's height are ignored, and pixels missing at the
    /// end of the data are left as index 0. Index 0 is the background colour of the short run codes, and an
    /// index the palette does not define is fully transparent.
    func decodePGS() throws -> Data {
        if data.isEmpty || width <= 0 || height <= 0 {
            return data
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw macSubtitleOCRError.invalidRLE("PGS image dimensions overflow.")
        }

        let width = width
        let height = height
        var image = Data(count: pixelCount)
        var line = 0
        var column = 0
        var shortLines = 0
        var clippedPixels = 0

        image.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            guard let pixels = output.baseAddress else { return }
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                let end = input.count
                var position = 0
                while line < height, position < end {
                    var color = input[position]
                    position += 1
                    var run = 1

                    if color == 0x00 {
                        guard position < end else { return }
                        let flags = input[position]
                        position += 1
                        run = Int(flags & 0x3F)
                        if flags & 0x40 != 0 {
                            guard position < end else { return }
                            run = (run << 8) | Int(input[position])
                            position += 1
                        }
                        if flags & 0x80 != 0 {
                            guard position < end else { return }
                            color = input[position]
                            position += 1
                        }

                        if run == 0 {
                            // End of line; whatever the line did not fill stays index 0.
                            if column < width {
                                shortLines += 1
                            }
                            line += 1
                            column = 0
                            continue
                        }
                    }

                    let count = min(run, width - column)
                    clippedPixels += run - count
                    // The buffer starts zeroed, so runs of index 0, most of any subtitle, need no write.
                    if count > 0, color != 0 {
                        memset(pixels + line * width + column, Int32(color), count)
                    }
                    column += count
                }
            }
        }

        let complete = line == height || (line == height - 1 && column == width)
        if shortLines > 0 || clippedPixels > 0 || !complete {
            Self.logger.debug("""
            Malformed PGS RLE in a \(width)x\(height) object: padded \(shortLines) short lines, \
            dropped \(clippedPixels) pixels past a line end, \
            \(complete ? "all lines present" : "data ended at line \(line + 1)")
            """)
        }

        return image
    }

    func decodeVobSub() throws -> Data {
        guard !data.isEmpty, width > 0, height > 0 else { return data }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw macSubtitleOCRError.invalidRLE("VobSub image dimensions overflow.")
        }
        let width = width
        let height = height
        let evenOffset = evenOffset
        let oddOffset = oddOffset
        var image = Data(count: pixelCount)

        try image.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            guard let pixels = output.baseAddress else { return }
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                // DVD subpictures encode alternating rows in two independently byte-aligned
                // fields. Their offsets are authoritative: padding between fields is not
                // pixel data, and an odd-height image has one extra row in its first field.
                for field in 0 ..< min(2, height) {
                    guard let offset = field == 0 ? evenOffset : oddOffset,
                          offset >= 0, offset < bytes.count
                    else {
                        throw macSubtitleOCRError.invalidRLE("Invalid VobSub field offset.")
                    }
                    var position = offset * 2
                    func readNibble() throws -> Int {
                        guard position / 2 < bytes.count else {
                            throw macSubtitleOCRError.invalidRLE("Insufficient VobSub RLE data.")
                        }
                        let byte = bytes[position / 2]
                        let value = position % 2 == 0 ? byte >> 4 : byte & 0x0F
                        position += 1
                        return Int(value)
                    }

                    for y in stride(from: field, to: height, by: 2) {
                        var x = 0
                        while x < width {
                            var code = try readNibble()
                            if code < 0x04 {
                                code = try (code << 4) | readNibble()
                                if code < 0x10 {
                                    code = try (code << 4) | readNibble()
                                    if code < 0x40 {
                                        code = try (code << 4) | readNibble()
                                    }
                                }
                            }
                            let color = code & 0x03
                            let run = code < 4 ? width - x : code >> 2
                            guard run <= width - x else {
                                throw macSubtitleOCRError.invalidRLE("VobSub run exceeds the row width.")
                            }
                            // The image starts zeroed, so runs of index 0, most of any subpicture, need
                            // no write, and the others are filled whole rather than pixel by pixel.
                            if color != 0 {
                                memset(pixels + y * width + x, Int32(color), run)
                            }
                            x += run
                        }
                        // A row always starts on a byte boundary, even when its last run
                        // used only the high nibble of a byte.
                        position = (position + 1) & ~1
                    }
                }
            }
        }
        return image
    }
}
