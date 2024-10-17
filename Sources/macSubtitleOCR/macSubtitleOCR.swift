//
// macSubtitleOCR.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import ArgumentParser
import os
import UniformTypeIdentifiers
import Vision

private let logger: Logger = .init(subsystem: "github.ecdye.macSubtitleOCR", category: "main")

// The main struct representing the macSubtitleOCR command-line tool.
@main
struct macSubtitleOCR: AsyncParsableCommand {
    // MARK: - Properties

    @Argument(help: "Input file containing the subtitle stream (.sup, .sub, .idx, or .mkv)")
    var input: String

    @Argument(help: "Directory to output files to")
    var outputDirectory: String

    @Option(wrappedValue: "en", help: "The input image language(s)")
    var language: String

    @Flag(help: "Use internal decoder (experimental)")
    var internalDecoder = false

    @Flag(help: "Save image files for subtitle track (optional)")
    var saveImages = false

    @Flag(help: "Save the raw json results from OCR (optional)")
    var json = false

    @Flag(help: "Enable fast mode (less accurate)")
    var fastMode = false

    @Flag(help: "Disable language correction (less accurate)")
    var disableLanguageCorrection = false

    @Flag(help: "Force old API (VNRecognizeTextRequest)")
    var forceOldAPI = false

    @Flag(help: "Save extracted subtitle file to disk (MKV input only)")
    var saveSubtitleFile = false

    // MARK: - Entrypoint

