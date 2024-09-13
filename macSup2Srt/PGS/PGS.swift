//
//  SUP.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/1/2024.
//  Copyright © 2024 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PGSSubtitle {
    public var timestamp: TimeInterval = 0
    public var imageWidth: Int = 0
    public var imageHeight: Int = 0
    public var imageData: Data = .init()
    public var imagePalette: [UInt8] = []
    public var endTimestamp: TimeInterval = 0
}

public class PGS {
    public init() {}

    // MARK: - Decoding .sup File

    /// Parses a `.sup` file and returns an array of `PGSSubtitle` objects
    public func parseSupFile(fromFileAt url: URL) throws -> [PGSSubtitle] {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }

        var subtitles = [PGSSubtitle]()
        let fileLength = try fileHandle.seekToEnd()
        fileHandle.seek(toFileOffset: 0) // Ensure the file handle is at the start
        var headerData = fileHandle.readData(ofLength: 13)
        
        while fileHandle.offsetInFile < fileLength {
            guard var subtitle = try parseNextSubtitle(fileHandle: fileHandle, headerData: &headerData)
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

        return subtitles
    }

    private func parseNextSubtitle(fileHandle: FileHandle, headerData: inout Data) throws -> PGSSubtitle? {
        var subtitle = PGSSubtitle()
        var p1 = false
        var p2 = false
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
                let ODS = try ODS(segmentData)
                subtitle.imageWidth = ODS.getObjectWidth()
                subtitle.imageHeight = ODS.getObjectHeight()
                subtitle.imageData = ODS.getImageData()
                p2 = true
            case 0x16, 0x17: // PCS (Presentation Composition Segment), WDS (Window Definition Segment)
                headerData = fileHandle.readData(ofLength: 13)
                continue // PCS and WDS parsing not required for basic rendering
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

    private func parseTimestamp(_ data: Data) -> TimeInterval {
        let pts =
            (Int(data[2]) << 24 | Int(data[3]) << 16 | Int(data[4]) << 8
                | Int(data[5]))
        return TimeInterval(pts) / 90000.0 // 90 kHz clock
    }

    // MARK: - Segment Parsers

    /// Parses the Presentation Composition Segment (PCS) to extract the height and width of the video.
    /// PCS structure (simplified):
    ///   0x14: Segment Type; already checked by the caller
    ///   2 bytes: Width
    ///   2 bytes: Height
    private func parsePCS(_ data: Data) -> (width: Int, height: Int) {
        let width = Int(data[0]) << 8 | Int(data[1])
        let height = Int(data[2]) << 8 | Int(data[3])

        return (width: width, height: height)
    }

    /// Converts the RGBA data to a CGImage
    public func createImage(from imageData: inout Data, palette: [UInt8], width: Int, height: Int) -> CGImage? {
        // Convert the image data to RGBA format using the palette
        let rgbaData = imageDataToRGBA(&imageData, palette: palette, width: width, height: height)

        let bitmapInfo = CGBitmapInfo.byteOrder32Big
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let provider = CGDataProvider(data: rgbaData as CFData) else {
            return nil
        }

        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Converts the image data to RGBA format using the palette
    private func imageDataToRGBA(_ imageData: inout Data, palette: [UInt8], width: Int, height: Int) -> Data {
        let bytesPerPixel = 4
        let numColors = 256 // There are only 256 possible palette entries in a PGS Subtitle
        var rgbaData = Data(capacity: width * height * bytesPerPixel)

        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = Int(y) * width + Int(x)
                let colorIndex = Int(imageData[index])

                guard colorIndex < numColors else {
                    continue
                }

                let paletteOffset = colorIndex * 4
                rgbaData.append(contentsOf: [palette[paletteOffset], palette[paletteOffset + 1],
                                             palette[paletteOffset + 2], palette[paletteOffset + 3]])
            }
        }

        return rgbaData
    }
    
    public func saveImageAsPNG(image: CGImage, outputPath: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(outputPath as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else {
            throw PGSError.fileReadError
        }
        CGImageDestinationAddImage(destination, image, nil)

        if !CGImageDestinationFinalize(destination) {
            throw PGSError.fileReadError
        }
    }
}
