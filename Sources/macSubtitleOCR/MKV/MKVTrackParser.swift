//
// MKVTrackParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/22/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

class MKVTrackParser: MKVFileHandler {
    // MARK: - Properties

    private(set) var tracks: [MKVTrack] = []
    private(set) var codecPrivate = [Int: String]()

    // MARK: - Functions

    func parseTracks(codec: [String]) throws {
        guard findElement(withID: EBML.segmentID) as? (UInt64, UInt32) != nil else {
            fatalError("Segment element not found in file: \(filePath)")
        }

        guard let (tracksSize, _) = findElement(withID: EBML.tracksID) as? (UInt64, UInt32) else {
            fatalError("Tracks element not found in file: \(filePath)")
        }

        let endOfTracksOffset = fileHandle.offsetInFile + tracksSize

        var tracks = [Int: String]()
        while fileHandle.offsetInFile < endOfTracksOffset {
            if let (elementID, elementSize) = tryParseElement() {
                if elementID == EBML.trackEntryID {
                    logger.debug("Found TrackEntry element")
                    if let track = parseTrackEntry(codec: codec) {
                        tracks[track.0] = track.1
                    }
                } else if elementID == EBML.chapters {
                    break
                } else {
                    fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
                }
            }
        }

        let trackData = extractTrackData(from: tracks)
        trackData?.enumerated().forEach { index, data in
            self.tracks.append(MKVTrack(
                trackNumber: index,
                codecId: tracks[index + 1]!,
                trackData: data,
                idxData: codecPrivate[index + 1]))
        }
    }

    func extractTrackData(from tracks: [Int: String]) -> [Data]? {
        fileHandle.seek(toFileOffset: 0)

        // Step 1: Locate the Segment element
        guard let segmentSize = locateSegment() else { return nil }
        let segmentEndOffset = fileHandle.offsetInFile + segmentSize
        // swiftformat:disable:next redundantSelf
        logger.debug("Found Segment, Size: \(segmentSize), End Offset: \(segmentEndOffset), EOF: \(self.endOfFile)")

        var trackData = [Data](repeating: Data(), count: tracks.count)

        // Step 2: Parse Clusters within the Segment
        while fileHandle.offsetInFile < segmentEndOffset {
            guard let clusterSize = locateCluster() else { continue }
            let clusterEndOffset = fileHandle.offsetInFile + clusterSize

            // Step 3: Extract the cluster timestamp
            guard let clusterTimestamp = extractClusterTimestamp() else {
                logger.warning("Failed to extract cluster timestamp, skipping cluster.")
                continue
            }

            // Step 4: Parse Blocks (SimpleBlock or Block) within each Cluster
            parseBlocks(
                within: clusterEndOffset,
                trackNumber: tracks,
                clusterTimestamp: clusterTimestamp,
                trackData: &trackData)
        }

        return trackData.isEmpty ? nil : trackData
    }

    // MARK: - Methods

