import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

public struct SupSubtitle {
    public let timestamp: TimeInterval
    public var imageSize: (width: Int, height: Int)
    public var imageData: Data
    public var imagePalette: [UInt32]
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
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }
        
        var subtitles = [SupSubtitle]()
        let fileLength = try fileHandle.seekToEnd()
        fileHandle.seek(toFileOffset: 0)  // Ensure the file handle is at the start
        
        while fileHandle.offsetInFile < fileLength {

            guard var subtitle = try parseNextSubtitle(fileHandle: fileHandle)
            else { continue }

            var endTimestamp: TimeInterval = 0
            while endTimestamp <= subtitle.timestamp {
                let nH = fileHandle.readData(ofLength: 13)
                endTimestamp = parseTimestamp(nH)
            }
            subtitle.endTimestamp = endTimestamp
            fileHandle.seek(toFileOffset: fileHandle.offsetInFile - 13)
            
            subtitles.append(subtitle)
        }
        
        return subtitles
    }
    
    private func parseNextSubtitle(fileHandle: FileHandle) throws
    -> SupSubtitle?
    {
        var ODS: (width: Int, height: Int, imageData: Data)
        ODS = (width: 0, height: 0, imageData: Data.init(count: 0))
        var PDS: [UInt32]
        PDS = [UInt32](repeating: 0, count: 256)
        var p1 = false
        var p2 = false
        while true {
            /// Read the PGS header (13 bytes)
            let headerData = fileHandle.readData(ofLength: 13)
            //print("Header Data Read: \(headerData.count) bytes, offset \(fileHandle.offsetInFile)")
            
            guard headerData.count == 13 else {
                print("Failed to read PGS header correctly.")
                return nil
            }
            
            // Extract timestamp (27-bit)
            let timestamp = parseTimestamp(headerData)
            //print("Timestamp: \(timestamp)")
            
            // Read segment length (2 bytes, big-endian)
            let segmentLength = Int(headerData[11]) << 8 | Int(headerData[12])
            //print("Segment Length: \(segmentLength) bytes")
            if segmentLength == 0 {
                return nil
            }
            
            // Read the rest of the segment
            let segmentData = fileHandle.readData(ofLength: segmentLength)
            //print("Segment Data Read: \(segmentData.count) bytes")
            
            guard segmentData.count == segmentLength else {
                print("Failed to read the full segment data.")
                return nil
            }
            
            // Parse the segment based on the type (0x14 for PCS, 0x15 for WDS, 0x16 for PDS, 0x17 for ODS, 0x80 for END)
            let segmentType = headerData[10]
            
            switch segmentType {
                //case 0x14:  // PCS (Presentation Composition Segment)
                //print(parsePCS(segmentData))
                //                return nil
                //            case 0x17:  // WDS (Window Definition Segment)
                //                // WDS parsing not required for basic rendering
                //                return nil
            case 0x16:  // PDS (Palette Definition Segment)
                PDS = parsePDS(segmentData)
                p1 = true
            case 0x15:  // ODS (Object Definition Segment)
                ODS = try parseODS(segmentData)
                p2 = true
                //            case 0x80:  // END (End of Display Set Segment)
                //                // END indicates the end of a subtitle display set
            default:
                continue
            }
            if p1 && p2 {
                p1 = false
                p2 = false
                
                return SupSubtitle(
                    timestamp: timestamp,
                    imageSize: (width: ODS.width, height: ODS.height),
                    imageData: ODS.imageData, imagePalette: PDS)
            }
            //return SupSubtitle(
            //        timestamp: timestamp, imageSize: (width: imageSize.width, height: imageSize.height),
            //        imageData: decodedImageData, imagePalette: imagePalette)
        }
        
    }
    
    private func parseTimestamp(_ data: Data) -> TimeInterval {
        
        let pts = (Int(data[2]) << 24 | Int(data[3]) << 16 | Int(data[4]) << 8
                   | Int(data[5]))
        //& 0x1FFF_FFFF  Seems to reset timestamp around 6000?
        return  TimeInterval(pts) / 90_000.0 // 90 kHz clock
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
    
    /// Parses the Palette Definition Segment (PDS) to extract the RGB palette.
    private func parsePDS(_ data: Data) -> [UInt32] {
        // PDS structure (simplified):
        //   0x16: Segment Type (already checked)
        //   1 byte: Palette ID
        //   1 byte: Palette Version
        //   Followed by a series of palette entries:
        //       Each entry is 5 bytes: (Index, Y, Cr, Cb, Alpha)
        
        var palette = [UInt32](repeating: 0, count: 256)
        
        // Start reading after the first 2 bytes (Palette ID and Version)
        var i = 2
        while i + 4 < data.count {
            let index = data[i]
            let y = data[i + 1]
            let cr = data[i + 2]  //UInt8(128)
            let cb = data[i + 3]  //UInt8(128)
            let alpha = data[i + 4]  //UInt8(16)
            
            // Convert YCrCb to RGB
            let rgb = yCrCbToRGB(y: y, cr: cr, cb: cb)
            
            // Combine the RGB and alpha into a single 32-bit value
            let argb =
            (UInt32(alpha) << 24) | (rgb.red << 16) | (rgb.green << 8)
            | rgb.blue
            
            // Store the result in the palette using the index as the key
            palette[Int(index)] = argb
            
            // Move to the next palette entry
            i += 5
        }
        
        return palette
    }
    
    /// Converts YCrCb values to an RGB tuple
    private func yCrCbToRGB(y: UInt8, cr: UInt8, cb: UInt8) -> (
        red: UInt32, green: UInt32, blue: UInt32
    ) {
        let y = Double(y) //- 16.0
        let cr = 0.0  // Double(cr) - 128.0
        let cb = 0.0  // Double(cb) - 128.0
        
        let yCbCr = simd_double3(y, cb, cr)
        let r1 = simd_double3(1.164, 0, 1.793)
        let r2 = simd_double3(1.164, -0.213, -0.533)
        let r3 = simd_double3(1.164, 2.112, 0)
        let matrix = simd_double3x3(r1, r2, r3)
        let rgb = yCbCr * matrix
        
        // Clamp to 0-255
        let red = UInt32(max(0.0, min(255.0, rgb[0])))
        let green = UInt32(max(0.0, min(255.0, rgb[1])))
        let blue = UInt32(max(0.0, min(255.0, rgb[2])))
        
        return (red: red, green: green, blue: blue)
    }
    
    private func parseODS(_ data: Data) throws -> (
        width: Int, height: Int, imageData: Data
    ) {
        // ODS structure (simplified):
        //   0x17: Segment Type
        //   2 bytes: Object ID
        //   1 byte: Version number
        //   1 byte: Sequence flag (should be 0x80 for new object, 0x00 for continuation)
        //   3 bytes: Object data length
        //   2 bytes: Object width
        //   2 bytes: Object height
        //   Rest: Image data (run-length encoded, RLE)
        
        //let objectID = Int(data[0]) << 8 | Int(data[1])
        let objectDataLength =
        Int(data[4]) << 16 | Int(data[5]) << 8 | Int(data[6])
        
        guard objectDataLength <= data.count - 7 else {
            throw SupDecoderError.invalidFormat
        }  // PGS includes the width and height as part of the image data length calculations
        
        let width = Int(data[7]) << 8 | Int(data[8])
        let height = Int(data[9]) << 8 | Int(data[10])
        let imageData = data.subdata(in: 11..<data.endIndex)
        
        let decodedImageData = decodeRLE(data: imageData)
        
        return (width: width, height: height, imageData: Data(decodedImageData))
    }
    
    /// Saves the decoded grayscale image data as a binary PGM file.
    public func saveAsPGM(
        imageData: Data, width: Int, height: Int, outputPath: URL
    ) throws {
        // Create a file handle for writing
        FileManager.default.createFile(
            atPath: outputPath.absoluteString, contents: nil, attributes: nil)
        let fileHandle = try FileHandle(forWritingTo: outputPath)
        defer { fileHandle.closeFile() }
        
        // Write the PGM header
        let header = "P5\n\(width) \(height)\n8\n"
        guard let headerData = header.data(using: .ascii) else {
            throw SupDecoderError.invalidFormat
        }
        fileHandle.write(headerData)
        
        // Write the image data directly as binary values
        fileHandle.write(imageData)
    }
    
    /// Saves the decoded image data as a PNG file
    public func saveSubtitleAsPNG(
        imageData: Data, palette: [UInt32], width: Int, height: Int,
        outputPath: URL
    ) throws {
        // Create a CGImage from the RGBA data
        guard
            let image = createImage(
                from: imageData, palette: palette, width: width, height: height)
        else {
            throw SupDecoderError.invalidFormat
        }
        
        // Save the image as a PNG file
        try saveImageAsPNG(image: image, outputPath: outputPath)
    }
    
    /// Converts the RGBA data to a CGImage
    public func createImage(
        from imageData: Data, palette: [UInt32], width: Int, height: Int
    ) -> CGImage? {
        // Convert the image data to RGBA format using the palette
        let rgbaData = imageDataToRGBA(
            imageData, palette: palette, width: width, height: height)
        
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) else {
            return nil
        }
        
        guard let provider = CGDataProvider(data: rgbaData as CFData) else {
            return nil
        }
        
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
    
    /// Converts the image data to RGBA format using the palette
    private func imageDataToRGBA(
        _ imageData: Data, palette: [UInt32], width: Int, height: Int
    ) -> Data {
        var rgbaData = Data(capacity: width * height * 4)
        
        for i in 0..<(width * height) {
            let paletteIndex = Int(imageData[i])
            let color = palette[paletteIndex]
            
            // Convert ARGB to RGBA
            //            var r = 255, g = 255, b = 255, a = 0
            //
            //            if (imageData[i] > 128) {
            //                a = 255
            //            }
            var a = (color >> 24) & 0xFF
            var r = (color >> 16) & 0xFF
            var g = (color >> 8) & 0xFF
            var b = color & 0xFF
            
            if a == 0 {
                r = 255
                b = 255
                g = 255
                a = 255
            }
            
            rgbaData.append(contentsOf: [
                UInt8(r), UInt8(g), UInt8(b), UInt8(a),
            ])
        }
        
        return rgbaData
    }
    
    private func saveImageAsPNG(image: CGImage, outputPath: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                outputPath as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw SupDecoderError.fileReadError
        }
        CGImageDestinationAddImage(destination, image, nil)
        
        if !CGImageDestinationFinalize(destination) {
            throw SupDecoderError.fileReadError
        }
    }
}
