//
// RLEData.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024-2025 Ethan Dye. All rights reserved.
//

import Foundation

struct RLEData {
    // MARK: - Properties

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

    func decodePGS() throws -> Data {
        if data.isEmpty || width <= 0 || height <= 0 {
            return data
        }
        var pixelCount = 0
        var lineCount = 0
        var iterator = data.makeIterator()

        var image = Data()

        while var color: UInt8 = iterator.next(), lineCount < height {
            var run = 1

            if color == 0x00 {
                let flags = iterator.next()!
                run = Int(flags & 0x3F)
                if flags & 0x40 != 0 {
                    run = (run << 8) + Int(iterator.next()!)
                }
                color = (flags & 0x80) != 0 ? iterator.next()! : 0
            }

            // Ensure run is valid and doesn't exceed pixel buffer
            if run > 0, pixelCount + run <= width * height {
                // Fill the pixel data with the decoded color
                image.append(contentsOf: repeatElement(color, count: run))
                pixelCount += run
            } else if run == 0 {
                // New Line: Check if pixels align correctly
                if pixelCount % width > 0 {
                    throw macSubtitleOCRError
                        .invalidRLE("Decoded \(pixelCount % width) pixels, but line should be \(width) pixels.")
                }
                lineCount += 1
            }
        }

        // Check if we decoded enough pixels
        if pixelCount < width * height {
            throw macSubtitleOCRError.invalidRLE("Insufficient RLE data for subtitle.")
        }

        return image
    }

    mutating func decodeVobSub() throws -> Data {
        if data.isEmpty || width <= 0 || height <= 0 {
            return data
        }
        var nibbles = Data()
        var decodedLines = Data()
        decodedLines.reserveCapacity(Int(width * height))
        nibbles.reserveCapacity(data.count * 2)

        // Convert RLE data to nibbles
        for byte in data {
            nibbles.append(byte >> 4)
            nibbles.append(byte & 0x0F)
        }

        var i = 0
        var y = 0
        var x = 0
        var currentNibbles: [UInt8?] = [nibbles[i], nibbles[i + 1]]
        i += 2
        while currentNibbles[1] != nil, y < height {
            var nibble = getNibble(currentNibbles: &currentNibbles, nibbles: nibbles, i: &i)

            if nibble < 0x04 {
                if nibble == 0x00 {
                    nibble = nibble << 4 | getNibble(currentNibbles: &currentNibbles, nibbles: nibbles, i: &i)
                    if nibble < 0x04 {
                        nibble = nibble << 4 | getNibble(currentNibbles: &currentNibbles, nibbles: nibbles, i: &i)
                    }
                }
                nibble = nibble << 4 | getNibble(currentNibbles: &currentNibbles, nibbles: nibbles, i: &i)
            }
            let color = UInt8(nibble & 0x03)
            var run = Int(nibble >> 2)

            if decodedLines.count % width == 0, color != 0, run == 15 {
                i -= 5
                currentNibbles = [nibbles[i], nibbles[i + 1]]
                i += 2
                continue
            }
            x += Int(run)

            if run == 0 || x >= width {
                run += width - x
                x = 0
                y += 1
                if i % 2 != 0 {
                    _ = getNibble(currentNibbles: &currentNibbles, nibbles: nibbles, i: &i)
                }
                if y >= (height / 2), i / 2 < oddOffset!, evenOffset != 0 {
                    continue // Skip extra lines until we reach the oddOffset
                }
            }

            decodedLines.append(contentsOf: repeatElement(color, count: run))
        }
        height = decodedLines.count / width

        return interleaveLines(decodedLines)
    }

    private func interleaveLines(_ decodedLines: Data) -> Data {
        var finalImage = Data()
        finalImage.reserveCapacity(Int(width * height))

        let halfHeight = height / 2
        let heightOdd = height % 2 != 0
        for step in stride(from: 0, to: halfHeight, by: 1) {
            finalImage.append(decodedLines.subdata(in: step * width ..< step * width + width))
            let oddStepStart = (halfHeight + step + 1) * width
            let evenStepStart = (halfHeight + step) * width
            let start = heightOdd ? oddStepStart : evenStepStart
            let end = heightOdd ? oddStepStart + width : evenStepStart + width
            finalImage.append(decodedLines.subdata(in: start ..< end))
        }
        if heightOdd {
            finalImage.append(decodedLines.subdata(in: halfHeight * width ..< halfHeight * width + width))
        }
        return finalImage
    }

    private func getNibble(currentNibbles: inout [UInt8?], nibbles: Data, i: inout Int) -> UInt16 {
        let nibble = UInt16(currentNibbles.removeFirst()!)
        nibbles.count <= i ? currentNibbles.append(nil) : currentNibbles.append(nibbles[i])
        i += 1
        return nibble
    }
}
