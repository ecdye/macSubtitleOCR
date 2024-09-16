//
//  MKVParser.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/14/24.
//  Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

class MKVParser {
    private var fileHandle: FileHandle?
    private var eof: UInt64?
    private var timestampScale: Double = 1_000_000.0 // Default value if not specified in a given MKV file

    // Open the MKV file
    func openFile(filePath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("File does not exist")
            return false
        }

        do {
            fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
            eof = fileHandle!.seekToEndOfFile()
            fileHandle!.seek(toFileOffset: 0)
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
    public func parseTracks() -> [MKVTrack]? {
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

    func getSubtitleTrackData(trackNumber: Int, outPath: String) {
        if let trackData = extractTrackData(trackNumber: trackNumber) {
//                print("Found track data for track number \(trackNumber): \(trackData)")
            do {
                try (trackData as NSData).write(to: URL(fileURLWithPath: outPath).deletingPathExtension().appendingPathExtension("sup"))
            } catch {
                print("Failed to write subtitle data to file: \(error.localizedDescription).")
            }
        } else {
            print("Failed to find track data for track number \(trackNumber).")
        }
    }

    // Function to seek to the track bytestream for a specific track number and extract all blocks
    func extractTrackData(trackNumber: Int) -> Data? {
        guard let fileHandle = fileHandle else { return nil }
        fileHandle.seek(toFileOffset: 0)

        // Step 1: Locate the Segment element
        if let (segmentSize, _) = findElement(withID: EBML.segmentID) as? (UInt64, UInt32) {
            let segmentEndOffset = fileHandle.offsetInFile + segmentSize
//            print("Found Segment, Size: \(segmentSize), End Offset: \(segmentEndOffset), EOF: \(eof?.description ?? "Nil")\n")
            var trackData = Data()

            // Step 2: Parse Clusters within the Segment
            while fileHandle.offsetInFile < segmentEndOffset {
                if let (clusterSize, _) = findElement(withID: EBML.cluster, avoidCluster: false) as? (UInt64, UInt32) {
                    let clusterEndOffset = fileHandle.offsetInFile + clusterSize
//                    print("Found Cluster, Size: \(clusterSize), End Offset: \(clusterEndOffset)\n")

                    // Step 3: Extract the cluster timestamp
                    guard let clusterTimestamp = extractClusterTimestamp() else {
                        print("Failed to extract cluster timestamp")
                        continue
                    }

//                    print("Cluster Timestamp: \(clusterTimestamp)")

                    // Step 4: Parse Blocks (SimpleBlock or Block) within each Cluster
                    while fileHandle.offsetInFile < clusterEndOffset {
//                        print("Looking for Block at Offset: \(fileHandle.offsetInFile)/\(clusterEndOffset)")
                        if let (blockSize, blockType) = findElement(withID: EBML.simpleBlock, EBML.blockGroup) as? (UInt64, UInt32) {
                            var blockStartOffset = fileHandle.offsetInFile
                            var blockSize = blockSize

                            if blockType == EBML.blockGroup {
                                guard let (ns, _) = findElement(withID: EBML.block) as? (UInt64, UInt32) else { return nil }
                                blockSize = ns
                                blockStartOffset = fileHandle.offsetInFile
                            }

                            // Step 5: Read the track number in the block and compare it
                            if let (blockTrackNumber, blockTimestamp) = readTrackNumber(from: fileHandle) as? (UInt64, Int64) {
                                if blockTrackNumber == trackNumber {
                                    // Step 6: Calculate and encode the timestamp as 4 bytes in big-endian (PGS format)
                                    let absPTS = calcAbsPTSForPGS(clusterTimestamp, blockTimestamp, timestampScale)
                                    let pgsPTS = encodePTSForPGS(absPTS)
//                                    print("Encoded Timestamp: \(pgsPTS)")

                                    // Step 7: Read the block data and add needed PGS headers and timestamps
                                    let pgsHeader = Data([0x50, 0x47] + pgsPTS + [0x00, 0x00, 0x00, 0x00])
                                    var blockData = Data()
                                    let raw = fileHandle.readData(ofLength: Int(blockSize - (fileHandle.offsetInFile - blockStartOffset)))
                                    var offset = 0
                                    while (offset + 3) <= raw.count {
                                        let segmentSize = min(Int(getUInt16BE(buffer: raw, offset: offset + 1) + 3), raw.count - offset)
//                                        let type = raw[offset]
//                                        print("Segment size \(segmentSize) at \(offset) type 0x\(String(format: "%02x", type))")

                                        blockData.append(pgsHeader)
                                        blockData.append(raw.subdata(in: offset ..< segmentSize + offset))
                                        offset += segmentSize
                                    }

                                    trackData.append(blockData)
                                } else {
                                    // Skip this block if it's for a different track
//                                    print("Skipping Block at Offset: \(fileHandle.offsetInFile)/\(clusterEndOffset)")
//                                    print("Got Track Number: \(blockTrackNumber) looking for: \(trackNumber)\n")
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

    // Extract the cluster timestamp
    func extractClusterTimestamp() -> Int64? {
        guard let fileHandle = fileHandle else { return nil }

        if let (timestampElementSize, _) = findElement(withID: EBML.timestamp) as? (UInt64, UInt32) {
            return readFixedLengthNumber(fileHandle: fileHandle, length: Int(timestampElementSize))
        }
        return nil
    }

    // Find EBML element by ID, avoiding Cluster header
    private func findElement(withID targetID: UInt32, _ tgtID2: UInt32? = nil, avoidCluster: Bool = true) -> (UInt64?, UInt32?) {
        guard let fileHandle = fileHandle else { return (nil, nil) }

        while let (elementID, elementSize, elementOffset) = tryParseElement() {
            // Ensure we stop if we have reached or passed the EOF
            if fileHandle.offsetInFile >= eof! {
                return (nil, nil)
            }

            // If, by chance, we find a different scale, update it from the default
            if elementID == EBML.timestampScale {
                timestampScale = Double(readFixedLengthNumber(fileHandle: fileHandle, length: Int(elementSize)))
            }

            // If a Cluster header is encountered, seek back to the start of the Cluster
            if elementID == EBML.cluster && avoidCluster {
//                print("Encountered Cluster: seeking back to before the cluster header\n")
                fileHandle.seek(toFileOffset: elementOffset) // Seek back to before the Cluster header
                return (nil, nil)
            }

            // If the element matches the target ID (or secondary ID), return its size
            if elementID == targetID || (tgtID2 != nil && elementID == tgtID2!) {
                return (elementSize, elementID)
            } else {
                // Skip over the element's data by seeking to its end
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
        }

        return (nil, nil)
    }

    // Parse TrackEntry and return MKVTrack object
    private func parseTrackEntry() -> MKVTrack? {
        guard let fileHandle = fileHandle else { return nil }
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

    /// Function to read the track number, timestamp, and lacing type (if any) from a Block or SimpleBlock header
    func readTrackNumber(from fileHandle: FileHandle) -> (UInt64?, Int64) {
        let (trackNumber, _, timestamp) = parseBlockHeader(from: fileHandle)!
        return (trackNumber, timestamp)
    }

    func parseBlockHeader(from fileHandle: FileHandle) -> (trackNumber: UInt64, lacingType: UInt8?, timestamp: Int64)? {
        let trackNumber = readVINT(from: fileHandle, unmodified: true)
        let timestamp = readFixedLengthNumber(fileHandle: fileHandle, length: 2)
        let suffix = fileHandle.readData(ofLength: 1)

        let lacingFlag = (suffix[0] >> 1) & 0x03 // Bits 1 and 2 are the lacing type
//        print("Track number: \(trackNumber), Lacing type: \(lacingFlag)")
        if lacingFlag != 0x00 {
            // Lacing is present, return the lacing type (1 for Xiph, 2 for Fixed, 3 for EBML lacing), currently unused
            return (trackNumber, lacingFlag, timestamp)
        } else {
            // No lacing
            return (trackNumber, nil, timestamp)
        }
    }

    private func tryParseElement(unmodified: Bool = false) -> (elementID: UInt32, elementSize: UInt64, os: UInt64)? {
        let oldOs = fileHandle!.offsetInFile
        let (elementID, elementSize) = readEBMLElement(from: fileHandle!, unmodified: unmodified)
        return (elementID, elementSize, os: oldOs)
    }
}
