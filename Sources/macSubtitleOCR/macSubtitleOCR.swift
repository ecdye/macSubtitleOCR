//
// macSup2Srt.swift
// macSup2Srt
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import ArgumentParser
import Cocoa
import os
import UniformTypeIdentifiers
import Vision

// The main struct representing the macSup2Srt command-line tool.
@main
struct macSubtitleOCR: ParsableCommand {
    // MARK: - Properties

    @Argument(help: "Input .sup subtitle file")
    var sup: String

    @Argument(help: "File to output the completed .srt file to")
    var srt: String

    @Option(help: "File to output the OCR direct output in json to (optional)")
    var json: String?

    @Option(help: "Output image files of subtitles to directory (optional)")
    var imageDirectory: String?

    @Option(wrappedValue: "en", help: "The input image language(s)")
    var language: String

    @Flag(help: "Enable fast mode (less accurate)")
    var fastMode = false

    @Flag(help: "Enable language correction")
    var languageCorrection = false

    @Flag(help: "Save extracted `.sup` file to disk (MKV input only)")
    var saveSup: Bool = false

    // MARK: - Entrypoint
    func validate() throws {
                if sup.isEmpty {
                    throw ValidationError("Please provide at least one value to calculate the \(sup).")
                }
            }
    mutating func run() throws {
        // Setup utilities
        let logger = Logger(subsystem: "github.ecdye.macSup2Srt", category: "main")
        let manager = FileManager.default

        // Setup options
        let inFile = self.sup
        let revision = self.setOCRRevision()
        let recognitionLevel = self.setOCRMode()
        let languages = self.language.split(separator: ",").map { String($0) }

        // Setup data variables
        var subIndex = 1
        var jsonStream: [Any] = []
        var inSubStream: [PGSSubtitle]
        var outSubStream: [SrtSubtitle] = []

        if self.sup.hasSuffix(".mkv") {
            let mkvParser = try MKVParser(filePath: sup)
            var trackNumber: Int?
            guard let tracks = mkvParser.parseTracks() else { throw macSup2SrtError.invalidFormat }
            for track in tracks {
                logger.debug("Found subtitle track: \(track.trackNumber), Codec: \(track.codecId)")
                if track.codecId == "S_HDMV/PGS" {
                    trackNumber = track.trackNumber
                    break // TODO: Implement ability to extract all PGS tracks in file
                }
            }
            self.sup = try mkvParser.getSubtitleTrackData(trackNumber: trackNumber!, outPath: self.sup)!
            mkvParser.closeFile()
        }

        // Initialize the decoder
        let PGS = PGS()
        inSubStream = try PGS.parseSupFile(fromFileAt: URL(fileURLWithPath: self.sup))

        for var subtitle in inSubStream {
            if subtitle.imageWidth == 0 && subtitle.imageHeight == 0 {
                logger.debug("Skipping subtitle index \(subIndex) with empty image data!")
                continue
            }

            guard let subImage = PGS.createImage(from: &subtitle)
            else {
                logger.info("Could not create image from decoded data for index \(subIndex)! Skipping...")
                continue
            }

            // Save subtitle image as PNG if imageDirectory is provided
            if let imageDirectory = imageDirectory {
                let outputDirectory = URL(fileURLWithPath: imageDirectory)
                do {
                    try manager.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: false,
                                                attributes: nil)
                } catch CocoaError.fileWriteFileExists {
                    // Folder already existed
                }
                let pngPath = outputDirectory.appendingPathComponent("subtitle_\(subIndex).png")

                try PGS.saveImageAsPNG(image: subImage, outputPath: pngPath)
            }

            // Perform text recognition
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

                var subtitleLines: [[String: Any]] = []
                var subtitleText = ""
                var index = 0
                for observation in observations {
                    let candidate = observation.topCandidates(1).first
                    let string = candidate?.string ?? ""
                    let confidence = candidate?.confidence ?? 0.0
                    let stringRange = string.startIndex ..< string.endIndex
                    let boxObservation = try? candidate?.boundingBox(for: stringRange)
                    let boundingBox = boxObservation?.boundingBox ?? .zero
                    let rect = VNImageRectForNormalizedRect(boundingBox,
                                                            subtitle.imageWidth,
                                                            subtitle.imageHeight)

                    let line: [String: Any] = ["text": string,
                                               "confidence": confidence,
                                               "x": Int(rect.minX),
                                               "width": Int(rect.size.width),
                                               "y": Int(CGFloat(subtitle.imageHeight) - rect.minY - rect
                                                   .size.height),
                                               "height": Int(rect.size.height)]

                    subtitleLines.append(line)
                    subtitleText += string
                    index += 1
                    if index != observations.count {
                        subtitleText += "\n"
                    }
                }

                let subtitleData: [String: Any] = ["image": subIndex,
                                                   "lines": subtitleLines,
                                                   "text": subtitleText]

                jsonStream.append(subtitleData)

                let newSubtitle = SrtSubtitle(index: subIndex,
                                              startTime: subtitle.timestamp,
                                              endTime: subtitle.endTimestamp,
                                              text: subtitleText)

                outSubStream.append(newSubtitle)
            }

            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = self.languageCorrection
            request.revision = revision
            request.recognitionLanguages = languages

            try? VNImageRequestHandler(cgImage: subImage, options: [:]).perform([request])

            subIndex += 1
        }

        if let json = json {
            // Convert subtitle data to JSON
            let jsonData = try JSONSerialization.data(withJSONObject: jsonStream,
                                                      options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

            // Write JSON to file
            try jsonString.write(to: URL(fileURLWithPath: json),
                                 atomically: true,
                                 encoding: .utf8)
        }

        if self.saveSup, inFile.hasSuffix(".mkv") {
            try manager.moveItem(
                at: URL(fileURLWithPath: self.sup),
                to: URL(fileURLWithPath: inFile).deletingPathExtension().appendingPathExtension("sup")
            )
        }

        // Encode subtitles to SRT file
        try SRT().encode(subtitles: outSubStream,
                         toFileAt: URL(fileURLWithPath: self.srt))
    }

    // MARK: - Methods

    private func setOCRMode() -> VNRequestTextRecognitionLevel {
        if self.fastMode {
            return VNRequestTextRecognitionLevel.fast
        } else {
            return VNRequestTextRecognitionLevel.accurate
        }
    }

    private func setOCRRevision() -> Int {
        if #available(macOS 13, *) {
            return VNRecognizeTextRequestRevision3
        } else {
            return VNRecognizeTextRequestRevision2
        }
    }
}
