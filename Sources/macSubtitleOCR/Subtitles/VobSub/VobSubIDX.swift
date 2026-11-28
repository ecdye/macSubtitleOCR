//
// VobSubIDX.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/4/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct VobSubIDX {
    private static let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "VobSubIDX")

    // MARK: - Properties

    /// One subtitle stream of the idx: an `id:` block and the `timestamp:` lines under it.
    struct Stream {
        /// The `index:` of the stream's `id:` line. Its packets in the `.sub` carry substream ID `0x20 + index`.
        let index: Int
        var language: String?
        /// Each subtitle's time, with the `delay:` in effect for it already added.
        var timestamps: [TimeInterval] = []
        var offsets: [UInt64] = []
        /// The `delay:` in effect for each subtitle, in seconds.
        var delays: [TimeInterval] = []
    }

    /// Every stream the idx declares or lists timestamps for, in the order they first appear.
    ///
    /// A VobSubRip idx often holds several languages, each in its own `id:` block, all sharing one
    /// `.sub`. Timestamps before any `id:` line belong to stream 0, and an `id:` line repeating an
    /// earlier index continues that stream, as in FFmpeg.
    private(set) var streams: [Stream] = []
    /// The 16 RGB colors of the `palette:` line, 3 bytes each, or nil when the idx has none.
    ///
    /// Read as FFmpeg reads it, so a line with fewer than 16 colors leaves the rest black.
    private(set) var palette: [UInt8]?

    /// The timestamps of the first stream, for an idx holding a single one.
    var timestamps: [TimeInterval] {
        streams.first?.timestamps ?? []
    }

    /// The file positions of the first stream, for an idx holding a single one.
    var offsets: [UInt64] {
        streams.first?.offsets ?? []
    }

    /// The language of the first stream, for an idx holding a single one.
    var language: String? {
        streams.first?.language
    }

    // MARK: - Lifecycle

    init(_ url: URL) throws {
        do {
            let idxData = try String(contentsOf: url, encoding: .utf8)
            parseIdxFile(idxData: idxData)
        } catch {
            throw macSubtitleOCRError.fileReadError("Failed to parse IDX file: \(error)")
        }
    }

    init(_ idxData: String) throws {
        parseIdxFile(idxData: idxData)
    }

    // MARK: - Methods

    private mutating func parseIdxFile(idxData: String) {
        let lines = idxData.split(separator: "\n")
        var current: Int?
        var delay = 0

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.starts(with: "palette:") {
                palette = parsePalette(trimmedLine.dropFirst("palette:".count))
            } else if trimmedLine.starts(with: "id:") {
                let position = stream(at: extractStreamIndex(from: trimmedLine))
                if streams[position].language == nil {
                    streams[position].language = extractLanguage(from: trimmedLine)
                }
                current = position
            } else if trimmedLine.starts(with: "delay:") {
                if let parsed = extractDelay(from: trimmedLine) {
                    delay = parsed
                } else {
                    Self.logger.debug("Ignoring out-of-range VobSub delay: \(trimmedLine)")
                }
            } else if trimmedLine.starts(with: "timestamp:") {
                guard let timestamp = extractTimestamp(from: trimmedLine),
                      let offset = extractOffset(from: trimmedLine)
                else {
                    continue
                }
                let position = current ?? stream(at: 0)
                current = position
                let seconds = TimeInterval(delay) / 1000
                streams[position].offsets.append(offset)
                streams[position].timestamps.append(timestamp + seconds)
                streams[position].delays.append(seconds)
            }
        }
    }

    /// The position in `streams` of the stream with `index`, adding it if it is not there yet.
    private mutating func stream(at index: Int) -> Int {
        if let position = streams.firstIndex(where: { $0.index == index }) {
            return position
        }
        streams.append(Stream(index: index))
        return streams.count - 1
    }

    /// Extract the stream index from a line like "id: en, index: 0".
    ///
    /// A line without one is taken as index 0, as FFmpeg does. Substream IDs leave room for 32
    /// streams; a larger index is kept here, and `VobSub` reports that stream alone as unreadable
    /// rather than rejecting the whole idx.
    private func extractStreamIndex(from line: String) -> Int {
        guard let range = line.range(of: "index:") else { return 0 }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return Int(value.prefix { $0.isNumber }) ?? 0
    }

    /// Extract the delay in milliseconds from a line like "delay: -00:00:01:500".
    ///
    /// Read as FFmpeg's `vobsub_read_header` reads it: an optional sign, then up to four
    /// colon-separated fields of hours, minutes, seconds and milliseconds, any missing ones 0.
    /// Each `delay:` line replaces the one before it, rather than adding to it, and applies to
    /// every timestamp after it, in whatever stream, until the next.
    ///
    /// FFmpeg reads each field into a C `int`, so a field too large for 32 bits has no defined
    /// value there. Such a line gives nil here, and the caller keeps the delay already in effect.
    /// With every field within 32 bits, the total stays far inside 64 bits.
    private func extractDelay(from line: String) -> Int? {
        var value = line.dropFirst("delay:".count).drop { $0 == " " || $0 == "\t" }
        var sign = 1
        if let first = value.first, first == "-" || first == "+" {
            sign = first == "-" ? -1 : 1
            value = value.dropFirst()
        }
        var fields = [0, 0, 0, 0]
        for (position, field) in value.split(separator: ":", omittingEmptySubsequences: false).prefix(4)
            .enumerated() {
            let text = field.trimmingCharacters(in: .whitespaces)
            guard let number = Int32(text) else {
                if isInteger(text) {
                    return nil
                }
                break
            }
            fields[position] = Int(number)
        }
        return ((fields[0] * 3600 + fields[1] * 60 + fields[2]) * 1000 + fields[3]) * sign
    }

    /// Whether `text` is a whole number, with an optional sign, however many digits it has.
    private func isInteger(_ text: String) -> Bool {
        let digits = text.first == "-" || text.first == "+" ? text.dropFirst() : Substring(text)
        return !digits.isEmpty && digits.allSatisfy { ("0" ... "9").contains($0) }
    }

    /// Extract the language from a line like "id: en, index: 0"
    private func extractLanguage(from line: String) -> String? {
        let value = line.dropFirst("id:".count)
        let id = value.prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    /// Extract timestamp from a line starting with "timestamp:"
    private func extractTimestamp(from line: String) -> TimeInterval? {
        guard line.starts(with: "timestamp:") else { return nil }

        // Split line by " " to get timestamp part
        let components = line.split(separator: " ")
        guard components.count > 1 else { return nil }

        var timestampString = components[1]
        if timestampString.hasSuffix(",") {
            timestampString = timestampString.dropLast()
        }
        return convertTimestampToTimeInterval(String(timestampString))
    }

    /// Extract file offset from a line starting with "filepos:"
    private func extractOffset(from line: String) -> UInt64? {
        guard let fileposRange = line.range(of: "filepos:") else { return nil }

        let offsetString = line[fileposRange.upperBound...].trimmingCharacters(in: .whitespaces)
        return UInt64(offsetString, radix: 16) // Convert hex string to UInt64
    }

    /// Convert "hh:mm:ss:ms" timestamp string to TimeInterval (seconds)
    ///
    /// A field such as `inf`, `nan` or `1e999`, or one so large that the total is not finite,
    /// gives nil, and the line is skipped like any other unreadable one.
    private func convertTimestampToTimeInterval(_ timestamp: String) -> TimeInterval? {
        let components = timestamp.split(separator: ":")

        guard components.count == 4,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]),
              let milliseconds = Double(components[3])
        else {
            return nil
        }

        let total = (hours * 3600) + (minutes * 60) + seconds + (milliseconds / 1000)
        return total.isFinite ? total : nil
    }

    /// Read the colors of a `palette:` line as FFmpeg's `ff_dvdsub_parse_palette` does.
    ///
    /// It always reads 16 colors, each with `strtoul` in base 16 followed by any commas and spaces
    /// after it. A missing color reads as 0, black. Text that is not a hex number also reads as 0 and
    /// is not skipped, so every color after it is black too. Only the low 24 bits of each are kept.
    private func parsePalette(_ text: Substring) -> [UInt8] {
        String(text).withCString { start in
            var position = UnsafeMutablePointer(mutating: start)
            var palette = [UInt8]()
            palette.reserveCapacity(48)
            for _ in 0 ..< 16 {
                var end: UnsafeMutablePointer<CChar>?
                let color = UInt32(truncatingIfNeeded: strtoul(position, &end, 16))
                position = end ?? position
                palette += [UInt8(color >> 16 & 0xFF), UInt8(color >> 8 & 0xFF), UInt8(color & 0xFF)]
                // A comma, or a space as av_isspace counts them.
                while position.pointee == 0x2C || position.pointee == 0x20 || (0x09 ... 0x0D).contains(position.pointee) {
                    position += 1
                }
            }
            return palette
        }
    }
}
