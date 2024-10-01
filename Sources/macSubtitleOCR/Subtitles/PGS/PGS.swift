//
// PGS.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
import ImageIO

class PGS {
    // MARK: - Properties

    private var subtitles = [Subtitle]()

    // MARK: - Lifecycle

    init(_ url: URL) throws {
        try parseSupFile(fromFileAt: url)
    }

    // MARK: - Getters

    func getSubtitles() -> [Subtitle] {
        subtitles
    }

    // MARK: - Functions

    // Converts the RGBA data to a CGImage
    func createImage(index: Int) -> CGImage? {
        // Convert the image data to RGBA format using the palette
        let rgbaData = imageDataToRGBA(&subtitles[index])

        let bitmapInfo = CGBitmapInfo.byteOrder32Big
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let provider = CGDataProvider(data: rgbaData as CFData) else {
            return nil
        }

        let image = CGImage(width: subtitles[index].imageWidth,
                            height: subtitles[index].imageHeight,
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: subtitles[index].imageWidth * 4, // 4 bytes per pixel (RGBA)
                            space: colorSpace,
                            bitmapInfo: bitmapInfo,
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: false,
                            intent: .defaultIntent)

        return cropImageToVisibleArea(image!, buffer: 5)
    }

    // MARK: - Methods

    // Parses a `.sup` file and populates the subtitles array
    private func parseSupFile(fromFileAt url: URL) throws {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }

        let fileLength = try fileHandle.seekToEnd()
        fileHandle.seek(toFileOffset: 0) // Ensure the file handle is at the start
        var headerData = fileHandle.readData(ofLength: 13)

        while fileHandle.offsetInFile < fileLength {
            guard let subtitle = try parseNextSubtitle(fileHandle: fileHandle, headerData: &headerData)
            else {
                headerData = fileHandle.readData(ofLength: 13)
                continue
            }

            // Find the next timestamp to use as our end timestamp
            while subtitle.endTimestamp <= subtitle.timestamp {
                headerData = fileHandle.readData(ofLength: 13)
                subtitle.endTimestamp = parseTimestamp(headerData)
            }

            subtitles.append(subtitle)
        }
    }

    private func parseTimestamp(_ data: Data) -> TimeInterval {
        let pts = (Int(data[2]) << 24 | Int(data[3]) << 16 | Int(data[4]) << 8 | Int(data[5]))
        return TimeInterval(pts) / 90000.0 // 90 kHz clock
    }

    // Converts the image data to RGBA format using the palette
    private func imageDataToRGBA(_ subtitle: inout Subtitle) -> Data {
        let bytesPerPixel = 4
        let numColors = 256 // There are only 256 possible palette entries in a PGS Subtitle
        var rgbaData = Data(capacity: subtitle.imageWidth * subtitle.imageHeight * bytesPerPixel)

        for y in 0 ..< subtitle.imageHeight {
            for x in 0 ..< subtitle.imageWidth {
                let index = Int(y) * subtitle.imageWidth + Int(x)
                let colorIndex = Int(subtitle.imageData[index])

                guard colorIndex < numColors else {
                    continue
                }

                let paletteOffset = colorIndex * 4
                rgbaData.append(contentsOf: [
                    subtitle.imagePalette[paletteOffset],
                    subtitle.imagePalette[paletteOffset + 1],
                    subtitle.imagePalette[paletteOffset + 2],
                    subtitle.imagePalette[paletteOffset + 3],
                ])
            }
        }

        return rgbaData
    }

    private func parseNextSubtitle(fileHandle: FileHandle, headerData: inout Data) throws -> Subtitle? {
        let subtitle = Subtitle()
        var p1 = false
        var p2 = false
        var multipleODS = false
        var ods: ODS?
        while true {
            guard headerData.count == 13 else {
                print("Failed to read PGS header correctly.")
                return nil
            }

            let segmentType = headerData[10]

            // Read segment length (2 bytes, big-endian)
            let segmentLength = Int(headerData[11]) << 8 | Int(headerData[12])

            if segmentType == 0x80 { // END (End of Display Set Segment)
                return nil
            } else if segmentLength == 0 {
                print("Invalid segment found! Skipping...")
                return nil
            }

            // Read the rest of the segment
            let segmentData = fileHandle.readData(ofLength: segmentLength)

            guard segmentData.count == segmentLength else {
                print("Failed to read the full segment data, got: \(segmentData.count) expected: \(segmentLength)")
                return nil
            }

            // Parse the segment based on the type (0x14 for PCS, 0x15 for WDS, 0x16 for PDS, 0x17 for ODS)
            switch segmentType {
            case 0x14: // PDS (Palette Definition Segment)
                subtitle.imagePalette = try PDS(segmentData).getPalette()
                p1 = true
            case 0x15: // ODS (Object Definition Segment)
                if segmentData[3] == 0x80 {
                    ods = try ODS(segmentData)
                    multipleODS = true
                    break
                } else if multipleODS {
                    try ods?.appendSegment(segmentData)
                    if segmentData[3] != 0x40 { break } else { multipleODS = false }
                } else {
                    ods = try ODS(segmentData)
                }
                p2 = true
                subtitle.imageWidth = ods!.getObjectWidth()
                subtitle.imageHeight = ods!.getObjectHeight()
                subtitle.imageData = ods!.getImageData()
            case 0x16, 0x17: // PCS (Presentation Composition Segment), WDS (Window Definition Segment)
                break // PCS and WDS parsing not required for basic rendering
            default:
                return nil
            }
            headerData = fileHandle.readData(ofLength: 13)
            if p1, p2 {
                p1 = false
                p2 = false
                subtitle.timestamp = parseTimestamp(headerData)
                return subtitle
            }
        }
    }

    private func cropImageToVisibleArea(_ image: CGImage, buffer: Int) -> CGImage? {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data
        else {
            return nil
        }

        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel / 8
        let bytesPerRow = image.bytesPerRow
        let alphaInfo = image.alphaInfo

        guard alphaInfo == .premultipliedLast || alphaInfo == .last else {
            // Ensure that the image contains an alpha channel.
            return nil
        }

        let pixelData = CFDataGetBytePtr(data)

        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0

        // Iterate over each pixel to find the non-transparent bounding box
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                let alpha = pixelData![pixelIndex + 3] // Assuming RGBA format

                if alpha > 0 { // Non-transparent pixel
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        // Check if the image is fully transparent, return nil if so
        if minX == width || maxX == 0 || minY == height || maxY == 0 {
            return nil // Fully transparent image
        }

        // Add buffer to the bounding box, ensuring it's clamped within the image bounds
        minX = max(0, minX - buffer)
        maxX = min(width - 1, maxX + buffer)
        minY = max(0, minY - buffer)
        maxY = min(height - 1, maxY + buffer)

        let croppedWidth = maxX - minX + 1
        let croppedHeight = maxY - minY + 1

        let croppedRect = CGRect(x: minX, y: minY, width: croppedWidth, height: croppedHeight)

        // Create a cropped image from the original image
        return image.cropping(to: croppedRect)
    }
}
