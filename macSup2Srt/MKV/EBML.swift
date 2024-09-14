//
//  EBML.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/13/24.
//

import Foundation

// MARK: - EBML Constants

// Matroska's EBML IDs for important elements
enum EBML {
    static let segmentID: UInt32 = 0x18538067  // EBML ID for the Segment
    static let tracksID: UInt32 = 0x1654AE6B   // EBML ID for Tracks
    static let trackEntryID: UInt32 = 0xAE     // EBML ID for TrackEntry
    static let trackTypeID: UInt32 = 0x83      // EBML ID for TrackType
    static let trackNumberID: UInt32 = 0xD7    // EBML ID for TrackNumber
    static let codecID: UInt32 = 0x86          // EBML ID for CodecID
    static let subtitleTrackType: UInt8 = 0x11 // Subtitle track type ID in MKV
    static let trackUID: UInt32 = 0x73C5       // EBML ID for TrackUID
    static let flagDefault: UInt32 = 0x88      // EBML ID for FlagDefault
    static let flagLacing: UInt32 = 0x9C       // EBML ID for FlagDefault
    static let minCache: UInt32 = 0x6DE7       // EBML ID for MinCache
    static let language: UInt32 = 0x22B59C     // EBML ID for Language
    static let defaultDuration: UInt32 = 0x23E383 // EBML ID for DefaultDuration
    static let void: UInt32 = 0xEC             // EBML ID for Void
    static let chapters: UInt32 = 0x1043A770    // EBML ID for Chapters
    static let cluster: UInt32 = 0x1F43B675    // EBML ID for Cluster
    static let simpleBlock: UInt32 = 0xA3      // EBML ID for SimpleBlock
    static let block: UInt32 = 0xA1            // EBML ID for Block
}

// MARK: - EBML Parsing Helper Functions

//// Helper function to read variable-length integers (VINT) from MKV (up to 8 bytes)
func readVINT(from fileHandle: FileHandle, unmodified: Bool = false) -> UInt64 {
    guard let firstByte = fileHandle.readData(ofLength: 1).first else {
            return 0
        }
    var length: UInt8 = 1
    var mask: UInt8 = 0x80

    // Find how many bytes are needed for the VINT (variable integer)
    while ((firstByte & UInt8(mask)) == 0) {
        length += 1
        mask >>= 1
    }
    print("length: \(length)")
    
    // Extract the value'
    print(String(format:"mask: 0x%08X", mask))
    if (mask - 1 == 0x0F) {
        mask = 0xFF
        //    } else if (EBML.trackNumberID == firstByte ||
        //               EBML.trackEntryID == firstByte ||
        //               EBML.trackUID >> 8 == firstByte ||
        //               EBML.flagDefault == firstByte ||
        //               EBML.flagLacing == firstByte ||
        //               EBML.trackTypeID == firstByte ||
        //               EBML.codecID == firstByte ||
        //               EBML.void == firstByte ||
        //               EBML.minCache >> 8 == firstByte ||
        //               EBML.language >> 16 == firstByte ||
        //               EBML.defaultDuration >> 16 == firstByte) && !unmodified {
    } else if (length == 1) && !unmodified {
        mask = firstByte
    } else {
        mask = mask - 1
    }
    print(String(format:"Byte: 0x%08X", firstByte))
    print(String(format:"Res: 0x%08X", firstByte & mask))
    var value: UInt64 = UInt64(firstByte & mask)
    
    if length > 1 {
        let data = fileHandle.readData(ofLength: Int(length - 1))
        for byte in data {
//            print(String(format:"B4: 0x%02X", value))
            //if value != 0 {
                value <<= 8
                value |= UInt64(byte)
           // } else {
         //       value = UInt64(byte)
           // }
//            print(String(format:"AF: 0x%02X", value))
        }
    }
    //print("value: \(value)")
    return value
}

// Helper function to read a specified number of bytes
func readBytes(from fileHandle: FileHandle, length: Int) -> Data? {
    return fileHandle.readData(ofLength: length)
}

// Helper function to read an EBML element's ID and size
func readEBMLElement(from fileHandle: FileHandle, unmodified: Bool = false) -> (elementID: UInt32, elementSize: UInt64) {
    let elementID = readVINT(from: fileHandle, unmodified: unmodified) // Read element ID
    let elementSize = readVINT(from: fileHandle, unmodified: true) // Read element size
            print(String(format:"elementID: 0x%08X, elementSize: \(elementSize)", elementID))
            return (UInt32(elementID), elementSize)
//    if elementID ==  EBML.language || elementID == EBML.defaultDuration {
//        let elementSize = readVINT(from: fileHandle, unmodified: true) // Read element size
//        print(String(format:"elementID: 0x%08X, elementSize: \(elementSize)", elementID))
//        return (UInt32(elementID), elementSize)
//    } else {
//        let elementSize = readVINT(from: fileHandle) // Read element size
//        print(String(format:"elementID: 0x%08X, elementSize: \(elementSize)", elementID))
//        return (UInt32(elementID), elementSize)
//    }
}



// MARK: - Usage Example
//
//let mkvParser = MKVParser()
//let filePath = "/path/to/your/file.mkv" // Replace with your MKV file path
//
//if mkvParser.openFile(filePath: filePath) {
//    mkvParser.seekToFirstSubtitleTrack()
//    mkvParser.closeFile()
//} else {
//    print("Failed to open the MKV file.")
//}
