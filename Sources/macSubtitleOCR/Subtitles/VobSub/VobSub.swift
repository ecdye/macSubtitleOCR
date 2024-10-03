//
// VobSub.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/30/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
import ImageIO
import os

class VobSub {
    struct IdxSubtitleReference {
        let timestamp: TimeInterval
        let offset: Int
    }

    // MARK: - Properties

    private var subtitles = [Subtitle]()

    // MARK: - Lifecycle

    init(_ sub: String, _ idx: String) throws {
        try decodeVobSub(subFilePath: sub, idxFilePath: idx)
    }

    // MARK: - Getters

    func getSubtitles() -> [Subtitle] {
        subtitles
    }

    var idxPalette = [UInt8]()
    var logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "VobSub")
    private var stderr = StandardErrorOutputStream()

    func readVobSubFiles(subFileURL: URL, idxFilePath: String) -> (FileHandle, String)? {
        do {
            let fileHandle = try FileHandle(forReadingFrom: subFileURL)
            let idxData = try String(contentsOf: URL(fileURLWithPath: idxFilePath), encoding: .utf8)
            return (fileHandle, idxData)
        } catch {
            return nil
        }
    }

    func parseIdxFile(idxData: String) throws -> [IdxSubtitleReference] {
        var subtitles = [IdxSubtitleReference]()
        let lines = idxData.split(separator: "\n")
        let timestampRegex = try NSRegularExpression(pattern: "timestamp: (\\d{2}:\\d{2}:\\d{2}:\\d{3})")
        let offsetRegex = try NSRegularExpression(pattern: "filepos: (\\w+)")

        for line in lines {
            if line.starts(with: "palette:") {
                let entries = line.split(separator: ", ").map { String($0) }
                for entry in entries {
                    idxPalette.append(contentsOf: entry.hexToBytes)
                }
            }
            if line.starts(with: "timestamp:") {
                let timestampMatch = timestampRegex.firstMatch(in: String(line), options: [], range: NSRange(location: 0, length: line.count))
                let offsetMatch = offsetRegex.firstMatch(in: String(line), options: [], range: NSRange(location: 0, length: line.count))

                if let timestampMatch, let offsetMatch {
                    let timestampString = (line as NSString).substring(with: timestampMatch.range(at: 1))
                    let timestamp = extractTimestamp(from: timestampString)
                    let offsetString = (line as NSString).substring(with: offsetMatch.range(at: 1))
                    if let offset = Int(offsetString, radix: 16), let timestamp {
                        subtitles.append(IdxSubtitleReference(timestamp: timestamp, offset: offset))
                    }
                }
            }
        }
        return subtitles
    }

    func extractTimestamp(from idxTimestamp: String) -> TimeInterval? {
        // Split the timestamp into components (hours, minutes, seconds, milliseconds)
        let components = idxTimestamp.split(separator: ":")

        // Ensure we have exactly 4 components (hh:mm:ss:ms)
        guard components.count == 4,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]),
              let milliseconds = Double(components[3])
        else {
            return nil
        }

        // Convert everything to seconds
        let totalSeconds = (hours * 3600) + (minutes * 60) + seconds + (milliseconds / 1000)

        return totalSeconds
    }

    func extractSubtitleImages(subFile: FileHandle, idxReference: [IdxSubtitleReference]) throws {
        var idx = 0
        for subtitle in idxReference {
            let offset = UInt64(subtitle.offset)
            var nextOffset: UInt64
            if idx + 1 < idxReference.count {
                nextOffset = UInt64(idxReference[idx + 1].offset)
            } else {
                let currentOffset = subFile.offsetInFile
                nextOffset = subFile.seekToEndOfFile()
                subFile.seek(toFileOffset: currentOffset)
            }
            var pic = Subtitle(startTimestamp: subtitle.timestamp, endTimestamp: 0, imageData: .init(), numberOfColors: 16)
            try readSubFrame(pic: &pic, subFile: subFile, offset: offset, nextOffset: nextOffset, idxPalette: idxPalette)
            logger.debug("Found image at offset \(subtitle.offset) with timestamp \(subtitle.timestamp)")
            logger.debug("Image size: \(pic.imageWidth!) x \(pic.imageHeight!)")
            subtitles.append(pic)
            idx += 1
        }
    }

    func decodeVobSub(subFilePath: String, idxFilePath: String) throws {
        guard let (subFile, idxData) = readVobSubFiles(subFileURL: URL(filePath: subFilePath), idxFilePath: idxFilePath) else {
            print("Error: Failed to read files", to: &stderr)
            return
        }
        let subtitles = try parseIdxFile(idxData: idxData)
        try extractSubtitleImages(subFile: subFile, idxReference: subtitles)
    }
}
