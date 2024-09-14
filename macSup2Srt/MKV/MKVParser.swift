//
//  MKVParser.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/14/24.
//

import Foundation

class MKVParser {
    private var fileHandle: FileHandle?
    private var eof: UInt64?
    
    // Open the MKV file
    func openFile(filePath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("File does not exist")
            return false
        }
        
        do {
            self.fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
            self.eof = fileHandle!.seekToEndOfFile()
            fileHandle!.seek(toFileOffset: 0)
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
        guard let _ = findElement(withID: EBML.segmentID) else {
            print("Segment element not found")
            return nil
        }
        
        guard let _ = findElement(withID: EBML.tracksID) else {
            print("Tracks element not found")
            return nil
        }
        
        var trackList = [MKVTrack]()
        while let (elementID, elementSize, _) = tryParseElement() {
            if elementID == EBML.trackEntryID {
                if let track = parseTrackEntry() {
                    trackList.append(track)
                }
            } else if elementID == EBML.chapters {
                break
            } else {
                fileHandle?.seek(toFileOffset: fileHandle!.offsetInFile + elementSize)
            }
        }
        return trackList
    }
    
    // Seek to the first subtitle track
    func seekToFirstSubtitleTrack() {
        guard let trackList = parseTracks() else {
            print("No tracks found")
            return
        }
        
        if let subtitleTrack = trackList.first(where: { $0.trackType == EBML.subtitleTrackType }) {
            print("Found subtitle track: \(subtitleTrack.trackNumber), Codec: \(subtitleTrack.codecId)")
            if let trackData = seekToTrackData(trackNumber: subtitleTrack.trackNumber - 1) {
                print("Found track data for track number \(subtitleTrack.trackNumber): \(trackData)")
                print("trackData: \(trackData as NSData)")
            } else {
                print("Failed to find track data for track number \(subtitleTrack.trackNumber).")
            }
        } else {
            print("No subtitle track found")
        }
    }

    // Seek to track bytestream for a specific track number
    private func seekToTrackData(trackNumber: Int) -> Data? {
        guard let fileHandle = self.fileHandle else { return nil }
        fileHandle.seek(toFileOffset: 0)
        
        
        if let segmentSize = findElement(withID: EBML.segmentID) {
            let segmentEndOffset = fileHandle.offsetInFile + segmentSize
            print("Found Segment, Size: \(segmentSize), End Offset: \(segmentEndOffset), EOF: \(eof?.description ?? "Nil")\n")
            
            // Step 2: Parse Clusters within the Segment
            while fileHandle.offsetInFile < segmentEndOffset {
                if let clusterSize = findElement(withID: EBML.cluster, avoidCluster: false) {
                    let clusterEndOffset = fileHandle.offsetInFile + clusterSize
                    print("Found Cluster, Size: \(clusterSize), End Offset: \(clusterEndOffset)\n")
                    
                    // Step 3: Parse Blocks (SimpleBlock or Block) within each Cluster
                    while fileHandle.offsetInFile < clusterEndOffset {
                        print("Looking for Block at Offset: \(fileHandle.offsetInFile)/\(clusterEndOffset)")
                        if let blockSize = findElement(withID: EBML.simpleBlock, EBML.block) {
                            let blockStartOffset = fileHandle.offsetInFile
                            
                            // Step 4: Read the first byte to get the track number
                            if let blockTrackNumber = readTrackNumber(from: fileHandle) {
                                print("Got Track Number: \(blockTrackNumber) looking for: \(trackNumber)\n")
                                // Step 5: Read the block data
                                if blockTrackNumber == trackNumber {
                                    let blockData = fileHandle.readData(ofLength: Int(blockSize - (fileHandle.offsetInFile - blockStartOffset)))
                                    return blockData
                                } else {
                                    fileHandle.seek(toFileOffset: fileHandle.offsetInFile + (blockSize - (fileHandle.offsetInFile - blockStartOffset)))
                                }
                            }
                        } else {
                            break
                        }
                    }
                } else {
                    break
                }
            }
        }
        return nil
    }
    
//    // Find EBML element by ID
//    private func findElement(withID targetID: UInt32, _ tgtID2: UInt32? = nil) -> UInt64? {
//        while let (elementID, elementSize, _) = tryParseElement() {
//            if fileHandle!.offsetInFile >= eof! { return nil }
//            if elementID == targetID || (tgtID2 != nil && elementID == tgtID2!) {
//                return elementSize
//            } else {
//                fileHandle!.seek(toFileOffset: fileHandle!.offsetInFile + elementSize)
//            }
//        }
//        return nil
//    }
    // Find EBML element by ID, avoiding Cluster header
    private func findElement(withID targetID: UInt32, _ tgtID2: UInt32? = nil, avoidCluster: Bool = true) -> UInt64? {
        guard let fileHandle = fileHandle else { return nil }

        while let (elementID, elementSize, elementOffset) = tryParseElement() {
            // Ensure we stop if we have reached or passed the EOF
            if fileHandle.offsetInFile >= eof! {
                return nil
            }

            // If a Cluster header is encountered, seek back to the start of the Cluster
            if elementID == EBML.cluster && avoidCluster {
                print("Encountered Cluster: seeking back to before the cluster header")
                fileHandle.seek(toFileOffset: elementOffset)  // Seek back to before the Cluster header
                return nil
            }

            // If the element matches the target ID (or secondary ID), return its size
            if elementID == targetID || (tgtID2 != nil && elementID == tgtID2!) {
                return elementSize
            } else {
                // Skip over the element's data by seeking to its end
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
        }

        return nil
    }

    // Parse TrackEntry and return MKVTrack object
    private func parseTrackEntry() -> MKVTrack? {
        guard let fileHandle = self.fileHandle else { return nil }
        var trackNumber: Int?
        var trackType: UInt8?
        var codecId: String?
        
        while let (elementID, elementSize, _) = tryParseElement() {
            switch elementID {
            case EBML.trackNumberID:
                trackNumber = Int((readBytes(from: fileHandle, length: 1)?.first)!)
            case EBML.trackTypeID:
                trackType = readBytes(from: fileHandle, length: 1)?.first
            case EBML.codecID:
                var data = readBytes(from: fileHandle, length: Int(elementSize))
                data?.removeNullBytes()
                codecId = data.flatMap { String(data: $0, encoding: .ascii) }
            default:
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
            if trackNumber != nil, trackType != nil, codecId != nil { break }
        }
        
        if let trackNumber = trackNumber, let trackType = trackType, let codecId = codecId {
            return MKVTrack(trackNumber: trackNumber, trackType: trackType, codecId: codecId)
        }
        return nil
    }

    private func readTrackNumber(from fileHandle: FileHandle) -> UInt64? {
        return UInt64((readBytes(from: fileHandle, length: 1)?.first)! & (0x80 - 1))
    }

    private func tryParseElement(unmodified: Bool = false) -> (elementID: UInt32, elementSize: UInt64, os: UInt64)? {
        let oldOs = fileHandle!.offsetInFile
        let (elementID, elementSize) = readEBMLElement(from: fileHandle!, unmodified: unmodified)
        return (elementID, elementSize, os: oldOs)
    }
}
