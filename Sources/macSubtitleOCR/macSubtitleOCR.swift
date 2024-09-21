//
// macSubtitleOCR.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import ArgumentParser
import Cocoa
import os
import UniformTypeIdentifiers
import Vision

// The main struct representing the macSubtitleOCR command-line tool.
@main
struct macSubtitleOCR: ParsableCommand {
    // MARK: - Properties

    @Argument(help: "Input file containing the subtitle stream (.sup or .mkv)")
    var input: String

    @Argument(help: "Directory to output the completed .srt files to")
    var srtDirectory: String

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

    mutating func run() throws {
        // Setup utilities
        let logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "main")
        let manager = FileManager.default

        // Setup options
        let inFile = input
        let revision = setOCRRevision()
        let recognitionLevel = setOCRMode()
        let languages = language.split(separator: ",").map { String($0) }

        // Setup data variables
        var subIndex = 1
        var jsonStream: [Any] = []
        var srtStreams: [Int: SRT] = [:]
        var intermediateFiles: [Int: String] = [:]

        if input.hasSuffix(".mkv") {
            let mkvStream = try MKVSubtitleExtractor(filePath: input)
            try mkvStream.parseTracks(codec: "S_HDMV/PGS")
            for track in mkvStream.tracks {
                subIndex = 1 // reset counter for each track
                logger.debug("Found subtitle track: \(track.trackNumber), Codec: \(track.codecId)")
                intermediateFiles[track.trackNumber] = try mkvStream.getSubtitleTrackData(trackNumber: track.trackNumber)!

                // Open the PGS data stream
                let PGS = try PGS(URL(fileURLWithPath: intermediateFiles[track.trackNumber]!))

                let srtStream = SRT()
                srtStreams[track.trackNumber] = srtStream

                try processSubtitles(PGS: PGS, srtStream: srtStream, trackNumber: track.trackNumber, subIndex: subIndex, jsonStream: &jsonStream, logger: logger, manager: manager, recognitionLevel: recognitionLevel, languages: languages, revision: revision)
            }
        } else {
            // Open the PGS data stream
            let PGS = try PGS(URL(fileURLWithPath: input))
            let srtStream = SRT()
            srtStreams[0] = srtStream

            try processSubtitles(PGS: PGS, srtStream: srtStream, trackNumber: 0, subIndex: subIndex, jsonStream: &jsonStream, logger: logger, manager: manager, recognitionLevel: recognitionLevel, languages: languages, revision: revision)
        }

        if let json {
            // Convert subtitle data to JSON
            let jsonData = try JSONSerialization.data(withJSONObject: jsonStream, options: [.prettyPrinted, .sortedKeys])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

            // Write JSON to file
            try jsonString.write(to: URL(fileURLWithPath: json),
                                 atomically: true,
                                 encoding: .utf8)
        }

        for (trackNumber, srtStream) in srtStreams {
            let outputDirectory = URL(fileURLWithPath: srtDirectory)
            do {
                try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: false, attributes: nil)
            } catch CocoaError.fileWriteFileExists {
                // Folder already existed
            }
            let srtFilePath = outputDirectory.appendingPathComponent("track_\(trackNumber).srt")
            try srtStream.write(toFileAt: srtFilePath)
            if saveSup, inFile.hasSuffix(".mkv") {
                let fileName = "\(trackNumber)_" + URL(fileURLWithPath: inFile).deletingPathExtension().appendingPathExtension("sup").lastPathComponent
                try manager.moveItem(
                    at: URL(fileURLWithPath: intermediateFiles[trackNumber]!),
                    to: URL(fileURLWithPath: inFile).deletingLastPathComponent().appendingPathComponent(fileName))
            } else {
                try manager.removeItem(at: URL(fileURLWithPath: intermediateFiles[trackNumber]!))
            }
        }
    }

    // MARK: - Methods

    private func setOCRMode() -> VNRequestTextRecognitionLevel {
        if fastMode {
            VNRequestTextRecognitionLevel.fast
        } else {
            VNRequestTextRecognitionLevel.accurate
        }
    }

    private func setOCRRevision() -> Int {
        if #available(macOS 13, *) {
            VNRecognizeTextRequestRevision3
        } else {
            VNRecognizeTextRequestRevision2
        }
    }

    private func saveImageAsPNG(image: CGImage, outputPath: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(outputPath as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw macSubtitleOCRError.fileCreationError
        }
        CGImageDestinationAddImage(destination, image, nil)

        if !CGImageDestinationFinalize(destination) {
            throw macSubtitleOCRError.fileWriteError
        }
    }

    private func processSubtitles(PGS: PGS, srtStream: SRT, trackNumber _: Int, subIndex: Int, jsonStream: inout [Any], logger: Logger, manager: FileManager, recognitionLevel: VNRequestTextRecognitionLevel, languages: [String], revision: Int) throws {
        var subIndex = subIndex
        var inJson = jsonStream
        for subtitle in PGS.getSubtitles() {
            if subtitle.imageWidth == 0, subtitle.imageHeight == 0 {
                logger.debug("Skipping subtitle index \(subIndex) with empty image data!")
                continue
            }

            guard let subImage = PGS.createImage(index: subIndex - 1)
            else {
                logger.info("Could not create image for index \(subIndex)! Skipping...")
                continue
            }

            // Save subtitle image as PNG if imageDirectory is provided
            if let imageDirectory {
                let outputDirectory = URL(fileURLWithPath: imageDirectory)
                do {
                    try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: false, attributes: nil)
                } catch CocoaError.fileWriteFileExists {
                    // Folder already existed
                }
                let pngPath = outputDirectory.appendingPathComponent("subtitle_\(subIndex).png")

                try saveImageAsPNG(image: subImage, outputPath: pngPath)
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
                    let rect = VNImageRectForNormalizedRect(boundingBox, subtitle.imageWidth, subtitle.imageHeight)

                    let line: [String: Any] = [
                        "text": string,
                        "confidence": confidence,
                        "x": Int(rect.minX),
                        "width": Int(rect.size.width),
                        "y": Int(CGFloat(subtitle.imageHeight) - rect.minY - rect.size.height),
                        "height": Int(rect.size.height),
                    ]

                    subtitleLines.append(line)
                    subtitleText += string
                    index += 1
                    if index != observations.count {
                        subtitleText += "\n"
                    }
                }

                let subtitleData: [String: Any] = [
                    "image": subIndex,
                    "lines": subtitleLines,
                    "text": subtitleText,
                ]

                inJson.append(subtitleData)

                srtStream.appendSubtitle(SRTSubtitle(index: subIndex,
                                                     startTime: subtitle.timestamp,
                                                     endTime: subtitle.endTimestamp,
                                                     text: subtitleText))
            }

            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = languageCorrection
            request.revision = revision
            request.recognitionLanguages = languages

            try? VNImageRequestHandler(cgImage: subImage, options: [:]).perform([request])

            subIndex += 1
        }
        jsonStream = inJson
    }
}
