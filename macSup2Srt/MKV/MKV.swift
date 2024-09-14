//
//  MKV.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/13/24.
//  Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

// MARK: - Struct to Represent MKV Tracks

struct MKVTrack {
    let trackNumber: Int
    let trackType: UInt8
    let codecId: String
}

// MARK: - Main MKV Parser


class MKVParser {
    private var fileHandle: FileHandle?
    
    // Open the MKV file
    func openFile(filePath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("File does not exist")
            return false
        }
        
        do {
            fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
            print("MKV file opened successfully")
            return true
        } catch {
            print("Error opening file: \(error)")
            return false
        }
    }
    
    // Close the MKV file
    func closeFile() {
        fileHandle?.closeFile()
        fileHandle = nil
    }
    
    // Parse the EBML structure and find the Tracks section
    func parseTracks() -> [MKVTrack]? {
        guard let fileHandle = fileHandle else {
            print("File not opened")
            return nil
        }
        
        // Step 1: Search for the Segment element
        guard findElement(withID: EBML.segmentID) else {
            print("Segment element not found")
            return nil
        }
        
        // Step 2: Search for the Tracks element within the Segment
        guard findElement(withID: EBML.tracksID) else {
            print("Tracks element not found")
            return nil
        }
        
        // Step 3: Parse all TrackEntry elements within the Tracks section
        var trackList = [MKVTrack]()
        
        while let (elementID, _) = tryParseElement(), elementID == EBML.trackEntryID {
            if let track = parseTrackEntry() {
                trackList.append(track)
            }
        }
        
        return trackList
    }
    
    // Function to find a specific EBML element by its ID
    private func findElement(withID targetID: UInt32) -> Bool {
        guard let fileHandle = fileHandle else { return false }
        
        while let (elementID, elementSize) = tryParseElement() {
            if elementID == targetID {
                return true
            } else {
                // Skip over the element's data
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
        }
        
        return false
    }
    
    // Try parsing an EBML element, returning its ID and size (or nil if EOF)
    private func tryParseElement() -> (elementID: UInt32, elementSize: UInt64)? {
        guard let fileHandle = fileHandle, fileHandle.offsetInFile < fileHandle.seekToEndOfFile() else {
            return nil
        }
        
        fileHandle.seek(toFileOffset: fileHandle.offsetInFile)
        
        let (elementID, elementSize) = readEBMLElement(from: fileHandle)
        return (elementID, elementSize)
    }
    
    // Parse a TrackEntry element and return an MKVTrack object
    private func parseTrackEntry() -> MKVTrack? {
        guard let fileHandle = fileHandle else { return nil }
        
        var trackNumber: Int?
        var trackType: UInt8?
        var codecId: String?
        
        // Parse through the elements within the TrackEntry
        while let (elementID, elementSize) = tryParseElement() {
            switch elementID {
            case EBML.trackNumberID:
                trackNumber = Int(readVINT(from: fileHandle))
            case EBML.trackTypeID:
                trackType = readBytes(from: fileHandle, length: Int(elementSize))?.first
            case EBML.codecID:
                if let data = readBytes(from: fileHandle, length: Int(elementSize)) {
                    codecId = String(data: data, encoding: .utf8)
                }
            default:
                // Skip over other elements
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
            
            // Exit early if we have found all necessary info
            if trackNumber != nil, trackType != nil, codecId != nil {
                break
            }
        }
        
        // Return the parsed track entry
        if let trackNumber = trackNumber, let trackType = trackType, let codecId = codecId {
            return MKVTrack(trackNumber: trackNumber, trackType: trackType, codecId: codecId)
        }
        
        return nil
    }
    
    // Seek to the first subtitle track
    func seekToFirstSubtitleTrack() {
        guard let trackList = parseTracks() else {
            print("No tracks found")
            return
        }
        
        // Find the first subtitle track
        if let subtitleTrack = trackList.first(where: { $0.trackType == EBML.subtitleTrackType }) {
            print("Found subtitle track: \(subtitleTrack.trackNumber), Codec: \(subtitleTrack.codecId)")
            // Normally you would seek to the actual subtitle data here
        } else {
            print("No subtitle track found")
        }
    }
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
