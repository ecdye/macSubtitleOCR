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
        guard let _ = findElement(withID: EBML.segmentID) as? (UInt64, UInt32) else {
            print("Segment element not found")
            return nil
        }
        
        guard let _ = findElement(withID: EBML.tracksID) as? (UInt64, UInt32) else {
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
            if let trackData = extractTrackData(trackNumber: subtitleTrack.trackNumber) {
                print("Found track data for track number \(subtitleTrack.trackNumber): \(trackData)")
                print("trackData: \(trackData as NSData)")
                do {
                    try (trackData as NSData).write(to: URL(fileURLWithPath: "/Users/ethandye/Documents/MakeMKV/data.bin"))
                } catch {
                    print("Failed to write subtitle data to file: \(error.localizedDescription).")
                }
            } else {
                print("Failed to find track data for track number \(subtitleTrack.trackNumber).")
            }
        } else {
            print("No subtitle track found")
        }
    }

    // Function to seek to the track bytestream for a specific track number and extract all blocks
    func extractTrackData(trackNumber: Int) -> Data? {
        guard let fileHandle = self.fileHandle else { return nil }
        fileHandle.seek(toFileOffset: 0)
        
        // Step 1: Locate the Segment element
        if let (segmentSize, _) = findElement(withID: EBML.segmentID) as? (UInt64, UInt32) {
            let segmentEndOffset = fileHandle.offsetInFile + segmentSize
            print("Found Segment, Size: \(segmentSize), End Offset: \(segmentEndOffset), EOF: \(eof?.description ?? "Nil")\n")
            var trackData = Data()

            // Step 2: Parse Clusters within the Segment
            while fileHandle.offsetInFile < segmentEndOffset {
                if let (clusterSize, _) = findElement(withID: EBML.cluster, avoidCluster: false) as? (UInt64, UInt32) {
                    let clusterEndOffset = fileHandle.offsetInFile + clusterSize
                    print("Found Cluster, Size: \(clusterSize), End Offset: \(clusterEndOffset)\n")
                    
                    // Step 3: Parse Blocks (SimpleBlock or Block) within each Cluster
                    while fileHandle.offsetInFile < clusterEndOffset {
                        print("Looking for Block at Offset: \(fileHandle.offsetInFile)/\(clusterEndOffset)")
                        if let (blockSize, blockType) = findElement(withID: EBML.simpleBlock, EBML.blockGroup) as? (UInt64, UInt32) {
                            var blockStartOffset = fileHandle.offsetInFile
                            var blockSize = blockSize
                            
                            if (blockType == EBML.blockGroup) {
                                guard let (ns, _) = findElement(withID: EBML.block) as? (UInt64, UInt32) else { return nil }
                                blockSize = ns
                                blockStartOffset = fileHandle.offsetInFile
                            }
                            
                                                            
                            // Step 4: Read the track number in the block and compare it
                            if let (blockTrackNumber, blockTimestamp) = readTrackNumber(from: fileHandle) as? (UInt64, [UInt8]) {
                                print("Got Track Number: \(blockTrackNumber) looking for: \(trackNumber)")
                                if blockTrackNumber == trackNumber {
                                    // Step 5: Read the block data and append it to the track data
                                    print("Reading Block at Offset: \(fileHandle.offsetInFile)/\(clusterEndOffset)\n")
                                    var blockData = Data.init()
                                    blockData.append(contentsOf: [0x50, 0x47, blockTimestamp[0], blockTimestamp[1]])
                                    blockData.append(fileHandle.readData(ofLength: Int(blockSize - (fileHandle.offsetInFile - blockStartOffset))))
                                    trackData.append(blockData)
                                } else {
                                    // Skip this block if it's for a different track
                                    print("Skipping Block at Offset: \(fileHandle.offsetInFile)/\(clusterEndOffset)\n")
                                    fileHandle.seek(toFileOffset: blockStartOffset + blockSize)
                                }
                            }
                        } else {
                            break // No more blocks found in this cluster
                        }
                    }
                } else {
                    break // No more clusters found in the segment
                }
            }

            return trackData.isEmpty ? nil : trackData
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
    private func findElement(withID targetID: UInt32, _ tgtID2: UInt32? = nil, avoidCluster: Bool = true) -> (UInt64?, UInt32?) {
        guard let fileHandle = fileHandle else { return (nil, nil) }

        while let (elementID, elementSize, elementOffset) = tryParseElement() {
            // Ensure we stop if we have reached or passed the EOF
            if fileHandle.offsetInFile >= eof! {
                return (nil, nil)
            }

            // If a Cluster header is encountered, seek back to the start of the Cluster
            if elementID == EBML.cluster && avoidCluster {
                print("Encountered Cluster: seeking back to before the cluster header\n")
                fileHandle.seek(toFileOffset: elementOffset)  // Seek back to before the Cluster header
                return (nil, nil)
            }

            // If the element matches the target ID (or secondary ID), return its size
            if elementID == targetID || (tgtID2 != nil && elementID == tgtID2!) {
                if elementID == EBML.simpleBlock {
                    print("Got SimpleBlock")
                } else if elementID == EBML.block {
                    print("Got Block")
                } else if elementID == EBML.blockGroup {
                    print("Got BlockGroup")
                }
                return (elementSize, elementID)
            } else {
                // Skip over the element's data by seeking to its end
                print("Skipping over element!")  // Off by one idea start
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
        }

        return (nil, nil)
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
    
    
    // Updated function to read track number from a SimpleBlock or Block
    func readTrackNumber(from fileHandle: FileHandle) -> (UInt64?, [UInt8]) {
        print("Reading track Number")
        let (trackNumber, lacing, timestamp) = parseBlockHeader(from: fileHandle)!
        if lacing != nil, lacing != 0x00 { print("Lacing is not supported") }
        return (trackNumber, timestamp)
    }
    
    func parseBlockHeader(from fileHandle: FileHandle) -> (trackNumber: UInt64, lacingType: UInt8?, timestamp: [UInt8])? {
       // guard let firstByte = fileHandle.readData(ofLength: 1).first else { return nil }
        let trackNumber = readVINT(from: fileHandle, unmodified: true)
        let timestamp = fileHandle.readData(ofLength: 2)
        let suffix = fileHandle.readData(ofLength: 1)

        let lacingFlag = (suffix[0] >> 1) & 0x03    // Bits 1 and 2 are the lacing type
        let PTS = [UInt8(timestamp[0]), UInt8(timestamp[1])]
        print("Track number: \(trackNumber), Lacing type: \(lacingFlag)")
        if lacingFlag != 0x00 {
            // Lacing is present, return the lacing type (1 for Xiph, 2 for Fixed, 3 for EBML lacing)
            return (trackNumber, lacingFlag, PTS)
        } else {
            // No lacing
            return (trackNumber, nil, PTS)
        }
    }
//    // Function to read the track number from a SimpleBlock or Block element
//    func readTrackNumber(from fileHandle: FileHandle) -> UInt64? {
//        // SimpleBlock/Block structure starts with a VINT that encodes the track number
//        //guard let firstByte = readBytes(from: fileHandle, length: 1)?.first else { return nil }
//        let trackNumber = readVINT(from: fileHandle, unmodified: true)
//        let trackPosition = fileHandle.readData(ofLength: 2)
//        return trackNumber //UInt64(firstByte & (0x80 - 1))  // Mask off the leading VINT flag
//    }

    private func tryParseElement(unmodified: Bool = false) -> (elementID: UInt32, elementSize: UInt64, os: UInt64)? {
        let oldOs = fileHandle!.offsetInFile
        let (elementID, elementSize) = readEBMLElement(from: fileHandle!, unmodified: unmodified)
        return (elementID, elementSize, os: oldOs)
    }
}
