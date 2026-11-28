//
// MKVTrackParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/22/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

class MKVTrackParser: MKVFileHandler {
    // MARK: - Properties

    private(set) var tracks: [MKVTrack] = []
    private var codecPrivate = [Int: String]()
    private var languages = [Int: String]()
    /// Nanoseconds per Cluster and Block timestamp tick, from the Segment Info.
    private(set) var timestampScale = defaultTimestampScale
    /// Codec IDs of the subtitle tracks that were passed over because they are not ones asked for.
    private(set) var skippedSubtitleCodecs: [String] = []

    // MARK: - Functions

    func parseTracks(for codecs: [String]) throws {
        guard findElement(withID: EBML.segmentID) as? (UInt64, UInt32) != nil else {
            throw macSubtitleOCRError.invalidInputFile("MKV segment element not found in file")
        }

        guard let (tracksSize, _) = findElement(withID: EBML.tracksID) as? (UInt64, UInt32) else {
            throw macSubtitleOCRError.invalidInputFile("MKV tracks element not found in file")
        }

        let endOfTracksOffset = fileHandle.offsetInFile + tracksSize

        var subtitleTracks = [Int: String]()
        while fileHandle.offsetInFile < endOfTracksOffset, let (elementID, elementSize) = tryParseElement() {
            if elementID == EBML.trackEntryID {
                logger.debug("Found TrackEntry element")
                let endOfEntryOffset = fileHandle.offsetInFile + elementSize
                if let track = parseTrackEntry(for: codecs, until: endOfEntryOffset) {
                    subtitleTracks[track.0] = track.1
                }
                fileHandle.seek(toFileOffset: endOfEntryOffset)
            } else if elementID == EBML.chapters {
                break
            } else {
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
        }

        // Go through the tracks by number, as dictionary order changes from run to run.
        let trackData = extractTrackData(for: subtitleTracks) ?? [:]
        for (trackNumber, data) in trackData.sorted(by: { $0.key < $1.key }) {
            if data.isEmpty {
                print("Found empty track data for track \(trackNumber), skipping track!")
                continue
            }
            tracks.append(MKVTrack(
                trackNumber: trackNumber,
                codecID: subtitleTracks[trackNumber]!,
                trackData: data,
                idxData: codecPrivate[trackNumber],
                language: languages[trackNumber]))
        }
    }

    func extractTrackData(for tracks: [Int: String]) -> [Int: Data]? {
        fileHandle.seek(toFileOffset: 0)

        // Step 1: Locate the Segment element
        guard let segmentSize = locateSegment() else { return nil }
        let segmentDataOffset = fileHandle.offsetInFile
        let segmentEndOffset = segmentDataOffset + segmentSize
        logger.debug("Found Segment, Size: \(segmentSize), End Offset: \(segmentEndOffset)")

        timestampScale = readTimestampScale(segmentDataOffset: segmentDataOffset, segmentEndOffset: segmentEndOffset)
            ?? defaultTimestampScale
        // swiftformat:disable:next redundantSelf
        logger.debug("Timestamp scale: \(self.timestampScale) ns")
        fileHandle.seek(toFileOffset: segmentDataOffset)

        var trackData = [Int: Data]()

        // Step 2: Parse Clusters within the Segment
        while fileHandle.offsetInFile < segmentEndOffset {
            let startOffset = fileHandle.offsetInFile
            defer {
                // Stop rather than spin if an iteration read nothing.
                if fileHandle.offsetInFile <= startOffset {
                    fileHandle.seek(toFileOffset: segmentEndOffset)
                }
            }

            guard let clusterSize = locateCluster() else { break }
            let clusterEndOffset = fileHandle.offsetInFile + clusterSize
            // Whatever stops the reading of the Cluster, go on from its end, or from the next Cluster.
            defer { resumeAfterCluster(endingAt: clusterEndOffset, before: min(segmentEndOffset, endOfFile)) }

            // Step 3: Extract the cluster timestamp
            guard let clusterTimestamp = extractClusterTimestamp() else {
                logger.warning("Failed to extract cluster timestamp, skipping cluster.")
                continue
            }

            // Step 4: Parse Blocks (SimpleBlock or Block) within each Cluster
            parseBlocks(until: clusterEndOffset, for: tracks, with: clusterTimestamp, into: &trackData)
        }

        return trackData
    }

    // MARK: - Methods

    /// Leaves the file at the end of a Cluster whose reading has stopped, for whatever reason, so that the
    /// elements after it are read from their start.
    ///
    /// A Cluster whose size is known ends at that size. One of unknown size, or one whose size runs to or past
    /// the end of the file, ends at the next Cluster: if the file is not already at one, the Cluster was cut
    /// short by damage, and the next Cluster ID before `endOffset` is searched for byte by byte.
    private func resumeAfterCluster(endingAt clusterEndOffset: UInt64, before endOffset: UInt64) {
        // tryParseElement cuts an unknown size, or one past the end of the file, at the end of the file.
        guard clusterEndOffset >= endOfFile else {
            fileHandle.seek(toFileOffset: clusterEndOffset)
            return
        }

        let offset = fileHandle.offsetInFile
        guard offset < endOffset else { return }
        if tryParseElement()?.elementID == EBML.cluster {
            fileHandle.seek(toFileOffset: offset)
            return
        }
        logger.debug("Cluster of unknown size stopped at \(offset), searching for the next Cluster")
        fileHandle.seek(toFileOffset: findNextCluster(from: offset + 1, before: endOffset) ?? endOffset)
    }

    /// Returns the offset of the first well-formed Cluster header whose ID lies between `startOffset` and
    /// `endOffset`, found by its ID at any byte offset, or `nil` if there is none.
    private func findNextCluster(from startOffset: UInt64, before endOffset: UInt64) -> UInt64? {
        let clusterID = withUnsafeBytes(of: EBML.cluster.bigEndian) { Data($0) }
        let chunkSize: UInt64 = 1 << 16
        var chunkOffset = startOffset
        while chunkOffset < endOffset {
            fileHandle.seek(toFileOffset: chunkOffset)
            let chunk = fileHandle.readData(ofLength: Int(min(chunkSize, endOffset - chunkOffset)))
            guard chunk.count >= clusterID.count else { return nil }

            var searchStart = chunk.startIndex
            while let match = chunk.range(of: clusterID, in: searchStart ..< chunk.endIndex) {
                let candidate = chunkOffset + UInt64(match.lowerBound - chunk.startIndex)
                fileHandle.seek(toFileOffset: candidate)
                if tryParseElement() != nil {
                    logger.debug("Found Cluster at \(candidate)")
                    return candidate
                }
                searchStart = match.lowerBound + 1
            }
            // Keep the last bytes of the chunk, as an ID may start in them.
            chunkOffset += UInt64(chunk.count - (clusterID.count - 1))
        }
        return nil
    }

    /// Reads every child of a TrackEntry, which may come in any order, and records the track's language and
    /// VobSub index once the whole entry is read.
    private func parseTrackEntry(for codecs: [String], until endOfEntryOffset: UInt64) -> (Int, String)? {
        var trackNumber: Int?
        var codecID: String?
        var language: String?
        var languageBCP47: String?
        var privateData: String?

        while fileHandle.offsetInFile < endOfEntryOffset, let (elementID, elementSize) = tryParseElement() {
            let endOfElementOffset = fileHandle.offsetInFile + elementSize
            switch elementID {
            case EBML.trackNumberID:
                trackNumber = readUnsignedInteger(ofSize: elementSize).flatMap { $0 > 0 ? Int(exactly: $0) : nil }
                logger.debug("Found track number: \(String(describing: trackNumber))")
            case EBML.trackTypeID: // Unused by us, left for debugging
                let trackType = readUnsignedInteger(ofSize: elementSize)
                logger.debug("Found track type: \(String(describing: trackType))")
            case EBML.codecID:
                codecID = readString(ofSize: elementSize)
                logger.debug("Found codec ID: \(String(describing: codecID))")
            case EBML.language:
                language = readString(ofSize: elementSize)
                logger.debug("Found language: \(String(describing: language))")
            case EBML.languageBCP47:
                languageBCP47 = readString(ofSize: elementSize)
                logger.debug("Found BCP 47 language: \(String(describing: languageBCP47))")
            case EBML.codecPrivate:
                privateData = readString(ofSize: elementSize)
            default:
                break
            }
            fileHandle.seek(toFileOffset: endOfElementOffset)
        }

        guard let trackNumber, let codecID else { return nil }

        // LanguageBCP47 takes precedence over Language when both are present.
        let trackLanguage = languageBCP47 ?? language
        languages[trackNumber] = trackLanguage

        if codecID == "S_VOBSUB", let privateData {
            var idx = "# VobSub index file, v7 (do not modify this line!)\n" + privateData
            if let trackLanguage {
                idx.append("langidx: 0\n")
                idx.append("\nid: \(trackLanguage), index: 0")
            }
            codecPrivate[trackNumber] = idx
        }

        if codecs.contains(codecID) {
            return (trackNumber, codecID)
        }
        if codecID.hasPrefix("S_") {
            skippedSubtitleCodecs.append(codecID)
        }
        return nil
    }

    /// Reads TimestampScale from the Segment Info, or returns `nil` if there is none or it is zero. Leaves
    /// the file offset at the start of the Segment data.
    ///
    /// Info usually comes before the first Cluster, but may be anywhere in the Segment. Past the first
    /// Cluster, the Info entry of a SeekHead found before it is followed if there is one; otherwise, or if it
    /// does not lead to Info, the top-level elements are skipped one by one by their sizes until Info is
    /// found. A Cluster of unknown size cannot be skipped, so the search stops there.
    private func readTimestampScale(segmentDataOffset: UInt64, segmentEndOffset: UInt64) -> UInt64? {
        defer { fileHandle.seek(toFileOffset: segmentDataOffset) }
        let endOffset = min(segmentEndOffset, endOfFile)
        var infoSeekPosition: UInt64?
        var passedCluster = false

        fileHandle.seek(toFileOffset: segmentDataOffset)
        while fileHandle.offsetInFile < endOffset, let (elementID, elementSize) = ebmlParser.readEBMLElement() {
            let dataOffset = fileHandle.offsetInFile
            switch elementID {
            case EBML.segmentInfo:
                let endOfInfoOffset = min(dataOffset + (elementSize ?? endOffset), endOffset)
                return readTimestampScale(until: endOfInfoOffset)
            case EBML.seekHead where !passedCluster && infoSeekPosition == nil:
                if let elementSize {
                    infoSeekPosition = readInfoSeekPosition(until: min(dataOffset + elementSize, endOffset))
                }
            case EBML.cluster where !passedCluster:
                passedCluster = true
                if let infoSeekPosition,
                   let scale = readTimestampScale(atSeekPosition: infoSeekPosition,
                                                  segmentDataOffset: segmentDataOffset, endOffset: endOffset) {
                    return scale
                }
            default:
                break
            }
            guard let elementSize else {
                logger.debug("Element \(elementID.hex()) of unknown size before Segment Info, using default scale")
                return nil
            }
            fileHandle.seek(toFileOffset: dataOffset + elementSize)
        }
        return nil
    }

    /// Reads TimestampScale from the Info element that a SeekHead places at `seekPosition` bytes into the
    /// Segment data, or returns `nil` if there is no Info element there.
    private func readTimestampScale(atSeekPosition seekPosition: UInt64, segmentDataOffset: UInt64,
                                    endOffset: UInt64) -> UInt64? {
        let (infoOffset, overflow) = segmentDataOffset.addingReportingOverflow(seekPosition)
        guard !overflow, infoOffset < endOffset else {
            logger.debug("SeekHead Info position \(seekPosition) is past the end of the Segment")
            return nil
        }
        fileHandle.seek(toFileOffset: infoOffset)
        guard let (elementID, elementSize) = ebmlParser.readEBMLElement(), elementID == EBML.segmentInfo else {
            logger.debug("SeekHead Info position \(seekPosition) does not hold Segment Info")
            return nil
        }
        let dataOffset = fileHandle.offsetInFile
        return readTimestampScale(until: min(dataOffset + (elementSize ?? endOffset), endOffset))
    }

    /// Reads the children of a Segment Info element up to `endOfInfoOffset` and returns its TimestampScale,
    /// or `nil` if there is none or it is zero.
    private func readTimestampScale(until endOfInfoOffset: UInt64) -> UInt64? {
        while fileHandle.offsetInFile < endOfInfoOffset, let (elementID, elementSize) = tryParseElement() {
            let endOfElementOffset = fileHandle.offsetInFile + elementSize
            if elementID == EBML.timestampScale {
                return readUnsignedInteger(ofSize: elementSize).flatMap { $0 > 0 ? $0 : nil }
            }
            fileHandle.seek(toFileOffset: endOfElementOffset)
        }
        return nil
    }

    /// Reads the Seek entries of a SeekHead up to `endOfSeekHeadOffset` and returns the SeekPosition of the
    /// one for the Segment Info, or `nil` if there is none.
    private func readInfoSeekPosition(until endOfSeekHeadOffset: UInt64) -> UInt64? {
        while fileHandle.offsetInFile < endOfSeekHeadOffset, let (elementID, elementSize) = tryParseElement() {
            let endOfSeekOffset = min(fileHandle.offsetInFile + elementSize, endOfSeekHeadOffset)
            if elementID == EBML.seek {
                var seekID: UInt64?
                var seekPosition: UInt64?
                while fileHandle.offsetInFile < endOfSeekOffset, let (childID, childSize) = tryParseElement() {
                    let endOfChildOffset = fileHandle.offsetInFile + childSize
                    if childID == EBML.seekID {
                        seekID = readUnsignedInteger(ofSize: childSize)
                    } else if childID == EBML.seekPosition {
                        seekPosition = readUnsignedInteger(ofSize: childSize)
                    }
                    fileHandle.seek(toFileOffset: endOfChildOffset)
                }
                if seekID == UInt64(EBML.segmentInfo), let seekPosition {
                    return seekPosition
                }
            }
            fileHandle.seek(toFileOffset: endOfSeekOffset)
        }
        return nil
    }

    /// Reads an EBML unsigned integer element of `size` bytes, or returns `nil` if it is empty or too wide.
    private func readUnsignedInteger(ofSize size: UInt64) -> UInt64? {
        guard (1 ... 8).contains(size) else { return nil }
        let data = fileHandle.readData(ofLength: Int(size))
        guard data.count == Int(size) else { return nil }
        return data.reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Reads an ASCII string element of `size` bytes, dropping any null padding.
    private func readString(ofSize size: UInt64) -> String? {
        var data = fileHandle.readData(ofLength: Int(size))
        data.removeNullBytes()
        return String(data: data, encoding: .ascii)
    }

    /// Reads the Cluster Timestamp, an unsigned integer, or returns `nil` if it is missing or wider than 8 bytes.
    private func extractClusterTimestamp() -> UInt64? {
        guard let (timestampElementSize, _) = findElement(withID: EBML.timestamp) as? (UInt64, UInt32) else {
            return nil
        }
        let endOfElementOffset = fileHandle.offsetInFile + timestampElementSize
        guard timestampElementSize <= 8,
              let timestamp = readFixedLengthNumber(fileHandle: fileHandle, length: Int(timestampElementSize))
        else {
            fileHandle.seek(toFileOffset: endOfElementOffset)
            return nil
        }
        return timestamp
    }

    private func parseBlocks(until clusterEndOffset: UInt64, for tracks: [Int: String], with clusterTimestamp: UInt64,
                             into trackData: inout [Int: Data]) {
        // A Block must end within its Cluster, which may itself be cut short by the end of the file.
        let endOffset = min(clusterEndOffset, endOfFile)
        while fileHandle.offsetInFile < clusterEndOffset {
            // swiftformat:disable:next redundantSelf
            logger.debug("Looking for Block at Offset: \(self.fileHandle.offsetInFile)/\(clusterEndOffset)")

            guard let (blockSize, blockStartOffset, groupEndOffset) = findBlockTypeAndSize(until: endOffset)
            else { break }

            // A Block must also end within its BlockGroup, when the end of the group is known.
            let blockLimit = groupEndOffset ?? endOffset
            let (blockEndOffset, overflow) = blockStartOffset.addingReportingOverflow(blockSize)
            guard !overflow, blockEndOffset <= blockLimit else {
                logger.debug("Block at \(blockStartOffset) of size \(blockSize) runs past its parent, skipping")
                fileHandle.seek(toFileOffset: groupEndOffset ?? max(endOffset, blockStartOffset))
                continue
            }

            // The header of track number, timestamp and flags must fit in the block, or the block is skipped.
            guard let (blockTrackNumber, blockTimestamp) = readTrackNumber(from: fileHandle),
                  fileHandle.offsetInFile <= blockEndOffset,
                  let payloadSize = Int(exactly: blockEndOffset - fileHandle.offsetInFile)
            else {
                logger.debug("Block at \(blockStartOffset) of size \(blockSize) is too short for its header, skipping")
                fileHandle.seek(toFileOffset: groupEndOffset ?? blockEndOffset)
                continue
            }

            if tracks[blockTrackNumber] == "S_HDMV/PGS" {
                handlePGSBlock(for: blockTrackNumber, with: blockTimestamp, payloadSize, clusterTimestamp, &trackData)
            } else if tracks[blockTrackNumber] == "S_VOBSUB" {
                handleVobSubBlock(for: blockTrackNumber, with: blockTimestamp, payloadSize, clusterTimestamp, &trackData)
            }
            // Skip the rest of the block, all of it if it is for a different track, and the rest of its group.
            fileHandle.seek(toFileOffset: groupEndOffset ?? blockEndOffset)
        }
    }

    private func handlePGSBlock(for trackNumber: Int, with blockTimestamp: Int16, _ payloadSize: Int,
                                _ clusterTimestamp: UInt64, _ trackData: inout [Int: Data]) {
        let absPTS = calculateAbsolutePTS(clusterTimestamp, blockTimestamp, timestampScale: timestampScale)
        let pgsPTS = encodePTSForPGS(absPTS)
        let pgsHeader = Data([0x50, 0x47] + pgsPTS + [0x00, 0x00, 0x00, 0x00])

        let raw = fileHandle.readData(ofLength: payloadSize)
        var blockData = Data()
        blockData.reserveCapacity(raw.count)

        var offset = 0
        while (offset + 3) <= raw.count, let declaredSize = raw.getUInt16BE(at: offset + 1) {
            let segmentSize = min(Int(declaredSize) + 3, raw.count - offset)
            logger.debug("Segment size \(segmentSize) at \(offset) type \(raw[offset].hex())")

            blockData.append(pgsHeader)
            blockData.append(raw.subdata(in: offset ..< segmentSize + offset))
            offset += segmentSize
        }

        trackData[trackNumber, default: Data()].append(blockData)
    }

    private func handleVobSubBlock(for trackNumber: Int, with blockTimestamp: Int16, _ payloadSize: Int,
                                   _ clusterTimestamp: UInt64, _ trackData: inout [Int: Data]) {
        let absolutePTS = calculateAbsolutePTS(clusterTimestamp, blockTimestamp, timestampScale: timestampScale)
        let vobSubPTS = encodePTSForVobSub(from: absolutePTS)

        var segmentSize = payloadSize
        let packHeader = vobSubPackHeader(systemClockReference: absolutePTS)
        var buffer = buildVobSubHeader(packHeader: packHeader, pts: vobSubPTS, segmentSize: segmentSize)

        buffer.append(fileHandle.readData(ofLength: min(segmentSize, 2019)))
        segmentSize -= min(segmentSize, 2019)

        appendVobSubSegments(packHeader: packHeader, segmentSize: segmentSize, buffer: &buffer)

        trackData[trackNumber, default: Data()].append(buffer)

        let offset = String(format: "%09X", trackData[trackNumber, default: Data()].count - buffer.count)
        codecPrivate[trackNumber]?.append("\ntimestamp: \(formatTime(absolutePTS)), filepos: \(offset)")
    }

    // swiftformat:disable all
    private func buildVobSubHeader(packHeader: [UInt8], pts: [UInt8], segmentSize: Int) -> Data {
        // PES length includes the flags, header length, PTS and stream ID after it.
        let pesLength = withUnsafeBytes(of: UInt16(min(segmentSize, 2019) + 9).bigEndian) { Array($0) }
        var vobSubHeader = Data()
        vobSubHeader.reserveCapacity(segmentSize + 512)
        vobSubHeader = Data(packHeader)                               // PS pack header
        vobSubHeader.append(contentsOf: [0x00, 0x00, 0x01, 0xBD])     // PES packet start code
        vobSubHeader.append(contentsOf: pesLength)                    // PES packet length
        vobSubHeader.append(contentsOf: [0x81,                        // MPEG-2 PES flags, original
                                         0x80,                        // PTS DTS flag
                                         UInt8(pts.count)])           // PTS data length
        vobSubHeader.append(contentsOf: pts)                          // PTS data
        vobSubHeader.append(contentsOf: [vobSubSubstreamID])          // Subpicture stream ID
        return vobSubHeader
    }

    private func appendVobSubSegments(packHeader: [UInt8], segmentSize: Int, buffer: inout Data) {
        var remainingSize = segmentSize
        while remainingSize > 0 {
            // Continuation packets have three header bytes and a stream ID.
            let nextSegmentSize = min(remainingSize, 2024) + 4
            let pesLength = withUnsafeBytes(of: UInt16(nextSegmentSize).bigEndian) { Array($0) }
            buffer.append(contentsOf: packHeader)                           // PS pack header
            buffer.append(contentsOf: [0x00, 0x00, 0x01, 0xBD])             // PES packet start code
            buffer.append(contentsOf: pesLength)                            // PES packet length
            buffer.append(contentsOf: [0x81,                                // MPEG-2 PES flags, original
                                       0x00,                                // PTS DTS flag
                                       0x00])                               // PTS data length
            buffer.append(contentsOf: [vobSubSubstreamID])                  // Subpicture stream ID
            buffer.append(fileHandle.readData(ofLength: min(remainingSize, 2024)))
            remainingSize -= min(remainingSize, 2024)
        }
    }
    // swiftformat:enable all

    /// Finds the next SimpleBlock, or the Block of the next BlockGroup, before `endOffset`, leaving the file at
    /// the start of the block's data. Returns the block's size and data offset, and the end of its BlockGroup
    /// when it is in one whose end is known.
    ///
    /// A BlockGroup with no Block is skipped. The Block is searched for only within its group, which ends at
    /// its size or at `endOffset`, whichever is first. A group of unknown size, or one whose size runs to or
    /// past the end of the file, has no known end, so it also ends at the first element that cannot be in a
    /// BlockGroup, and the search goes on from that element.
    ///
    /// BlockDuration is passed over, as are the group's other children.
    private func findBlockTypeAndSize(until endOffset: UInt64)
        -> (blockSize: UInt64, blockStartOffset: UInt64, groupEndOffset: UInt64?)? {
        while fileHandle.offsetInFile < endOffset {
            guard case let (elementSize?, elementID?) = findElement(withID: EBML.simpleBlock, EBML.blockGroup)
            else { return nil }
            let dataOffset = fileHandle.offsetInFile
            guard elementID == EBML.blockGroup else { return (elementSize, dataOffset, nil) }

            // tryParseElement cuts an unknown size, or one past the end of the file, at the end of the file.
            let hasKnownEnd = dataOffset + elementSize < endOfFile
            let groupEndOffset = max(min(dataOffset + elementSize, endOffset), dataOffset)
            if let blockSize = findBlock(until: groupEndOffset, stopAtNonChild: !hasKnownEnd) {
                return (blockSize, fileHandle.offsetInFile, hasKnownEnd ? groupEndOffset : nil)
            }
            logger.debug("BlockGroup at \(dataOffset) has no Block, skipping")
            if hasKnownEnd {
                fileHandle.seek(toFileOffset: groupEndOffset)
            }
        }
        return nil
    }

    /// Reads the children of a BlockGroup up to `groupEndOffset` and returns the size of its Block, leaving the
    /// file at the start of the Block's data, or returns `nil` if there is no Block. If `stopAtNonChild`, the
    /// group ends before the first element that cannot be in a BlockGroup, and the file is left there.
    private func findBlock(until groupEndOffset: UInt64, stopAtNonChild: Bool) -> UInt64? {
        while fileHandle.offsetInFile < groupEndOffset {
            let childOffset = fileHandle.offsetInFile
            guard let (childID, childSize) = tryParseElement() else { return nil }
            if childID == EBML.block {
                return childSize
            }
            if stopAtNonChild, !EBML.blockGroupChildren.contains(childID) {
                fileHandle.seek(toFileOffset: childOffset)
                return nil
            }
            fileHandle.seek(toFileOffset: fileHandle.offsetInFile + childSize)
        }
        return nil
    }

    /// Reads the track number and timestamp from a Block or SimpleBlock header, leaving the file at the end of
    /// the header, or returns `nil` if the file ends first or the track number is malformed.
    ///
    /// The lacing bits of the flags are logged but not acted on: a laced block, which holds several frames, is
    /// read as one frame. Subtitle tracks are not laced in practice.
    private func readTrackNumber(from fileHandle: FileHandle) -> (trackNumber: Int, timestamp: Int16)? {
        // A VINT is at most eight bytes, so its value, less the length marker, always fits in Int.
        guard let trackNumber = ebmlParser.readVINT(elementSize: true).map(Int.init),
              // The timestamp is a signed 16-bit offset from the cluster timestamp.
              let timestamp = readFixedLengthNumber(fileHandle: fileHandle, length: 2).map(Int16.init(truncatingIfNeeded:)),
              let flags = fileHandle.readData(ofLength: 1).first
        else { return nil }

        let lacingFlag = (flags >> 1) & 0x03 // Bits 1 and 2 are the lacing type
        logger.debug("Track number: \(trackNumber), Timestamp: \(timestamp), Lacing type: \(lacingFlag)")
        return (trackNumber, timestamp)
    }
}
