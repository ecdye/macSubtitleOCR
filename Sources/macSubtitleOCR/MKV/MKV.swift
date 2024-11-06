//
// MKV.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/22/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct MKV {
    // MARK: - Properties

    private let fileHandle: FileHandle
    private let endOfFile: UInt64
    private var timestampScale: TimeInterval = 1000000.0 // Default value if not specified in a given MKV file
    private let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "MKV")
    private let ebmlParser: EBMLParser
    private(set) var tracks: [MKVTrack] = []
    private var codecPrivate = [Int: String]()
    private var languages = [Int: String]()

    // MARK: - Lifecycle

    init(filePath: String) throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw macSubtitleOCRError.fileReadError("File does not exist at path: \(filePath)")
        }
        do {
            try fileHandle = FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        } catch {
            throw macSubtitleOCRError.fileReadError("Failed to open file: \(filePath)")
        }
        endOfFile = fileHandle.seekToEndOfFile()
        fileHandle.seek(toFileOffset: 0)
        ebmlParser = EBMLParser(fileHandle: fileHandle)
    }

    // MARK: - Functions

    func saveSubtitleTrackData(trackNumber: Int, outputDirectory: URL) {
        let codecType = tracks[trackNumber].codecID
        let fileExtension = (codecType == "S_HDMV/PGS") ? "sup" : "sub"
        let trackPath = outputDirectory.appendingPathComponent("track_\(trackNumber)").appendingPathExtension(fileExtension)
            .path

        if FileManager.default.createFile(atPath: trackPath, contents: tracks[trackNumber].trackData, attributes: nil) {
            logger.debug("Created file at path: \(trackPath)")
        } else {
            print("Failed to create file at path: \(trackPath)!", to: &stderr)
        }

        if fileExtension == "sub" {
            let idxPath = outputDirectory.appendingPathComponent("track_\(trackNumber)").appendingPathExtension("idx")
            do {
                try tracks[trackNumber].idxData?.write(to: idxPath, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to write idx file at path: \(idxPath)", to: &stderr)
            }
        }
    }

    mutating func parseTracks(for codecs: [String]) throws {
        guard findElement(withID: EBML.segmentID) as? (UInt64, UInt32) != nil else {
            throw macSubtitleOCRError.invalidInputFile("MKV segment element not found in file")
        }

        guard let (tracksSize, _) = findElement(withID: EBML.tracksID) as? (UInt64, UInt32) else {
            throw macSubtitleOCRError.invalidInputFile("MKV tracks element not found in file")
        }

        let endOfTracksOffset = fileHandle.offsetInFile + tracksSize

        var subtitleTracks = [Int: String]()
        while fileHandle.offsetInFile < endOfTracksOffset {
            if let (elementID, elementSize) = tryParseElement() {
                if elementID == EBML.trackEntryID {
                    logger.debug("Found TrackEntry element")
                    if let track = parseTrackEntry(for: codecs) {
                        subtitleTracks[track.0] = track.1
                    }
                } else if elementID == EBML.chapters {
                    break
                } else {
                    fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
                }
            }
        }

        let trackData = extractTrackData(for: subtitleTracks)
        trackData?.forEach { trackNumber, data in
            if data.isEmpty {
                print("Found empty track data for track \(trackNumber), skipping track!")
                return
            }
            tracks.append(MKVTrack(
                trackNumber: trackNumber,
                codecID: subtitleTracks[trackNumber]!,
                trackData: data,
                idxData: codecPrivate[trackNumber],
                language: languages[trackNumber]))
        }
    }

    mutating func extractTrackData(for tracks: [Int: String]) -> [Int: Data]? {
        fileHandle.seek(toFileOffset: 0)

        guard let segmentSize = locateSegment() else { return nil }
        let segmentEndOffset = fileHandle.offsetInFile + segmentSize
        logger.debug("Found Segment, Size: \(segmentSize), End Offset: \(segmentEndOffset)")

        var trackData = [Int: Data]()

        while fileHandle.offsetInFile < segmentEndOffset {
            guard let clusterSize = locateSegment(avoidCluster: false) else { continue }
            let clusterEndOffset = fileHandle.offsetInFile + clusterSize

            guard let clusterTimestamp = extractClusterTimestamp() else {
                logger.warning("Failed to extract cluster timestamp, skipping cluster.")
                continue
            }

            parseBlocks(until: clusterEndOffset, for: tracks, with: clusterTimestamp, into: &trackData)
        }

        return trackData
    }

    // MARK: - Methods

    private mutating func locateSegment(avoidCluster: Bool = true) -> UInt64? {
        if let (segmentSize, _) = findElement(withID: EBML.segmentID, avoidCluster: avoidCluster) as? (UInt64, UInt32) {
            return segmentSize
        }
        return nil
    }

    private func tryParseElement() -> (elementID: UInt32, elementSize: UInt64)? {
        let (elementID, elementSize) = ebmlParser.readEBMLElement()
        return (elementID, elementSize)
    }

    private mutating func findElement(withID targetID: UInt32, _ tgtID2: UInt32? = nil,
                                      avoidCluster: Bool = true) -> (UInt64?, UInt32?) {
        var previousOffset = fileHandle.offsetInFile
        while let (elementID, elementSize) = tryParseElement() {
            guard fileHandle.offsetInFile < endOfFile else { return (nil, nil) }

            if elementID == EBML.timestampScale {
                timestampScale = Double(readFixedLengthNumber(fileHandle: fileHandle, length: Int(elementSize)))
                continue
            }

            if elementID == EBML.cluster && avoidCluster {
                logger.debug("Encountered Cluster: seeking back to before the cluster header")
                fileHandle.seek(toFileOffset: previousOffset)
                return (nil, nil)
            }

            if elementID == targetID || (tgtID2 != nil && elementID == tgtID2!) {
                return (elementSize, elementID)
            } else {
                logger.debug("\(elementID.hex()) != \(targetID.hex()), skipping element")
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
            previousOffset = fileHandle.offsetInFile
        }
        return (nil, nil)
    }

    private mutating func parseTrackEntry(for codecs: [String]) -> (Int, String)? {
        var trackNumber: Int?
        var trackType: UInt8?
        var codecID: String?
        var language: String?

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
                codecID = String(data: data, encoding: .ascii)
                logger.debug("Found codec ID: \(codecID!)")
            case EBML.language, EBML.languageBCP47:
                var data = fileHandle.readData(ofLength: Int(elementSize))
                data.removeNullBytes()
                language = String(data: data, encoding: .ascii)
                logger.debug("Found language: \(language!)")
                languages[trackNumber!] = language
            default:
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
            if trackNumber != nil, trackType != nil, codecID != nil { break }
        }

        if let trackNumber, let codecID {
            if codecID == "S_VOBSUB" {
                while let (elementID, elementSize) = tryParseElement() {
                    switch elementID {
                    case EBML.codecPrivate:
                        var data = fileHandle.readData(ofLength: Int(elementSize))
                        data.removeNullBytes()
                        codecPrivate[trackNumber] = "# VobSub index file, v7 (do not modify this line!)\n" +
                            (String(data: data, encoding: .ascii) ?? "")
                        if let language {
                            codecPrivate[trackNumber]?.append("langidx: 0\n")
                            codecPrivate[trackNumber]?.append("\nid: \(language), index: 0")
                        }
                    default:
                        fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
                    }
                    if codecPrivate[trackNumber] != nil { break }
                }
            }
            if codecs.contains(codecID) {
                return (trackNumber, codecID)
            }
        }
        return nil
    }

    private mutating func extractClusterTimestamp() -> Int64? {
        if let (timestampElementSize, _) = findElement(withID: EBML.timestamp) as? (UInt64, UInt32) {
            return readFixedLengthNumber(fileHandle: fileHandle, length: Int(timestampElementSize))
        }
        return nil
    }

    private mutating func parseBlocks(until clusterEndOffset: UInt64, for tracks: [Int: String],
                                      with clusterTimestamp: Int64, into trackData: inout [Int: Data]) {
        while fileHandle.offsetInFile < clusterEndOffset {
            guard let (blockSize, blockStartOffset) = findBlockTypeAndSize() else { break }

            guard let (blockTrackNumber, blockTimestamp) = readTrackNumber(from: fileHandle) as? (UInt64, Int64)
            else { continue }

            if tracks[Int(blockTrackNumber)] == "S_HDMV/PGS" {
                handlePGSBlock(for: blockTrackNumber,
                               with: blockTimestamp, blockSize, clusterTimestamp, blockStartOffset, &trackData)
            } else if tracks[Int(blockTrackNumber)] == "S_VOBSUB" {
                handleVobSubBlock(for: blockTrackNumber,
                                  with: blockTimestamp, blockSize, clusterTimestamp, blockStartOffset, &trackData)
            } else {
                fileHandle.seek(toFileOffset: blockStartOffset + blockSize)
            }
        }
    }

    private func handlePGSBlock(for blockTrackNumber: UInt64, with blockTimestamp: Int64, _ blockSize: UInt64,
                                _ clusterTimestamp: Int64, _ blockStartOffset: UInt64, _ trackData: inout [Int: Data]) {
        let absPTS = calculateAbsolutePTS(clusterTimestamp, blockTimestamp)
        let pgsPTS = encodePTSForPGS(absPTS)
        let pgsHeader = Data([0x50, 0x47] + pgsPTS + [0x00, 0x00, 0x00, 0x00])

        var blockData = Data()
        blockData.reserveCapacity(Int(blockSize))
        let raw = fileHandle.readData(ofLength: Int(blockSize - (fileHandle.offsetInFile - blockStartOffset)))

        var offset = 0
        while (offset + 3) <= raw.count {
            let segmentSize = min(Int(raw.getUInt16BE(at: offset + 1)! + 3), raw.count - offset)
            logger.debug("Segment size \(segmentSize) at \(offset) type \(raw[offset].hex())")

            blockData.append(pgsHeader)
            blockData.append(raw.subdata(in: offset ..< segmentSize + offset))
            offset += segmentSize
        }

        let trackNumber = Int(blockTrackNumber)
        if trackData[trackNumber] == nil {
            trackData[trackNumber] = Data()
        }
        trackData[trackNumber]?.append(blockData)
    }

    private mutating func handleVobSubBlock(for blockTrackNumber: UInt64, with blockTimestamp: Int64, _ blockSize: UInt64,
                                            _ clusterTimestamp: Int64, _ blockStartOffset: UInt64,
                                            _ trackData: inout [Int: Data]) {
        let absolutePTS = calculateAbsolutePTS(clusterTimestamp, blockTimestamp)
        let vobSubPTS = encodePTSForVobSub(from: absolutePTS)

        var segmentSize = Int(blockSize - (fileHandle.offsetInFile - blockStartOffset))
        var vobSubHeader = buildVobSubHeader(pts: vobSubPTS, segmentSize: segmentSize)

        vobSubHeader.append(fileHandle.readData(ofLength: min(segmentSize, 2019)))
        segmentSize -= min(segmentSize, 2019)

        appendVobSubSegments(segmentSize: segmentSize, header: &vobSubHeader)

        let trackNumber = Int(blockTrackNumber)
        if trackData[trackNumber] == nil {
            trackData[trackNumber] = Data()
        }
        trackData[trackNumber]?.append(vobSubHeader)

        let offset = String(format: "%09X", trackData[trackNumber]!.count - vobSubHeader.count)
        codecPrivate[trackNumber]?.append("\ntimestamp: \(formatTime(absolutePTS)), filepos: \(offset)")
    }

    // swiftformat:disable all
    private func buildVobSubHeader(pts: [UInt8], segmentSize: Int) -> Data {
        let pesLength = withUnsafeBytes(of: UInt16(min(segmentSize, 2028)).bigEndian) { Array($0) }
        var vobSubHeader = Data([0x00, 0x00, 0x01, 0xBA,              // PS packet start code
                                 0x00, 0x00, 0x00, 0x00, 0x00, 0x0,   // Null system clock reference
                                 0x00, 0x00, 0x00,                    // Null multiplexer rate
                                 0x00,                                // Stuffing length
                                 0x00, 0x00, 0x01, 0xBD])             // PES packet start code
        vobSubHeader.append(contentsOf: pesLength)                    // PES packet length
        vobSubHeader.append(contentsOf: [0x00,                        // PES miscellaneous data
                                         0x80,                        // PTS DTS flag
                                         UInt8(pts.count)])           // PTS data length
        vobSubHeader.append(contentsOf: pts)                          // PTS data
        vobSubHeader.append(contentsOf: [0x00])                       // Null stream ID
        return vobSubHeader
    }

    private func appendVobSubSegments(segmentSize: Int, header: inout Data) {
        var remainingSize = segmentSize
        while remainingSize > 0 {
            let nextSegmentSize = min(remainingSize, 2028)
            let pesLength = withUnsafeBytes(of: UInt16(nextSegmentSize).bigEndian) { Array($0) }
            header.append(contentsOf: [0x00, 0x00, 0x01, 0xBA,              // PS packet start code
                                       0x00, 0x00, 0x00, 0x00, 0x00, 0x0,   // Null system clock reference
                                       0x00, 0x00, 0x00,                    // Null multiplexer rate
                                       0x00,                                // Stuffing length
                                       0x00, 0x00, 0x01, 0xBD])             // PES packet start code
            header.append(contentsOf: pesLength)                            // PES packet length
            header.append(contentsOf: [0x00,                                // PES miscellaneous data
                                       0x00,                                // PTS DTS flag
                                       0x00])                               // PTS data length
            header.append(contentsOf: [0x00])                               // Null stream ID
            header.append(fileHandle.readData(ofLength: min(remainingSize, 2024)))
            remainingSize -= min(remainingSize, 2024)
        }
    }
    // swiftformat:enable all

    private mutating func findBlockTypeAndSize() -> (blockSize: UInt64, blockStartOffset: UInt64)? {
        guard case (var blockSize?, let blockType?) = findElement(withID: EBML.simpleBlock, EBML.blockGroup) else {
            return nil
        }

        var blockStartOffset = fileHandle.offsetInFile
        if blockType == EBML.blockGroup {
            guard let (newSize, _) = findElement(withID: EBML.block) as? (UInt64, UInt32) else { return nil }
            blockSize = newSize
            blockStartOffset = fileHandle.offsetInFile
        }
        return (blockSize, blockStartOffset)
    }

    // Function to read the track number, timestamp, and lacing type (if any) from a Block or SimpleBlock header
    private func readTrackNumber(from fileHandle: FileHandle) -> (UInt64?, Int64) {
        let trackNumber = ebmlParser.readVINT(elementSize: true)
        let timestamp = readFixedLengthNumber(fileHandle: fileHandle, length: 2)
        let suffix = fileHandle.readData(ofLength: 1).first ?? 0

        let lacingFlag = (suffix >> 1) & 0x03 // Bits 1 and 2 are the lacing type (unused by us, kept for debugging)
        logger.debug("Track number: \(trackNumber), Timestamp: \(timestamp), Lacing type: \(lacingFlag)")
        return (trackNumber, timestamp)
    }
}