    func run() async throws {
        let fileManager = FileManager.default
        var intermediateFiles: [Int: String] = [:]
        var results: [macSubtitleOCRResult] = []
        let outputDirectory = URL(fileURLWithPath: outputDirectory)

        if internalDecoder {
            if input.hasSuffix(".sub") || input.hasSuffix(".idx") {
                let sub = try VobSub(
                    input.replacingOccurrences(of: ".idx", with: ".sub"),
                    input.replacingOccurrences(of: ".sub", with: ".idx"))
                let result = try await processSubtitles(subtitles: sub.subtitles, trackNumber: 0)
                results.append(result)
            } else if input.hasSuffix(".mkv") {
                let mkvStream = MKVSubtitleExtractor(filePath: input)
                try mkvStream.parseTracks(codec: "S_HDMV/PGS")
                for track in mkvStream.tracks {
                    logger.debug("Found subtitle track: \(track.trackNumber), Codec: \(track.codecId)")
                    if saveSubtitleFile {
                        intermediateFiles[track.trackNumber] = try mkvStream.getSubtitleTrackData(
                            trackNumber: track.trackNumber,
                            outputDirectory: outputDirectory)!
                    }

                    // Open the PGS data stream
                    let PGS = try PGS(mkvStream.tracks[track.trackNumber].trackData)

                    let result = try await processSubtitles(subtitles: PGS.subtitles, trackNumber: track.trackNumber)
                    results.append(result)
                }
            } else if input.hasSuffix(".sup") {
                // Open the PGS data stream
                let PGS = try PGS(URL(fileURLWithPath: input))
                let result = try await processSubtitles(subtitles: PGS.subtitles, trackNumber: 0)
                results.append(result)
            }
        } else {
            let ffmpeg = try FFmpeg(input)
            for result in ffmpeg.subtitleTracks {
                logger.debug("Processing subtitle track: \(result.key)")
                let result = try await processSubtitles(subtitles: result.value, trackNumber: result.key, invert: false)
                results.append(result)
            }
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes: nil)
        for result in results {
            autoreleasepool {
                // Save srt file
                let srtFilePath = outputDirectory.appendingPathComponent("track_\(result.trackNumber).srt")
                let srt = SRT(subtitles: result.srt.values.sorted { $0.index! < $1.index! })
                srt.write(toFileAt: srtFilePath)

                // Save json file
                if json {
                    // Convert subtitle data to JSON
                    // Convert subtitle data to JSON
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
                    let jsonData = try? JSONSerialization.data(
                        withJSONObject: jsonResults,
                        options: [.prettyPrinted, .sortedKeys])
                    let jsonString = (String(data: jsonData ?? Data(), encoding: .utf8) ?? "[]")
                    let jsonFilePath = outputDirectory.appendingPathComponent("track_\(result.trackNumber).json")
                    try? jsonString.write(to: jsonFilePath, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    // MARK: - Methods

    @available(macOS 15.0, *)
    private func getOCRMode() -> RecognizeTextRequest.RecognitionLevel {
        if fastMode {
            .fast
        } else {
            .accurate
        }
    }

    private func getOCRMode() -> VNRequestTextRecognitionLevel {
        if fastMode {
            .fast
        } else {
            .accurate
        }
    }

    private func saveImages(image: CGImage, trackNumber: Int = 0, index: Int) throws {
        let outputDirectory = URL(fileURLWithPath: outputDirectory)
        let imageDirectory = outputDirectory.appendingPathComponent("images/" + "track_\(trackNumber)/")
        let pngPath = imageDirectory.appendingPathComponent("subtitle_\(index).png")

        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: nil)

        let destination = CGImageDestinationCreateWithURL(pngPath as CFURL, UTType.png.identifier as CFString, 1, nil)
        guard let destination else {
            throw macSubtitleOCRError.fileCreationError
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw macSubtitleOCRError.fileWriteError
        }
    }

    actor SubtitleAccumulator {
        var srtSubtitles: [Int: Subtitle] = [:]
        var json: [Int: SubtitleJSONResult] = [:]

        func appendSubtitle(_ subtitle: Subtitle) {
            srtSubtitles[subtitle.index!] = subtitle
        }

        func appendJSON(_ jsonOut: SubtitleJSONResult) {
            json[jsonOut.image] = jsonOut
        }
    }

    actor AsyncSemaphore {
        private var permits: Int

        init(limit: Int) {
            permits = limit
        }

        func wait() async {
            while permits <= 0 {
                // Wait until there's a permit available
                await Task.yield()
            }
            permits -= 1
        }

        func signal() {
            permits += 1
        }
    }

    private func processSubtitles(subtitles: [Subtitle], trackNumber: Int,
                                  invert: Bool = true) async throws -> macSubtitleOCRResult {
        let accumulator = SubtitleAccumulator()
        let semaphore = AsyncSemaphore(limit: 5) // Limit concurrent tasks to 5

        try await withThrowingDiscardingTaskGroup { group in
            for (subIndex, var subtitle) in subtitles.enumerated() {
                group.addTask {
                    // Wait for permission to start the task
                    await semaphore.wait()

                    if subtitle.imageWidth == 0 || subtitle.imageHeight == 0 {
                        logger.warning("Skipping subtitle index \(subIndex + 1) with empty image data!")
                        await semaphore.signal()
                        return
                    }

                    guard let subImage = subtitle.createImage(invert) else {
                        logger.info("Could not create image for index \(subIndex + 1)! Skipping...")
                        await semaphore.signal()
                        return
                    }

                    // Save subtitle image as PNG if requested
                    if saveImages {
                        do {
                            try saveImages(image: subImage, trackNumber: trackNumber, index: subIndex)
                        } catch {
                            logger.error("Error saving image \(trackNumber)-\(subIndex): \(error.localizedDescription)")
                        }
                    }

                    var subtitleLines: [SubtitleLine] = []
                    var subtitleText = ""

                    // Perform text recognition
                    if !forceOldAPI, #available(macOS 15.0, *) {
                        var request = RecognizeTextRequest()
                        request.recognitionLevel = getOCRMode()
                        request.usesLanguageCorrection = !disableLanguageCorrection
                        request.recognitionLanguages = language.split(separator: ",")
                            .map { Locale.Language(identifier: String($0)) }
                        let result = try await request.perform(on: subImage) as [RecognizedTextObservation]

                        subtitleText = result.compactMap { observation in
                            guard let candidate = observation.topCandidates(1).first else { return "" }

                            let string = candidate.string
                            let confidence = candidate.confidence
                            let stringRange = string.startIndex ..< string.endIndex
                            let boundingBox = candidate.boundingBox(for: stringRange)!.boundingBox
                            let rect = boundingBox.toImageCoordinates(
                                CGSize(width: subImage.width, height: subImage.height),
                                origin: .upperLeft)
                            let line = SubtitleLine(
                                text: string,
                                confidence: confidence,
                                x: max(0, Int(rect.minX)),
                                width: Int(rect.size.width),
                                y: max(0, Int(CGFloat(subImage.height) - rect.minY - rect.size.height)),
                                height: Int(rect.size.height))
                            subtitleLines.append(line)

                            return string
                        }.joined(separator: "\n")
                    } else {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = getOCRMode()
                        request.usesLanguageCorrection = !disableLanguageCorrection
                        request.revision = VNRecognizeTextRequestRevision3
                        request.recognitionLanguages = language.split(separator: ",").map { String($0) }

                        try? VNImageRequestHandler(cgImage: subImage, options: [:]).perform([request])
                        let observations = request.results! as [VNRecognizedTextObservation]

                        subtitleText = observations.compactMap { observation in
                            guard let candidate = observation.topCandidates(1).first else { return "" }

                            let string = candidate.string
                            let confidence = candidate.confidence
                            let stringRange = string.startIndex ..< string.endIndex
                            let boundingBox = try? candidate.boundingBox(for: stringRange)?.boundingBox ?? .zero
                            let rect = VNImageRectForNormalizedRect(
                                boundingBox ?? .zero,
                                subtitle.imageWidth!,
                                subtitle.imageHeight!)

                            let line = SubtitleLine(
                                text: string,
                                confidence: confidence,
                                x: max(0, Int(rect.minX)),
                                width: Int(rect.size.width),
                                y: max(0, Int(CGFloat(subImage.height) - rect.minY - rect.size.height)),
                                height: Int(rect.size.height))
                            subtitleLines.append(line)

                            return string
                        }.joined(separator: "\n")
                    }

                    let subtitleOut = Subtitle(index: subIndex + 1, text: subtitleText,
                                               startTimestamp: subtitle.startTimestamp,
                                               endTimestamp: subtitle.endTimestamp)
                    let jsonOut = SubtitleJSONResult(
                        image: subIndex + 1,
                        lines: subtitleLines,
                        text: subtitleText)

                    // Safely append to the arrays using the actor
                    await accumulator.appendSubtitle(subtitleOut)
                    await accumulator.appendJSON(jsonOut)
                    await semaphore.signal()
                }
            }
        }

        // Return results from the accumulator
        return await macSubtitleOCRResult(trackNumber: trackNumber, srt: accumulator.srtSubtitles, json: accumulator.json)
    }
}
