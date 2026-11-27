//
// PDS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/8/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

struct PDS {
    // MARK: - Properties

    private(set) var palette = [UInt8](repeating: 0, count: 1024)

    // MARK: - Lifecycle

    /// Parses the palette definition segment at `offset`.
    ///
    /// `videoHeight` comes from the presentation composition segment and picks the color matrix: BT.601
    /// up to 576 lines and BT.709 above, or when the height is not known, as FFmpeg does.
    init(_ buffer: UnsafeRawBufferPointer, _ offset: Int, _ segmentLength: Int, videoHeight: Int = 0) throws {
        let count = buffer.count - offset
        guard count >= 7, segmentLength <= count, (segmentLength - 2) % 5 == 0 else {
            throw macSubtitleOCRError.invalidPDSDataLength(length: count)
        }
        parsePDS(buffer, offset, segmentLength, bt709: videoHeight <= 0 || videoHeight > 576)
    }

    // MARK: - Methods

    /// Parses the Palette Definition Segment (PDS) to extract the RGBA palette.
    /// PDS structure:
    ///   1 byte: Segment Type (0x14); already checked by the caller
    ///   1 byte: Palette ID (unused by us)
    ///   1 byte: Palette Version (unused by us)
    ///   Followed by a series of palette entries:
    ///       Each entry is 5 bytes: (Index, Y, Cr, Cb, Alpha)
    private mutating func parsePDS(_ buffer: UnsafeRawBufferPointer, _ offset: Int, _ segmentLength: Int,
                                   bt709: Bool) {
        // Start reading after the first 2 bytes (Palette ID and Version)
        var i = offset + 2
        while i + 4 <= (offset + segmentLength) {
            let index = buffer[i]
            let y = buffer[i + 1]
            let cr = buffer[i + 2]
            let cb = buffer[i + 3]
            let alpha = buffer[i + 4]

            // Convert YCrCb to RGB
            let rgb = PDS.yCrCbToRGB(y: y, cr: cr, cb: cb, bt709: bt709)

            // Store RGBA values to palette table
            palette[Int(index) * 4 + 0] = rgb.red
            palette[Int(index) * 4 + 1] = rgb.green
            palette[Int(index) * 4 + 2] = rgb.blue
            palette[Int(index) * 4 + 3] = alpha
            i += 5
        }
    }

    /// Converts a limited range YCbCr color to RGB exactly as FFmpeg's PGS decoder does, so both decoders
    /// give Vision the same image.
    ///
    /// This is the 10 bit fixed point arithmetic of `YUV_TO_RGB1_CCIR`, `YUV_TO_RGB1_CCIR_BT709` and
    /// `YUV_TO_RGB2_CCIR` in libavutil/colorspace.h. Chroma is an offset from 128 and luma an offset from
    /// 16, both signed, and only the final sums are clamped to 0...255.
    private static func yCrCbToRGB(y: UInt8, cr: UInt8, cb: UInt8,
                                   bt709: Bool) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let cb = Int(cb) - 128
        let cr = Int(cr) - 128
        let coefficients = bt709 ? bt709Coefficients : bt601Coefficients
        let redAdd = oneHalf + coefficients.crToRed * cr
        let greenAdd = oneHalf - coefficients.cbToGreen * cb - coefficients.crToGreen * cr
        let blueAdd = oneHalf + coefficients.cbToBlue * cb
        let y = (Int(y) - 16) * fixedPoint(255.0 / 219.0)

        func clamp(_ value: Int) -> UInt8 {
            UInt8(min(max(value >> scaleBits, 0), 255))
        }
        return (red: clamp(y + redAdd), green: clamp(y + greenAdd), blue: clamp(y + blueAdd))
    }

    private struct Coefficients {
        let crToRed: Int
        let cbToGreen: Int
        let crToGreen: Int
        let cbToBlue: Int

        /// Scales full range matrix coefficients to limited range chroma, as the `_CCIR` macros do.
        init(crToRed: Double, cbToGreen: Double, crToGreen: Double, cbToBlue: Double) {
            self.crToRed = fixedPoint(crToRed * 255.0 / 224.0)
            self.cbToGreen = fixedPoint(cbToGreen * 255.0 / 224.0)
            self.crToGreen = fixedPoint(crToGreen * 255.0 / 224.0)
            self.cbToBlue = fixedPoint(cbToBlue * 255.0 / 224.0)
        }
    }

    private static let scaleBits = 10
    private static let oneHalf = 1 << (scaleBits - 1)
    private static let bt601Coefficients = Coefficients(crToRed: 1.40200, cbToGreen: 0.34414,
                                                        crToGreen: 0.71414, cbToBlue: 1.77200)
    private static let bt709Coefficients = Coefficients(crToRed: 1.5747, cbToGreen: 0.1873,
                                                        crToGreen: 0.4682, cbToBlue: 1.8556)

    /// FFmpeg's `FIX`: the value in 10 bit fixed point, rounded half up.
    private static func fixedPoint(_ value: Double) -> Int {
        Int(value * Double(1 << scaleBits) + 0.5)
    }
}
