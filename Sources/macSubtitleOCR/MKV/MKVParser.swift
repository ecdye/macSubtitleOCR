//
// MKVParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

class MKVParser {
    // MARK: Properties

    private var eof: UInt64
    private var fileHandle: FileHandle
    private var stderr = StandardErrorOutputStream()
    private var timestampScale: Double = 1000000.0 // Default value if not specified in a given MKV file
    private let logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "main")

    // MARK: - Lifecycle

    public init(filePath: String) throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("Error: file '\(filePath)' does not exist", to: &self.stderr)
            throw macSubtitleOCRError.fileReadError
        }

        self.fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        self.eof = self.fileHandle.seekToEndOfFile()
        self.fileHandle.seek(toFileOffset: 0)
        self.logger.debug("Sucessfully opened file: \(filePath)")
    }

    // MARK: Functions

    // Parse the EBML structure and find the Tracks section
    public func parseTracks() -> [MKVTrack]? {
        guard let _ = findElement(withID: EBML.segmentID) as? (UInt64, UInt32) else {
            print("Segment element not found")
            return nil
        }
        self.logger.debug("Found Segment element")

        guard let (tracksSize, _) = findElement(withID: EBML.tracksID) as? (UInt64, UInt32) else {
            print("Tracks element not found")
            return nil
        }
        self.logger.debug("Found Tracks element")
        let endOfTracksOffset = self.fileHandle.offsetInFile + tracksSize

        var trackList = [MKVTrack]()
        while self.fileHandle.offsetInFile < endOfTracksOffset {
            if let (elementID, elementSize, _) = tryParseElement() {
                if elementID == EBML.trackEntryID {
                    self.logger.debug("Found TrackEntry element")
                    if let track = parseTrackEntry() {
                        trackList.append(track)
                    }
                } else if elementID == EBML.chapters {
                    break
                } else {
                    self.fileHandle.seek(toFileOffset: self.fileHandle.offsetInFile + elementSize)
                }
            }
        }
        return trackList
    }

    public func closeFile() {
        self.fileHandle.closeFile()
    }

    public func getSubtitleTrackData(trackNumber: Int, outPath: String) throws -> String? {
        let tmpSup = URL(fileURLWithPath: outPath).deletingPathExtension().appendingPathExtension("sup")
            .lastPathComponent

        if let trackData = extractTrackData(trackNumber: trackNumber) {
            self.logger.debug("Found track data for track number \(trackNumber): \(trackData)")
            let manager = FileManager.default
            let tmpFilePath = (manager.temporaryDirectory.path + "/" + tmpSup)
            if manager.createFile(atPath: tmpFilePath, contents: trackData, attributes: nil) {
                self.logger.debug("Created file at path: \(tmpFilePath).")
                return tmpFilePath
            } else {
                self.logger.debug("Failed to create file at path: \(tmpFilePath).")
                throw PGSError.fileReadError
            }
        } else {
            print("Failed to find track data for track number: \(trackNumber).", to: &self.stderr)
        }
        return nil
    }

    // MARK: - Methods

    // Function to seek to the track bytestream for a specific track number and extract all blocks
    private func extractTrackData(trackNumber: Int) -> Data? {
        self.fileHandle.seek(toFileOffset: 0)

        // Step 1: Locate the Segment element
        if let (segmentSize, _) = findElement(withID: EBML.segmentID) as? (UInt64, UInt32) {
            let segmentEndOffset = self.fileHandle.offsetInFile + segmentSize
            self.logger
                .debug("Found Segment, Size: \(segmentSize), End Offset: \(segmentEndOffset), EOF: \(self.eof)\n")
            var trackData = Data()

            // Step 2: Parse Clusters within the Segment
            while self.fileHandle.offsetInFile < segmentEndOffset {
                if let (clusterSize, _) = findElement(withID: EBML.cluster, avoidCluster: false) as? (
                    UInt64,
                    UInt32
                ) {
                    let clusterEndOffset = self.fileHandle.offsetInFile + clusterSize
                    self.logger.debug("Found Cluster, Size: \(clusterSize), End Offset: \(clusterEndOffset)\n")

                    // Step 3: Extract the cluster timestamp
                    guard let clusterTimestamp = extractClusterTimestamp() else {
                        self.logger.warning("Failed to extract cluster timestamp, skipping cluster.")
                        continue
                    }
                    self.logger.debug("Cluster Timestamp: \(clusterTimestamp)")

                    // Step 4: Parse Blocks (SimpleBlock or Block) within each Cluster
                    while self.fileHandle.offsetInFile < clusterEndOffset {
                        self.logger
                            .debug(
                                "Looking for Block at Offset: \(self.fileHandle.offsetInFile)/\(clusterEndOffset)"
                            )
                        if let (blockSize, blockType) = findElement(
                            withID: EBML.simpleBlock,
                            EBML.blockGroup
                        ) as? (UInt64, UInt32) {
                            var blockStartOffset = self.fileHandle.offsetInFile
                            var blockSize = blockSize

                            if blockType == EBML.blockGroup {
                                guard let (ns, _) = findElement(withID: EBML.block) as? (UInt64, UInt32)
                                else { return nil }
                                blockSize = ns
                                blockStartOffset = self.fileHandle.offsetInFile
                            }

                            // Step 5: Read the track number in the block and compare it
                            if let (blockTrackNumber,
                                    blockTimestamp) = readTrackNumber(from: fileHandle) as? (
                                UInt64,
                                Int64
                            ) {
                                if blockTrackNumber == trackNumber {
                                    // Step 6: Calculate and encode the timestamp as 4 bytes in big-endian
                                    // (PGS format)
                                    let absPTS = calcAbsPTSForPGS(
                                        clusterTimestamp,
                                        blockTimestamp,
                                        timestampScale
                                    )
                                    let pgsPTS = encodePTSForPGS(absPTS)

                                    // Step 7: Read the block data and add needed PGS headers and timestamps
                                    let pgsHeader = Data([0x50, 0x47] + pgsPTS + [0x00, 0x00, 0x00, 0x00])
                                    var blockData = Data()
                                    let raw = self.fileHandle
                                        .readData(ofLength: Int(blockSize -
                                                (self.fileHandle.offsetInFile - blockStartOffset)))
                                    var offset = 0
                                    while (offset + 3) <= raw.count {
                                        let segmentSize = min(
                                            Int(getUInt16BE(buffer: raw, offset: offset + 1) + 3),
                                            raw.count - offset
                                        )
                                        self.logger
                                            .debug(
                                                "Segment size \(segmentSize) at \(offset) type 0x\(String(format: "%02x", raw[offset]))"
                                            )

                                        blockData.append(pgsHeader)
                                        blockData.append(raw.subdata(in: offset ..< segmentSize + offset))
                                        offset += segmentSize
                                    }

                                    trackData.append(blockData)
                                } else {
                                    // Skip this block if it's for a different track
                                    self.logger
                                        .debug(
                                            "Skipping Block at Offset: \(self.fileHandle.offsetInFile)/\(clusterEndOffset)"
                                        )
                                    self.logger
                                        .debug(
                                            "Got Track Number: \(blockTrackNumber) looking for: \(trackNumber)"
                                        )
                                    self.fileHandle.seek(toFileOffset: blockStartOffset + blockSize)
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
    private func extractClusterTimestamp() -> Int64? {
        if let (timestampElementSize, _) = findElement(withID: EBML.timestamp) as? (UInt64, UInt32) {
            return readFixedLengthNumber(fileHandle: self.fileHandle, length: Int(timestampElementSize))
        }
        return nil
    }

    // Function to read the track number, timestamp, and lacing type (if any) from a Block or SimpleBlock
    // header
    private func readTrackNumber(from fileHandle: FileHandle) -> (UInt64?, Int64) {
        let trackNumber = readVINT(from: fileHandle, unmodified: true)
        let timestamp = readFixedLengthNumber(fileHandle: fileHandle, length: 2)
        let suffix = fileHandle.readData(ofLength: 1).first ?? 0

        let lacingFlag = (suffix >> 1) & 0x03 // Bits 1 and 2 are the lacing type
        self.logger.debug("Track number: \(trackNumber), Timestamp: \(timestamp), Lacing type: \(lacingFlag)")
        return (trackNumber, timestamp)
    }

    // Find EBML element by ID, avoiding Cluster header
    private func findElement(withID targetID: UInt32, _ tgtID2: UInt32? = nil,
                             avoidCluster: Bool = true) -> (UInt64?, UInt32?)
    {
        while let (elementID, elementSize, elementOffset) = tryParseElement() {
            // Ensure we stop if we have reached or passed the EOF
            if self.fileHandle.offsetInFile >= self.eof {
                return (nil, nil)
            }

            // If, by chance, we find a TimestampScale element, update it from the default
            if elementID == EBML.timestampScale {
                self.timestampScale = Double(readFixedLengthNumber(
                    fileHandle: self.fileHandle,
                    length: Int(elementSize)
                ))
                self.logger.debug("Found timestamp scale: \(self.timestampScale)")
                return (nil, nil)
            }

            // If a Cluster header is encountered, seek back to the start of the Cluster
            if elementID == EBML.cluster && avoidCluster {
                self.logger.debug("Encountered Cluster: seeking back to before the cluster header")
                self.fileHandle.seek(toFileOffset: elementOffset)
                return (nil, nil)
            }

            // If the element matches the target ID (or secondary ID), return its size
            if elementID == targetID || (tgtID2 != nil && elementID == tgtID2!) {
                return (elementSize, elementID)
            } else {
                // Skip over the element's data by seeking to its end
                self.logger.debug("Found: \(elementID), but not \(targetID), skipping element")
                self.fileHandle.seek(toFileOffset: self.fileHandle.offsetInFile + elementSize)
            }
        }

        return (nil, nil)
    }

    // Parse TrackEntry and return MKVTrack object
    private func parseTrackEntry() -> MKVTrack? {
        var trackNumber: Int?
        var trackType: UInt8?
        var codecId: String?

        while let (elementID, elementSize, _) = tryParseElement() {
            switch elementID {
            case EBML.trackNumberID:
                trackNumber = Int((readBytes(from: self.fileHandle, length: 1)?.first)!)
                self.logger.debug("Found track number: \(trackNumber!)")
            case EBML.trackTypeID:
                trackType = readBytes(from: self.fileHandle, length: 1)?.first
                self.logger.debug("Found track type: \(trackType!)")
            case EBML.codecID:
                var data = readBytes(from: fileHandle, length: Int(elementSize))
                data?.removeNullBytes()
                codecId = data.flatMap { String(data: $0, encoding: .ascii) }
                self.logger.debug("Found codec ID: \(codecId!)")
            default:
                self.fileHandle.seek(toFileOffset: self.fileHandle.offsetInFile + elementSize)
            }
            if trackNumber != nil, trackType != nil, codecId != nil { break }
        }

        if let trackNumber = trackNumber, let trackType = trackType, let codecId = codecId {
            return MKVTrack(trackNumber: trackNumber, trackType: trackType, codecId: codecId)
        }
        return nil
    }

    private func tryParseElement(unmodified: Bool = false)
        -> (elementID: UInt32, elementSize: UInt64, oldOffset: UInt64)?
    {
        let oldOffset = self.fileHandle.offsetInFile
        let (elementID, elementSize) = readEBMLElement(from: fileHandle, unmodified: unmodified)
        return (elementID, elementSize, oldOffset: oldOffset)
    }
}
