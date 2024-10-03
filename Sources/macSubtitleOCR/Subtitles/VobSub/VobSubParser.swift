//
// VobSubParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/30/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
import os

func readSubFrame(pic: inout Subtitle, subFile: FileHandle, offset: UInt64, nextOffset: UInt64, idxPalette: [UInt8]) throws {
    let logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "VobSub")
    var firstPacketFound = false
    var controlOffset: Int?
    var controlSize: Int?
    var controlHeaderCopied = 0
    var controlHeader = Data()
    var relativeControlOffset = 0
    var rleLengthFound = 0

    // logger.info("Reading subtitle frame at offset \(offset) with next offset \(nextOffset)")
    print("Reading subtitle frame at offset \(offset) with next offset \(nextOffset)")
    subFile.seek(toFileOffset: offset)
    repeat {
        let startOffset = subFile.offsetInFile
        // Read the first 4 bytes to find the PS packet
        guard subFile.readData(ofLength: 4).value(ofType: UInt32.self, at: 0) == MPEG2PacketType.psPacket else {
            fatalError("Error: Failed to find PS packet at offset \(subFile.offsetInFile)")
        }
        logger.debug("Found PS packet at offset \(subFile.offsetInFile)")

        subFile.readData(ofLength: 6) // System clock reference
        subFile.readData(ofLength: 3) // Multiplexer rate
        let stuffingLength = Int(subFile.readData(ofLength: 1)[0] & 7)
        subFile.readData(ofLength: stuffingLength) // Stuffing bytes
        logger.debug("Skipped \(stuffingLength) stuffing bytes")
        let psHeaderLength = subFile.offsetInFile - startOffset
        logger.debug("PS header length: \(psHeaderLength)")

        // Read the next 4 bytes to find the pes packet
        guard subFile.readData(ofLength: 4).value(ofType: UInt32.self, at: 0) == MPEG2PacketType.pesPacket else {
            fatalError("Error: Failed to find PES packet at offset \(subFile.offsetInFile)")
        }
        logger.debug("Found PES packet at offset \(subFile.offsetInFile)")

        // Read the PES packet length
        let pesLength = Int(subFile.readData(ofLength: 2).value(ofType: UInt16.self, at: 0) ?? 0)
        if pesLength == 0 {
            fatalError("Error: PES packet length is 0 at offset \(subFile.offsetInFile)")
        }
        let nextPSOffset = subFile.offsetInFile + UInt64(pesLength)
        let pesHeaderLength = subFile.offsetInFile - startOffset
        logger.debug("PES packet length: \(pesLength), Next PES packet offset: \(nextPSOffset), PS header length: \(pesHeaderLength)")

        let extByteOne = subFile.readData(ofLength: 1)[0]
        let firstPacket = (extByteOne >> 2 & 0x01) == 0
        logger.debug("firstPacket: \(firstPacket)")

        subFile.readData(ofLength: 1) // PTS DTS flags
        let ptsDataLength = Int(subFile.readData(ofLength: 1)[0])
        subFile.readData(ofLength: ptsDataLength) // Skip PES Header data bytes
        logger.debug("Skipped \(ptsDataLength) PTS bytes")

        let streamID = Int(subFile.readData(ofLength: 1)[0] - 0x20)
        logger.debug("Stream ID: \(streamID)")

        var trueHeaderSize = Int(subFile.offsetInFile - startOffset)
        if firstPacket, ptsDataLength >= 5 {
            let size = Int(subFile.readData(ofLength: 2).value(ofType: UInt16.self, at: 0) ?? 0)
            relativeControlOffset = Int(subFile.readData(ofLength: 2).value(ofType: UInt16.self, at: 0) ?? 0)
            let rleSize = relativeControlOffset - 2
            controlSize = size - rleSize - 4 // 4 bytes for the size and control offset
            logger.debug("Size: \(size), RLE Size: \(rleSize), Control Size: \(controlSize!)")

            controlOffset = Int(subFile.offsetInFile) + rleSize
            trueHeaderSize = Int(subFile.offsetInFile - startOffset)
            firstPacketFound = true
        } else if firstPacketFound {
            controlOffset! += trueHeaderSize
        }

        let savedOffset = subFile.offsetInFile
        let difference = max(0, Int(nextPSOffset) - controlOffset! - controlHeaderCopied)
        let copied = controlHeaderCopied
        var i = 0
        subFile.seek(toFileOffset: UInt64(controlOffset! + i + copied))
        while i < difference, controlHeaderCopied < controlSize! {
            controlHeader.append(subFile.readData(ofLength: 1)[0])
            controlHeaderCopied += 1
            i += 1
        }
        logger.debug("Obtained \(controlHeaderCopied) of \(controlSize!) bytes of control header")

        let rleFragmentSize = Int(nextPSOffset - savedOffset) - difference
        subFile.seek(toFileOffset: savedOffset)
        pic.imageData!.append(subFile.readData(ofLength: rleFragmentSize))
        rleLengthFound += rleFragmentSize
        logger.debug("RLE fragment size: \(rleFragmentSize), Total RLE length: \(rleLengthFound)")

        subFile.seek(toFileOffset: nextPSOffset)
    } while subFile.offsetInFile < nextOffset && controlHeaderCopied < controlSize!

    if controlHeaderCopied < controlSize! {
        logger.warning("Failed to read control header completely")
        for _ in controlHeaderCopied ..< controlSize! {
            controlHeader.append(0xFF)
        }
    }

    var index = 0
    var endOfControl = Int(controlHeader.value(ofType: UInt16.self, at: index)!) - relativeControlOffset - 4
    if endOfControl < 0 || endOfControl > controlSize! {
        logger.warning("Invalid control header size \(endOfControl). Setting to \(controlSize!)")
        endOfControl = Int(controlSize!)
    }
    index += 2

    var alphaSum = 0
    while index < endOfControl {
        let command = controlHeader[index]
        index += 1

        switch command {
        case 0:
            break // Set subtitle as forced
        case 1:
            break // Start display
        case 3:
            var byte = controlHeader[index]
            index += 1
            if pic.imagePalette == nil {
                pic.imagePalette = [UInt8](repeating: 0, count: 4)
            }
            pic.imagePalette![3] = byte >> 4
            pic.imagePalette![2] = byte & 0x0F
            byte = controlHeader[index]
            index += 1
            pic.imagePalette![1] = byte >> 4
            pic.imagePalette![0] = byte & 0x0F
            let palette = pic.imagePalette!
            logger.debug("Palette: \(palette)")
        case 4:
            var byte = controlHeader[index]
            index += 1
            if pic.imageAlpha == nil {
                pic.imageAlpha = [UInt8](repeating: 0, count: 4)
            }
            pic.imageAlpha![3] = byte >> 4
            pic.imageAlpha![2] = byte & 0x0F
            byte = controlHeader[index]
            index += 1
            pic.imageAlpha![1] = byte >> 4
            pic.imageAlpha![0] = byte & 0x0F
            for i in 0 ..< 4 {
                alphaSum += Int(pic.imageAlpha![i])
            }
            let alpha = pic.imageAlpha!
            logger.debug("Alpha: \(alpha), Alpha sum: \(alphaSum)")
        case 5:
            pic.imageXOffset = Int(controlHeader[index]) << 4 | Int(controlHeader[index + 1] >> 4)
            pic.imageWidth = (Int(controlHeader[index + 1]) & 0x0F) << 8 | Int(controlHeader[index + 2]) - pic.imageXOffset! + 1
            pic.imageStride = pic.imageWidth! + 7 & ~7
            pic.imageYOffset = Int(controlHeader[index + 3]) << 4 | Int(controlHeader[index + 4] >> 4)
            pic.imageHeight = (Int(controlHeader[index + 4]) & 0x0F) << 8 | Int(controlHeader[index + 5]) - pic.imageYOffset! + 1
            index += 6
            let dimensions = (width: pic.imageWidth!, height: pic.imageHeight!)
            logger.debug("Dimensions: width: \(dimensions.width), height: \(dimensions.height)")
        case 6:
            pic.imageEvenOffset = (Int(controlHeader.value(ofType: UInt16.self, at: index)!) - 4)
            pic.imageOddOffset = (Int(controlHeader.value(ofType: UInt16.self, at: index + 2)!) - 4)
            index += 4
            let rleOffsets = (even: pic.imageEvenOffset!, odd: pic.imageOddOffset!)
            logger.debug("RLE Offsets: even: \(rleOffsets.even), odd: \(rleOffsets.odd)")
        case 7:
            break // Color / Alpha updates (not implemented)
        default:
            logger.warning("Unknown control command: \(command). Skipping...")
        }
    }

    pic.imageData = try decodeImage(subtitle: pic, fileBuffer: subFile)
    pic.imagePalette = decodePalette(subPicture: pic, masterPalette: idxPalette)
}

