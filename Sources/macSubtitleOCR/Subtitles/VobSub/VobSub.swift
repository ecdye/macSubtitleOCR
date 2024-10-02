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

    func parseIdxFile(idxData: String) -> [IdxSubtitleReference] {
        var subtitles = [IdxSubtitleReference]()
        let lines = idxData.split(separator: "\n")
        let timestampRegex: NSRegularExpression
        let offsetRegex: NSRegularExpression
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss:SSS"
        do {
            timestampRegex = try NSRegularExpression(pattern: "timestamp: (\\d{2}:\\d{2}:\\d{2}:\\d{3})")
            offsetRegex = try NSRegularExpression(pattern: "filepos: (\\w+)")
        } catch {
            print("Error: Failed to create regular expressions: \(error)", to: &stderr)
            return []
        }

        for line in lines {
            if line.starts(with: "palette:") {
                let entries = line.split(separator: ", ").map { String($0) }
                for entry in entries {
                    print(entry.hexToBytes)
                    idxPalette.append(contentsOf: entry.hexToBytes)
                }
            }
            if line.starts(with: "timestamp:") {
                let timestampMatch = timestampRegex.firstMatch(in: String(line), options: [], range: NSRange(location: 0, length: line.count))
                let offsetMatch = offsetRegex.firstMatch(in: String(line), options: [], range: NSRange(location: 0, length: line.count))

                if let timestampMatch, let offsetMatch {
                    let timestampString = (line as NSString).substring(with: timestampMatch.range(at: 1))
                    let timestamp = dateFormatter.date(from: timestampString)?.timeIntervalSinceReferenceDate
                    let offsetString = (line as NSString).substring(with: offsetMatch.range(at: 1))
                    if let offset = Int(offsetString, radix: 16), let timestamp {
                        subtitles.append(IdxSubtitleReference(timestamp: timestamp, offset: offset))
                    }
                }
            }
        }
        return subtitles
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
        let subtitles = parseIdxFile(idxData: idxData)
        try extractSubtitleImages(subFile: subFile, idxReference: subtitles)
    }
}
