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

public struct SupSubtitle {
    public var timestamp: TimeInterval = 0
    public var imageWidth: Int = 0
    public var imageHeight: Int = 0
    public var imageData: Data = .init()
    public var imagePalette: [UInt8] = []
    public var endTimestamp: TimeInterval = 0
}

public enum SupDecoderError: Error {
    case invalidFormat
    case fileReadError
    case unsupportedFormat
}

public class SupDecoder {
    public init() {}

    // MARK: - Decoding .sup File

    /// Parses a `.sup` file and returns an array of `SupSubtitle` objects
    public func parseSup(fromFileAt url: URL) throws -> [SupSubtitle] {
        //        debugPrint("Parsing \(url.lastPathComponent)")
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }

        var subtitles = [SupSubtitle]()
        let fileLength = try fileHandle.seekToEnd()
        fileHandle.seek(toFileOffset: 0) // Ensure the file handle is at the start

        while fileHandle.offsetInFile < fileLength {
            guard var subtitle = try parseNextSubtitle(fileHandle: fileHandle)
            else { continue }

            var endTimestamp: TimeInterval = 0
            let oldOffset = fileHandle.offsetInFile
            while endTimestamp <= subtitle.timestamp {
                let nH = fileHandle.readData(ofLength: 13)
                //                debugPrint(String(format: "Segment Type: 0x%02X", nH[10]))
                endTimestamp = parseTimestamp(nH)
            }

            subtitle.endTimestamp = endTimestamp
            fileHandle.seek(toFileOffset: oldOffset)

            subtitles.append(subtitle)
        }
        //        debugPrint("Finished parsing \(url.lastPathComponent)")

        return subtitles
    }

    private func parseNextSubtitle(fileHandle: FileHandle) throws -> SupSubtitle? {
        var SupSubtitle = SupSubtitle()
        var p1 = false
        var p2 = false
        while true {
            // Read the PGS header (13 bytes)
            let headerData = fileHandle.readData(ofLength: 13)
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
                print("Failed to read the full segment data.")
                return nil
            }

            // Parse the segment based on the type (0x14 for PCS, 0x15 for WDS, 0x16 for PDS, 0x17 for ODS)
            switch segmentType {
            case 0x14: // PDS (Palette Definition Segment)
                SupSubtitle.imagePalette = try Palette(segmentData).getPalette()
                p1 = true
            case 0x15: // ODS (Object Definition Segment)
                let ODS = try parseODS(segmentData)
                SupSubtitle.imageWidth = ODS.width
                SupSubtitle.imageHeight = ODS.height
                SupSubtitle.imageData = ODS.imageData
                p2 = true
            case 0x16: // PCS (Presentation Composition Segment)
                continue // PCS parsing not required for basic rendering
            case 0x17: // WDS (Window Definition Segment)
                continue // WDS parsing not required for basic rendering
            default:
                return nil
            }
            if p1, p2 {
                p1 = false
                p2 = false
                SupSubtitle.timestamp = parseTimestamp(headerData)
                return SupSubtitle
            }
        }
    }

    private func parseTimestamp(_ data: Data) -> TimeInterval {
        let pts =
            (Int(data[2]) << 24 | Int(data[3]) << 16 | Int(data[4]) << 8
                | Int(data[5]))
        // & 0x1FFF_FFFF  Seems to reset timestamp around 6000?
        return TimeInterval(pts) / 90000.0 // 90 kHz clock
    }

    // MARK: - Segment Parsers

    private func parsePCS(_ data: Data) -> (width: Int, height: Int) {
        // PCS structure (simplified):
        //   0x14: Segment Type
        //   2 bytes: Width
        //   2 bytes: Height

        let width = Int(data[0]) << 8 | Int(data[1])
        let height = Int(data[2]) << 8 | Int(data[3])

        return (width: width, height: height)
    }

    /// Parses the Object Definition Segment (ODS) to extract the image bitmap.
    /// ODS structure (simplified):
    ///   0x17: Segment Type; already checked by the caller
    ///   2 bytes: Object ID
    ///   1 byte: Version number
    ///   1 byte: Sequence flag (should be 0x80 for new object, 0x00 for continuation)
    ///   3 bytes: Object data length
    ///   2 bytes: Object width
    ///   2 bytes: Object height
    ///   Rest: Image data (run-length encoded, RLE)
    private func parseODS(_ data: Data) throws -> (width: Int, height: Int, imageData: Data) {
        // let objectID = Int(data[0]) << 8 | Int(data[1])
        let objectDataLength =
            Int(data[4]) << 16 | Int(data[5]) << 8 | Int(data[6])

        // PGS includes the width and height as part of the image data length calculations
        guard objectDataLength <= data.count - 7 else {
            throw SupDecoderError.invalidFormat
        }

        let width = Int(data[7]) << 8 | Int(data[8])
        let height = Int(data[9]) << 8 | Int(data[10])
        var imageData = data.subdata(in: 11 ..< data.endIndex)

        imageData = try decodeRLE(data: imageData, width: width, height: height)
//        try decodeRLE(data: &imageData, width: width, height: height)

        return (width: width, height: height, imageData: imageData)
    }

    /// Converts the RGBA data to a CGImage
    public func createImage(from imageData: Data, palette: [UInt8], width: Int, height: Int) -> CGImage? {
        // Convert the image data to RGBA format using the palette
        let rgbaData = imageDataToRGBA(imageData, palette: palette, width: width, height: height)

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
    private func imageDataToRGBA(_ imageData: Data, palette: [UInt8], width: Int, height: Int) -> Data {
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
//                print("colors pi: \(index), i: \(colorIndex) r: \(palette[paletteOffset]), g: \(palette[paletteOffset + 1]), b: \(palette[paletteOffset + 2]), a: \(palette[paletteOffset + 3])")

                rgbaData.append(contentsOf: [palette[paletteOffset], palette[paletteOffset + 1],
                                             palette[paletteOffset + 2], palette[paletteOffset + 3]])
            }
        }

        return rgbaData
    }
}