func decodePalette(subPicture: Subtitle, masterPalette: [UInt8]) -> [UInt8] {
    var palette = [UInt8](repeating: 0, count: 4 * 4)

    for i in 0 ..< 4 {
        let index = subPicture.imagePalette![i]
        palette[4 * i] = masterPalette[3 * Int(index)]
        palette[4 * i + 1] = masterPalette[3 * Int(index) + 1]
        palette[4 * i + 2] = masterPalette[3 * Int(index) + 2]
        palette[4 * i + 3] = UInt8(subPicture.imageAlpha![i] * 0x11)
    }

    return palette
}

func decodeImage(subtitle: Subtitle, fileBuffer _: FileHandle) throws -> Data {
    let sizeEven: Int
    let sizeOdd: Int
    let width = subtitle.imageWidth!
    let height = subtitle.imageHeight!
    var bitmap = Data(repeating: 0, count: width * height * subtitle.imageStride!)

    if subtitle.imageOddOffset! > subtitle.imageEvenOffset! {
        sizeEven = subtitle.imageOddOffset! - subtitle.imageEvenOffset!
        sizeOdd = subtitle.imageData!.count - subtitle.imageOddOffset!
    } else {
        sizeOdd = subtitle.imageEvenOffset! - subtitle.imageOddOffset!
        sizeEven = subtitle.imageData!.count - subtitle.imageEvenOffset!
    }

    guard sizeEven > 0, sizeOdd > 0 else {
        throw VobSubError.invalidRLEBufferOffset
    }

    let rleData = RLEData(data: subtitle.imageData!, width: width, height: height)
    bitmap = try rleData.decodeVobSub()

    return bitmap
}
