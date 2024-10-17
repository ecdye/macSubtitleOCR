//
// FileHandler.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

struct FileHandler {
    let outputDirectory: String

    init(outputDirectory: String) {
        self.outputDirectory = outputDirectory
    }

    func saveSRTFile(for result: macSubtitleOCRResult) throws {
        let srtFilePath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("track_\(result.trackNumber).srt")
        let srt = SRT(subtitles: result.srt.values.sorted { $0.index! < $1.index! })
        srt.write(toFileAt: srtFilePath)
    }

    func saveJSONFile(for result: macSubtitleOCRResult) throws {
        let jsonResults = result.json.values.sorted { $0.image < $1.image }.map { jsonResult in
            [
                "image": jsonResult.image,
                "lines": jsonResult.lines.map { line in
                    [
                        "text": line.text,
                        "confidence": line.confidence,
                        "x": line.x,
                        "width": line.width,
                        "y": line.y,
                        "height": line.height
                    ] as [String: Any]
                },
                "text": jsonResult.text
            ] as [String: Any]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: jsonResults, options: [.prettyPrinted, .sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
        let jsonFilePath = URL(fileURLWithPath: outputDirectory).appendingPathComponent("track_\(result.trackNumber).json")
        try jsonString.write(to: jsonFilePath, atomically: true, encoding: .utf8)
    }
}
