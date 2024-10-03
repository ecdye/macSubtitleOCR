//
// VobSubIDX.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/2/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

struct VobSubIDX {
    private(set) var timestamps: [TimeInterval] = .init()
    private(set) var offsets: [UInt64] = .init()
    private(set) var palette: [UInt8] = .init()

    init(_ url: URL) {
        let idxData = try! String(contentsOf: url, encoding: .utf8)
        try! parseIdxFile(idxData: idxData)
    }

    mutating func parseIdxFile(idxData: String) throws {
        let lines = idxData.split(separator: "\n")
        let timestampRegex = try NSRegularExpression(pattern: "timestamp: (\\d{2}:\\d{2}:\\d{2}:\\d{3})")
        let offsetRegex = try NSRegularExpression(pattern: "filepos: (\\w+)")

        for line in lines {
            if line.starts(with: "palette:") {
                let entries = line.split(separator: ", ").map { String($0) }
                for entry in entries {
                    palette.append(contentsOf: entry.hexToBytes)
                }
            }
            if line.starts(with: "timestamp:") {
                let timestampMatch = timestampRegex.firstMatch(in: String(line), options: [], range: NSRange(location: 0, length: line.count))
                let offsetMatch = offsetRegex.firstMatch(in: String(line), options: [], range: NSRange(location: 0, length: line.count))

                if let timestampMatch, let offsetMatch {
                    let timestampString = (line as NSString).substring(with: timestampMatch.range(at: 1))
                    let timestamp = extractTimestamp(from: timestampString)
                    let offsetString = (line as NSString).substring(with: offsetMatch.range(at: 1))
                    if let offset = UInt64(offsetString, radix: 16), let timestamp {
                        offsets.append(offset)
                        timestamps.append(timestamp)
                    }
                }
            }
        }
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
}
