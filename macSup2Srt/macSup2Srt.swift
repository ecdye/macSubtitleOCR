//
//  macSup2Srt.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/1/2024.
//  Copyright © 2024 Ethan Dye. All rights reserved.
//

import ArgumentParser
import Cocoa
import UniformTypeIdentifiers
import Vision

/// The main struct representing the macSup2Srt command-line tool.
@main
struct macSup2Srt: ParsableCommand {
    // MARK: - Arguments / Options

    @Argument(help: "Input .sup subtitle file.")
    var sup: String

    @Argument(help: "File to output the OCR direct output in json to.")
    var json: String

    @Argument(help: "File to output the completed .srt file to")
    var srt: String

    @Option(help: "Output image files of subtitles to directory (optional)")
    var imageDirectory: String?

    @Option(wrappedValue: "en", help: "The input image language(s)")
    var language: String

    @Flag(help: "Enable fast mode (less accurate).")
    var fastMode = false

    @Flag(help: "Enable language correction.")
    var languageCorrection = false

    // MARK: - Methods

    /// The main entry point of the command-line tool.
    func run() throws {
        // Set the text recognition mode
        var recognitionLevel = VNRequestTextRecognitionLevel.accurate
        var subtitleDat: [Any] = []
        var srtFile: [SrtSubtitle] = []
        var subtitleIndex = 1

        // Split the language string into an array of languages
        let languages = language.split(separator: ",").map { String($0) }

        // Set the fast mode if applicable
        if fastMode {
            recognitionLevel = .fast
        }

        // Set the text recognition revision
        var revision: Int
        if #available(macOS 13, *) {
            revision = VNRecognizeTextRequestRevision3
        } else {
            revision = VNRecognizeTextRequestRevision2
        }

        // Initialize the decoder
        let PGS = PGS()
        let subtitles = try PGS.parseSupFile(fromFileAt: URL(fileURLWithPath: sup))

        for var subtitle in subtitles {
            if subtitle.imageWidth == 0 && subtitle.imageHeight == 0 {
                continue // Ignore empty image
            }
            guard let subImage = PGS.createImage(from: &subtitle)
            else {
                print("Could not create image from decoded data for index \(subtitleIndex)! Skipping...")
                continue
            }

            // Save subtitle image as PNG if imageDirectory is provided
            if let imageDirectory = imageDirectory {
                let outputDirectory = URL(fileURLWithPath: imageDirectory)
                let manager = FileManager.default
                do {
                    try manager.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: false,
                                                attributes: nil)
                } catch CocoaError.fileWriteFileExists {
                    // Folder already existed
                } catch {
                    throw error
                }
                let pngPath = outputDirectory.appendingPathComponent("subtitle_\(subtitleIndex).png")

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

                let subtitleData: [String: Any] = ["image": subtitleIndex,
                                                   "lines": subtitleLines,
                                                   "text": subtitleText]

                subtitleDat.append(subtitleData)

                let newSubtitle = SrtSubtitle(index: subtitleIndex,
                                              startTime: subtitle.timestamp,
                                              endTime: subtitle.endTimestamp,
                                              text: subtitleText)

                srtFile.append(newSubtitle)
            }

            request.recognitionLevel = recognitionLevel
            request.usesLanguageCorrection = languageCorrection
            request.revision = revision
            request.recognitionLanguages = languages

            try? VNImageRequestHandler(cgImage: subImage, options: [:]).perform([request])

            subtitleIndex += 1
        }

        // Convert subtitle data to JSON
        let jsonData = try JSONSerialization.data(withJSONObject: subtitleDat,
                                                  options: [.prettyPrinted, .sortedKeys])
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

        // Write JSON to file
        try jsonString.write(to: URL(fileURLWithPath: json),
                             atomically: true,
                             encoding: .utf8)

        // Encode subtitles to SRT file
        try SRT().encode(subtitles: srtFile,
                         toFileAt: URL(fileURLWithPath: srt))
    }
}
