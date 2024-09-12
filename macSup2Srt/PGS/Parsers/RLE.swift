//
//  RLE.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/1/2024.
//  Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

func decodeRLE(data: Data, width: Int, height: Int) throws -> Data {
    let rleBitmapEnd = data.endIndex
    var pixelCount = 0
    var lineCount = 0
    var buf = 0

    var image = Data()

    while buf < rleBitmapEnd && lineCount < height {
        var color: UInt8 = data[buf]
        buf += 1
        var run = 1

        if color == 0x00 {
            let flags = data[buf]
            buf += 1
            run = Int(flags & 0x3F)
            if flags & 0x40 != 0 {
                run = (run << 8) + Int(data[buf])
                buf += 1
            }
            color = (flags & 0x80) != 0 ? data[buf] : 0
            if (flags & 0x80) != 0 {
                buf += 1
            }
        }

        // Ensure run is valid and doesn't exceed pixel buffer
        if run > 0 && pixelCount + run <= width * height {
            // Fill the pixel data with the decoded color
            image.append(contentsOf: repeatElement(color, count: run))
            pixelCount += run
        } else if run == 0 {
            // New Line: Check if pixels align correctly
            if pixelCount % width > 0 {
                print("Error: Decoded \(pixelCount % width) pixels, but line should be \(width) pixels.")
                throw RLEDecodeError.invalidData
            }
            lineCount += 1
        }
    }

    // Check if we decoded enough pixels
    if pixelCount < width * height {
        print("Error: Insufficient RLE data for subtitle.")
        throw RLEDecodeError.insufficientData
    }

    return image
}

enum RLEDecodeError: Error {
    case invalidData
    case insufficientData
}
