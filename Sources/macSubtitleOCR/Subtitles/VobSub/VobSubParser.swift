//
// VobSubParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/4/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct VobSubParser {
    // MARK: - Properties

    let subtitle: Subtitle
    private let masterPalette: [UInt8]

    // MARK: - Lifecycle

    init(index: Int, buffer: UnsafeRawBufferPointer, timestamp: TimeInterval, offset: UInt64,
         nextOffset: UInt64, idxPalette: [UInt8]) throws {
        subtitle = Subtitle(index: index, startTimestamp: timestamp, imageData: .init(), numberOfColors: 16)
        masterPalette = idxPalette
        try readSubFrame(buffer: buffer, offset: offset, nextOffset: nextOffset)
        try decodeImage()
        try decodePalette()
    }

    // MARK: - Methods

    func readSubFrame(buffer: UnsafeRawBufferPointer, offset: UInt64, nextOffset: UInt64) throws {
        var firstPacketFound = false
        var controlOffset: Int?
        var controlSize: Int?
        var controlHeaderCopied = 0
        var controlHeader = Data()
        var relativeControlOffset = 0
        var rleLengthFound = 0

        var offset = Int(offset)
        repeat {
            let startOffset = offset
            guard buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian == MPEG2PacketType.psPacket else {
                print("No VobSub PS packet at offset \(offset), trying to decode anyway")
                break
            }
            offset += 4

            offset += 6 // System clock reference
            offset += 3 // Multiplexer rate
            let stuffingLength = buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self) & 7
            offset += 1 + Int(stuffingLength)

            guard buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian == MPEG2PacketType.pesPacket
            else {
                print("No VobSub PES packet at offset \(offset), trying to decode anyway")
                break
            }
            offset += 4

            let pesLength = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian)
            if pesLength == 0 {
                throw macSubtitleOCRError.invalidInputFile("VobSub PES packet length is 0 at offset: \(offset)")
            }
            offset += 2
            let nextPSOffset = offset + pesLength

            offset += 1 // Skip PES miscellaneous data
            let extByteOne = buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
            offset += 1
            // The PTS flag, not the header length, says whether a timestamp is present: a packet
            // continuing a subpicture may pad its header with 0xFF stuffing bytes instead.
            let firstPacket = (extByteOne & 0x80) == 0x80

            let ptsDataLength = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
            offset += 1
            if firstPacket, ptsDataLength >= 5 {
                var presentationTimestamp: UInt64 = 0
                presentationTimestamp = UInt64(buffer[offset + 4]) >> 1
                presentationTimestamp += UInt64(buffer[offset + 3]) << 7
                presentationTimestamp += UInt64(buffer[offset + 2] & 0xFE) << 14
                presentationTimestamp += UInt64(buffer[offset + 1]) << 22
                presentationTimestamp += UInt64(buffer[offset] & 0x0E) << 29
                subtitle.startTimestamp = TimeInterval(presentationTimestamp) / 90000
            }
            offset += ptsDataLength

            offset += 1 // Stream ID

            var trueHeaderSize = offset - startOffset
            if firstPacket, ptsDataLength >= 5 {
                let size = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian)
                offset += 2
                relativeControlOffset = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian)
                offset += 2
                let rleSize = relativeControlOffset - 4
                controlSize = size - rleSize - 4 // 4 bytes for the size and control offset
                controlOffset = offset + rleSize
                trueHeaderSize = offset - startOffset
                firstPacketFound = true
            } else if firstPacketFound {
                controlOffset! += trueHeaderSize
            }

            let difference = max(0, nextPSOffset - controlOffset! - controlHeaderCopied)
            let rleFragmentSize = nextPSOffset - offset - difference
            subtitle.imageData!.append(contentsOf: buffer[offset ..< offset + rleFragmentSize])
            rleLengthFound += rleFragmentSize
            offset += rleFragmentSize

            let bytesToCopy = difference <= 0 ? 0 : min(difference, controlSize! - controlHeaderCopied)
            controlHeader.append(contentsOf: buffer[offset ..< offset + bytesToCopy])
            controlHeaderCopied += bytesToCopy

            offset = nextPSOffset
        } while offset < nextOffset && controlHeaderCopied < controlSize!

        if controlHeaderCopied < controlSize! {
            print("Failed to read control header completely, \(controlHeaderCopied)/\(controlSize!), errors may occur")
            for _ in controlHeaderCopied ..< controlSize! {
                controlHeader.append(0xFF)
            }
        }

        parseControlSequences(controlHeader, offset: relativeControlOffset)
    }

    /// Walk the subpicture's chain of control sequences, as ffmpeg's `decode_dvd_subtitles` does.
    ///
    /// Each sequence is a delay, the offset of the next sequence, and commands ending in 0xFF;
    /// the last sequence points at itself. `header` holds the bytes from `controlStart`, the
    /// offset of the first sequence within the subpicture. The start and stop display commands
    /// usually sit in different sequences, so reading only the first loses the end time.
    private func parseControlSequences(_ header: Data, offset controlStart: Int) {
        let presented = subtitle.startTimestamp!
        var sequence = controlStart
        while true {
            let local = sequence - controlStart
            guard local >= 0, let date = header.getUInt16BE(at: local),
                  let next = header.getUInt16BE(at: local + 2) else {
                print("Control sequence for subtitle \(subtitle.index) lies outside its header, errors may occur")
                return
            }
            // A delay counts in units of 1024/90000 s from the presentation timestamp. ffmpeg
            // rounds it down to whole milliseconds; the shift needs more than the 16 bits it is read in.
            let delay = TimeInterval((Int(date) << 10) / 90) / 1000
            parseCommands(header, from: local + 4, at: presented + delay)
            let nextSequence = Int(next)
            if nextSequence == sequence {
                return
            }
            if nextSequence < sequence {
                print("Invalid control sequence offset for subtitle \(subtitle.index), errors may occur")
                return
            }
            sequence = nextSequence
        }
    }

    /// Apply one control sequence's commands, which take effect at `time`.
    ///
    /// The image is taken from the first sequence that describes it, since a later one
    /// only repeats it or changes its contrast to fade it.
    private func parseCommands(_ header: Data, from start: Int, at time: TimeInterval) {
        var index = start
        while index < header.count {
            let command = header[index]
            index += 1
            let operands = [0x03: 2, 0x04: 2, 0x05: 6, 0x06: 4][command] ?? 0
            guard index + operands <= header.count else {
                print("Control command \(command) for subtitle \(subtitle.index) is truncated, errors may occur")
                return
            }
            switch command {
            case 0x00:
                break // Forced display: shown whatever the player's subtitle setting.
            case 0x01:
                subtitle.startTimestamp = time
            case 0x02:
                subtitle.endTimestamp = time
            case 0x03:
                if subtitle.imagePalette == nil {
                    subtitle.imagePalette = [
                        header[index + 1] & 0x0F,
                        header[index + 1] >> 4,
                        header[index] & 0x0F,
                        header[index] >> 4
                    ]
                }
            case 0x04:
                if subtitle.imageAlpha == nil {
                    subtitle.imageAlpha = [
                        header[index + 1] & 0x0F,
                        header[index + 1] >> 4,
                        header[index] & 0x0F,
                        header[index] >> 4
                    ]
                }
            case 0x05:
                if subtitle.imageXOffset == nil, subtitle.imageYOffset == nil {
                    subtitle.imageXOffset = Int(header[index]) << 4 | Int(header[index + 1] >> 4)
                    subtitle.imageWidth = (Int(header[index + 1] & 0x0F) << 8 | Int(header[index + 2]))
                        - subtitle.imageXOffset! + 1
                    subtitle.imageYOffset = Int(header[index + 3]) << 4 | Int(header[index + 4] >> 4)
                    subtitle.imageHeight = (Int(header[index + 4] & 0x0F) << 8 | Int(header[index + 5]))
                        - subtitle.imageYOffset! + 1
                }
            case 0x06:
                if subtitle.evenOffset == nil, subtitle.oddOffset == nil {
                    subtitle.evenOffset = Int(header.getUInt16BE(at: index)!) - 4
                    subtitle.oddOffset = Int(header.getUInt16BE(at: index + 2)!) - 4
                }
            default:
                return // 0xFF ends the sequence; like ffmpeg, so does a command it does not know.
            }
            index += operands
        }
    }

    private func decodePalette() throws {
        guard subtitle.imagePalette != nil, subtitle.imageAlpha != nil else {
            throw macSubtitleOCRError.fileReadError("Failed to read image palette and alpha")
        }

        var palette = [UInt8](repeating: 0, count: 4 * 4)

        for i in 0 ..< 4 {
            let index = subtitle.imagePalette![i]
            palette[4 * i] = masterPalette[3 * Int(index)]
            palette[4 * i + 1] = masterPalette[3 * Int(index) + 1]
            palette[4 * i + 2] = masterPalette[3 * Int(index) + 2]
            palette[4 * i + 3] = UInt8(subtitle.imageAlpha![i] * 0x11)
        }

        subtitle.imagePalette = palette
    }

    private func decodeImage() throws {
        let rleData = RLEData(
            data: subtitle.imageData ?? Data(),
            width: subtitle.imageWidth ?? 0,
            height: subtitle.imageHeight ?? 0,
            evenOffset: subtitle.evenOffset ?? 0,
            oddOffset: subtitle.oddOffset ?? 0)
        subtitle.imageData = try rleData.decodeVobSub()
    }
}
