//
//  EMBL.swift
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
}

// MARK: - EBML Parsing Helper Functions

// Helper function to read variable-length integers (VINT) from MKV (up to 8 bytes)
func readVINT(from fileHandle: FileHandle) -> UInt64 {
    guard let firstByte = fileHandle.readData(ofLength: 1).first else {
        return 0
    }
    
    var length: UInt8 = 1
    
    // Find how many bytes are needed for the VINT (variable integer)
    for i in 0..<8 {
        if firstByte & (0x80 >> i) != 0 {
            length = UInt8(i + 1)
            break
        }
    }
    
    // Extract the value
    var value: UInt64 = UInt64(firstByte & (0xFF >> length))
    
    if length > 1 {
        let data = fileHandle.readData(ofLength: Int(length - 1))
        for byte in data {
            value = (value << 8) | UInt64(byte)
        }
    }
    
    return value
}

// Helper function to read a specified number of bytes
func readBytes(from fileHandle: FileHandle, length: Int) -> Data? {
    return fileHandle.readData(ofLength: length)
}

// Helper function to read an EBML element's ID and size
func readEBMLElement(from fileHandle: FileHandle) -> (elementID: UInt32, elementSize: UInt64) {
    let elementID = readVINT(from: fileHandle) // Read element ID
    let elementSize = readVINT(from: fileHandle) // Read element size
    return (UInt32(elementID), elementSize)
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
