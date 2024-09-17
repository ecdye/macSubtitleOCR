//
// SRT.swift
// macSup2Srt
//
// Copyright (c) 2024 Ethan Dye
// Created by Ethan Dye on 9/2/24.
//

import Foundation

public class SRT {
    public init() {}

    // MARK: Functions

    // MARK: - Decoding

    // Decodes subtitles from a string containing the SRT content
    public func decode(from content: String) throws -> [SrtSubtitle] {
        var subtitles = [SrtSubtitle]()

        // Split the content by subtitle blocks
        let blocks = content.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.components(separatedBy: .newlines).filter { !$0.isEmpty }

            guard lines.count >= 2 else {
                continue
            }

            // Parse index
            guard let index = Int(lines[0]) else {
                throw SRTError.invalidFormat
            }

            // Parse times
            let timeComponents = lines[1].components(separatedBy: " --> ")
            guard timeComponents.count == 2,
                  let startTime = parseTime(timeComponents[0]),
                  let endTime = parseTime(timeComponents[1])
            else {
                throw SRTError.invalidTimeFormat
            }

            // Combine remaining lines as the subtitle text
            var text = ""
            if lines.count <= 3 {
                text = lines[2...].joined(separator: "\n")
            }

            // Create and append the subtitle
            let subtitle = SrtSubtitle(index: index, startTime: startTime, endTime: endTime, text: text)
            subtitles.append(subtitle)
        }

        return subtitles
    }

    // Decodes subtitles from an SRT file at the given URL
    public func decode(fromFileAt url: URL) throws -> [SrtSubtitle] {
        do {
            // Read the file content into a string
            let content = try String(contentsOf: url, encoding: .utf8)
            // Decode the content into subtitles
            return try self.decode(from: content)
        } catch {
            throw SRTError.fileReadError
        }
    }

    // MARK: - Re-Encoding

    // Re-encodes an array of `Subtitle` objects into SRT format and returns it as a string
    public func encode(subtitles: [SrtSubtitle]) -> String {
        var srtContent = ""

        for subtitle in subtitles {
            let startTime = self.formatTime(subtitle.startTime)
            let endTime = self.formatTime(subtitle.endTime)

            srtContent += "\(subtitle.index)\n"
            srtContent += "\(startTime) --> \(endTime)\n"
            srtContent += "\(subtitle.text)\n\n"
        }

        return srtContent
    }

    // Re-encodes an array of `Subtitle` objects into SRT format and writes it to a file at the given URL
    public func encode(subtitles: [SrtSubtitle], toFileAt url: URL) throws {
        let srtContent = self.encode(subtitles: subtitles)

        do {
            try srtContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw SRTError.fileWriteError
        }
    }

    // MARK: - Helper Methods

    private func parseTime(_ timeString: String) -> TimeInterval? {
        let components = timeString.components(separatedBy: [":", ","])
        guard components.count == 4,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]),
              let milliseconds = Double(components[3])
        else {
            return nil
        }

        return (hours * 3600) + (minutes * 60) + seconds + (milliseconds / 1000)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time - TimeInterval(Int(time))) * 1000)

        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}

public enum SRTError: Error {
    case invalidFormat
    case invalidTimeFormat
    case fileNotFound
    case fileReadError
    case fileWriteError
}
