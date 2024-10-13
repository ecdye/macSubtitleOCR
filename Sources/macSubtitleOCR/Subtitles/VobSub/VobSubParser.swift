//
// VobSubParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/4/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct VobSubParser {
    // MARK: - Properties

    private let logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "VobSubParser")
    private(set) var subtitle: Subtitle = .init(imageData: .init(), numberOfColors: 16)
    private let masterPalette: [UInt8]
    private let fps = 24.0 // TODO: Make this configurable / dynamic

    // MARK: - Lifecycle

    init(subFile: FileHandle, timestamp: TimeInterval, offset: UInt64, nextOffset: UInt64, idxPalette: [UInt8]) {
        masterPalette = idxPalette
        subtitle.startTimestamp = timestamp
        readSubFrame(subFile: subFile, offset: offset, nextOffset: nextOffset, idxPalette: idxPalette)
        decodeImage()
        decodePalette()
    }

    // MARK: - Methods

    func readSubFrame(subFile: FileHandle, offset: UInt64, nextOffset: UInt64, idxPalette _: [UInt8]) {
        var firstPacketFound = false
        var controlOffset: Int?
        var controlSize: Int?
        var controlHeaderCopied = 0
        var controlHeader = Data()
        var relativeControlOffset = 0
        var rleLengthFound = 0

        subFile.seek(toFileOffset: offset)
        repeat {
            let startOffset = subFile.offsetInFile
            guard subFile.readData(ofLength: 4).value(ofType: UInt32.self) == MPEG2PacketType.psPacket else {
                fatalError("Failed to find PS packet at offset \(subFile.offsetInFile)")
            }

            subFile.readData(ofLength: 6) // System clock reference
            subFile.readData(ofLength: 3) // Multiplexer rate
            let stuffingLength = Int(subFile.readData(ofLength: 1)[0] & 7)
            subFile.readData(ofLength: stuffingLength) // Stuffing bytes

            guard subFile.readData(ofLength: 4).value(ofType: UInt32.self) == MPEG2PacketType.pesPacket else {
                fatalError("Failed to find PES packet at offset \(subFile.offsetInFile)")
            }

            let pesLength = Int(subFile.readData(ofLength: 2).value(ofType: UInt16.self) ?? 0)
            if pesLength == 0 {
                fatalError("PES packet length is 0 at offset \(subFile.offsetInFile)")
            }
            let nextPSOffset = subFile.offsetInFile + UInt64(pesLength)

            subFile.readData(ofLength: 1) // Skip PES miscellaneous data
            let extByteOne = subFile.readData(ofLength: 1)[0]
            let firstPacket = (extByteOne & 0x80) == 0x80 || (extByteOne & 0xC0) == 0xC0

            let ptsDataLength = Int(subFile.readData(ofLength: 1)[0])
            let ptsData = subFile.readData(ofLength: ptsDataLength)
            if ptsDataLength == 5 {
                var presentationTimestamp: UInt64 = 0
                presentationTimestamp = UInt64(ptsData[4]) >> 1
                presentationTimestamp += UInt64(ptsData[3]) << 7
                presentationTimestamp += UInt64(ptsData[2] & 0xFE) << 14
                presentationTimestamp += UInt64(ptsData[1]) << 22
                presentationTimestamp += UInt64(ptsData[0] & 0x0E) << 29
                subtitle.startTimestamp = TimeInterval(presentationTimestamp) / 90 / 1000
                logger.debug("Got \(subtitle.startTimestamp!) as timestamp")
            }

            subFile.readData(ofLength: 1) // Stream ID

            var trueHeaderSize = Int(subFile.offsetInFile - startOffset)
            if firstPacket, ptsDataLength >= 5 {
                let size = Int(subFile.readData(ofLength: 2).value(ofType: UInt16.self) ?? 0)
                relativeControlOffset = Int(subFile.readData(ofLength: 2).value(ofType: UInt16.self) ?? 0)
                let rleSize = relativeControlOffset - 2
                controlSize = size - rleSize - 4 // 4 bytes for the size and control offset
                controlOffset = Int(subFile.offsetInFile) + rleSize
                trueHeaderSize = Int(subFile.offsetInFile - startOffset)
                firstPacketFound = true
            } else if firstPacketFound {
                controlOffset! += trueHeaderSize
            }

            let savedOffset = subFile.offsetInFile
            let difference = max(0, Int(nextPSOffset) - controlOffset! - controlHeaderCopied)
            let rleFragmentSize = Int(nextPSOffset - savedOffset) - difference
            subtitle.imageData!.append(subFile.readData(ofLength: rleFragmentSize))
            rleLengthFound += rleFragmentSize

            let bytesToCopy = max(0, min(difference, controlSize! - controlHeaderCopied))
            controlHeader.append(subFile.readData(ofLength: bytesToCopy))
            controlHeaderCopied += bytesToCopy

            subFile.seek(toFileOffset: nextPSOffset)
        } while subFile.offsetInFile < nextOffset && controlHeaderCopied < controlSize!

        if controlHeaderCopied < controlSize! {
            logger.warning("Failed to read control header completely")
            for _ in controlHeaderCopied ..< controlSize! {
                controlHeader.append(0xFF)
            }
        }

        parseCommandHeader(controlHeader, offset: relativeControlOffset)
    }

    private func parseCommandHeader(_ header: Data, offset: Int) {
        let relativeEndTimestamp = TimeInterval(Int(header.value(ofType: UInt16.self)!)) * 1024 / 90000 / fps
        let endOfControl = Int(header.value(ofType: UInt16.self)!) - 4 - offset
        subtitle.endTimestamp = subtitle.startTimestamp! + relativeEndTimestamp

        var index = 2

        while index < endOfControl {
            let command = header[index]
            index += 1

            switch command {
            case 0:
                break // Set subtitle as forced
            case 1, 2:
                // Start and stop display commands
                break
            case 3:
                var byte = header[index]
                index += 1
                if subtitle.imagePalette == nil {
                    subtitle.imagePalette = [UInt8](repeating: 0, count: 4)
                }
                subtitle.imagePalette![3] = byte >> 4
                subtitle.imagePalette![2] = byte & 0x0F
                byte = header[index]
                index += 1
                subtitle.imagePalette![1] = byte >> 4
                subtitle.imagePalette![0] = byte & 0x0F
            case 4:
                var byte = header[index]
                index += 1
                if subtitle.imageAlpha == nil {
                    subtitle.imageAlpha = [UInt8](repeating: 0, count: 4)
                } else {
                    // If the alpha is already set, don't overwrite it. This typically happens when fade in/out is used.
                    index += 1
                    break
                }
                subtitle.imageAlpha![3] = byte >> 4
                subtitle.imageAlpha![2] = byte & 0x0F
                byte = header[index]
                index += 1
                subtitle.imageAlpha![1] = byte >> 4
                subtitle.imageAlpha![0] = byte & 0x0F
                logger.debug("Alpha: \(subtitle.imageAlpha!)")
            case 5:
                if subtitle.imageXOffset != nil || subtitle.imageYOffset != nil {
                    break // Don't overwrite the offsets if they're already set, only happens in bad files
                }
                subtitle.imageXOffset = Int(header[index]) << 4 | Int(header[index + 1] >> 4)
                subtitle.imageWidth = (Int(header[index + 1] & 0x0F) << 8 | Int(header[index + 2])) - subtitle
                    .imageXOffset! + 1
                index += 3
                subtitle.imageYOffset = Int(header[index]) << 4 | Int(header[index + 1] >> 4)
                subtitle.imageHeight = (Int(header[index + 1] & 0x0F) << 8 | Int(header[index + 2])) - subtitle
                    .imageYOffset! + 1
                index += 3
                logger.debug("Image size: \(subtitle.imageWidth!)x\(subtitle.imageHeight!)")
                logger.debug("X Offset: \(subtitle.imageXOffset!), Y Offset: \(subtitle.imageYOffset!)")
            case 6:
                subtitle.evenOffset = Int(header.value(ofType: UInt16.self, at: index)! - 4)
                subtitle.oddOffset = Int(header.value(ofType: UInt16.self, at: index + 2)! - 4)
                index += 4
                logger.debug("Even offset: \(subtitle.evenOffset!), Odd offset: \(subtitle.oddOffset!)")
            default:
                break
            }
        }
    }

    private func decodePalette() {
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

    private func decodeImage() {
        var rleData = RLEData(
            data: subtitle.imageData ?? Data(),
            width: subtitle.imageWidth ?? 0,
            height: subtitle.imageHeight ?? 0,
            evenOffset: subtitle.evenOffset ?? 0,
            oddOffset: subtitle.oddOffset ?? 0)
        subtitle.imageData = rleData.decodeVobSub()
    }
}