    private func parseTrackEntry(codec: [String]) -> (Int, String)? {
        var trackNumber: Int?
        var trackType: UInt8?
        var codecId: String?

        while let (elementID, elementSize) = tryParseElement() {
            switch elementID {
            case EBML.trackNumberID:
                trackNumber = Int((fileHandle.readData(ofLength: Int(elementSize)).first)!)
                logger.debug("Found track number: \(trackNumber!)")
            case EBML.trackTypeID: // Unused by us, left for debugging
                trackType = fileHandle.readData(ofLength: Int(elementSize)).first
                logger.debug("Found track type: \(trackType!)")
            case EBML.codecID:
                var data = fileHandle.readData(ofLength: Int(elementSize))
                data.removeNullBytes()
                codecId = String(data: data, encoding: .ascii)
                logger.debug("Found codec ID: \(codecId ?? "nil")")
            default:
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
            if trackNumber != nil, trackType != nil, codecId != nil { break }
        }

        if let trackNumber, let codecId {
            if codecId == "S_VOBSUB" {
                while let (elementID, elementSize) = tryParseElement() {
                    switch elementID {
                    case EBML.codecPrivate:
                        var data = fileHandle.readData(ofLength: Int(elementSize))
                        data.removeNullBytes()
                        codecPrivate[trackNumber] = String(data: data, encoding: .ascii)
                    default:
                        fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
                    }
                    if codecPrivate[trackNumber] != nil { break }
                }
            }
            if codec.contains(codecId) {
                return (trackNumber, codecId)
            }
        }
        return nil
    }

    private func extractClusterTimestamp() -> Int64? {
        if let (timestampElementSize, _) = findElement(withID: EBML.timestamp) as? (UInt64, UInt32) {
            return readFixedLengthNumber(fileHandle: fileHandle, length: Int(timestampElementSize))
        }
        return nil
    }

    private func parseBlocks(within clusterEndOffset: UInt64, trackNumber: [Int: String], clusterTimestamp: Int64,
                             trackData: inout [Data]) {
        while fileHandle.offsetInFile < clusterEndOffset {
            // swiftformat:disable:next redundantSelf
            logger.debug("Looking for Block at Offset: \(self.fileHandle.offsetInFile)/\(clusterEndOffset)")
            guard case (var blockSize?, let blockType?) = findElement(withID: EBML.simpleBlock, EBML.blockGroup)
            else { break }

            var blockStartOffset = fileHandle.offsetInFile

            if blockType == EBML.blockGroup {
                guard let (ns, _) = findElement(withID: EBML.block) as? (UInt64, UInt32) else { return }
                blockSize = ns
                blockStartOffset = fileHandle.offsetInFile
            }

            // Step 5: Read the track number in the block and compare it
            guard let (blockTrackNumber, blockTimestamp) = readTrackNumber(from: fileHandle) as? (UInt64, Int64)
            else { continue }
            if trackNumber[Int(blockTrackNumber)] == "S_HDMV/PGS" {
                // Step 6: Calculate and encode the timestamp as 4 bytes in big-endian (PGS format)
                let absPTS = calcAbsPTS(clusterTimestamp, blockTimestamp)
                let pgsPTS = encodePTSForPGS(absPTS)

                // Step 7: Read the block data and add needed PGS headers and timestamps
                let pgsHeader = Data([0x50, 0x47] + pgsPTS + [0x00, 0x00, 0x00, 0x00])
                var blockData = Data()
                let raw = fileHandle.readData(ofLength: Int(blockSize - (fileHandle.offsetInFile - blockStartOffset)))
                var offset = 0
                while (offset + 3) <= raw.count {
                    let segmentSize = min(Int(raw.getUInt16BE(at: offset + 1)! + 3), raw.count - offset)
                    logger.debug("Segment size \(segmentSize) at \(offset) type \(raw[offset].hex())")

                    blockData.append(pgsHeader)
                    blockData.append(raw.subdata(in: offset ..< segmentSize + offset))
                    offset += segmentSize
                }

                trackData[Int(blockTrackNumber - 1)].append(blockData)
            } else if trackNumber[Int(blockTrackNumber)] == "S_VOBSUB" {
                // swiftformat:disable all
                // Step 6: Calculate and encode the timestamp as 5 bytes in big-endian (VobSub format)
                let absPTS = calcAbsPTS(clusterTimestamp, blockTimestamp)
                let vobSubPTS = encodePTSForVobSub(absPTS)
                var segmentSize = Int(blockSize - (fileHandle.offsetInFile - blockStartOffset))
                let pesLength = withUnsafeBytes(of: UInt16(min(segmentSize, 2028)).bigEndian) { Array($0) }
                // 2028 is the maximum size of a VobSub segment, so we need to split the data into multiple segments
                // The first segment will contain the PTS data, while the rest will not, so it only gets 2019 bytes of data
                // The rest of the segments will get 2024 bytes of data

                // Step 7: Read the block data and add needed VobSub headers and timestamps
                var vobSubHeader = Data([0x00, 0x00, 0x01, 0xBA,              // PS packet start code
                                         0x00, 0x00, 0x00, 0x00, 0x00, 0x0,   // Null system clock reference
                                         0x00, 0x00, 0x00,                    // Null multiplexer rate
                                         0x00,                                // Stuffing length
                                         0x00, 0x00, 0x01, 0xBD])             // PES packet start code
                vobSubHeader.append(contentsOf: pesLength)                    // PES packet length
                vobSubHeader.append(contentsOf: [0x00,                        // PES miscellaneous data
                                                0x80,                         // PTS DTS flag
                                                UInt8(vobSubPTS.count)])      // PTS data length
                vobSubHeader.append(contentsOf: vobSubPTS)                    // PTS data
                vobSubHeader.append(contentsOf: [0x00])                       // Null stream ID
                vobSubHeader.append(fileHandle.readData(ofLength: min(segmentSize, 2019)))

                segmentSize -= min(segmentSize, 2019)

                while segmentSize > 0 {
                    let nextSegmentSize = min(segmentSize, 2028)
                    let pesLength = withUnsafeBytes(of: UInt16(nextSegmentSize).bigEndian) { Array($0) }
                    vobSubHeader.append(contentsOf: [0x00, 0x00, 0x01, 0xBA,              // PS packet start code
                                                     0x00, 0x00, 0x00, 0x00, 0x00, 0x0,   // Null system clock reference
                                                     0x00, 0x00, 0x00,                    // Null multiplexer rate
                                                     0x00,                                // Stuffing length
                                                     0x00, 0x00, 0x01, 0xBD])             // PES packet start code
                    vobSubHeader.append(contentsOf: pesLength)                            // PES packet length
                    vobSubHeader.append(contentsOf: [0x00,                                // PES miscellaneous data
                                                     0x00,                                // PTS DTS flag
                                                     0x00])                               // PTS data length
                    vobSubHeader.append(contentsOf: [0x00])                               // Null stream ID
                    vobSubHeader.append(fileHandle.readData(ofLength: min(segmentSize, 2024)))
                    segmentSize -= min(segmentSize, 2024)
                }

                trackData[Int(blockTrackNumber - 1)].append(vobSubHeader)
                let offset = String(format: "%09X", trackData[Int(blockTrackNumber - 1)].count - vobSubHeader.count)
                codecPrivate[Int(blockTrackNumber)]?.append("\ntimestamp: \(formatTime(absPTS)), filepos: \(offset)")
                // swiftformat:enable all
            } else {
                // Skip this block because it's for a different track
                fileHandle.seek(toFileOffset: blockStartOffset + blockSize)
            }
        }
    }

    private func formatTime(_ time: UInt64) -> String {
        let time = TimeInterval(time) / 90000
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time - TimeInterval(Int(time))) * 1000)

        return String(format: "%02d:%02d:%02d:%03d", hours, minutes, seconds, milliseconds)
    }

    // Function to read the track number, timestamp, and lacing type (if any) from a Block or SimpleBlock header
    private func readTrackNumber(from fileHandle: FileHandle) -> (UInt64?, Int64) {
        let trackNumber = readVINT(from: fileHandle, elementSize: true)
        let timestamp = readFixedLengthNumber(fileHandle: fileHandle, length: 2)
        let suffix = fileHandle.readData(ofLength: 1).first ?? 0

        let lacingFlag = (suffix >> 1) & 0x03 // Bits 1 and 2 are the lacing type (unused by us, kept for debugging)
        logger.debug("Track number: \(trackNumber), Timestamp: \(timestamp), Lacing type: \(lacingFlag)")
        return (trackNumber, timestamp)
    }
}
