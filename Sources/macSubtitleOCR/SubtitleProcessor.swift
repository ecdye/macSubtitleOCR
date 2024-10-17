//
// SubtitleProcessor.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
import os
import UniformTypeIdentifiers
import Vision

private let logger: Logger = .init(subsystem: "github.ecdye.macSubtitleOCR", category: "SubtitleProcessor")

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
            await Task.yield()
        }
        permits -= 1
    }

    func signal() {
        permits += 1
    }
}

struct SubtitleProcessor {
    let subtitles: [Subtitle]
    let trackNumber: Int
    let invert: Bool
    let saveImages: Bool
    let language: String
    let fastMode: Bool
    let disableLanguageCorrection: Bool
    let forceOldAPI: Bool
    let outputDirectory: String

    func process() async throws -> macSubtitleOCRResult {
        let accumulator = SubtitleAccumulator()
        let semaphore = AsyncSemaphore(limit: 5) // Limit concurrent tasks to 5

        try await withThrowingDiscardingTaskGroup { group in
            for (subIndex, var subtitle) in subtitles.enumerated() {
                group.addTask {
                    // Wait for permission to start the task
                    await semaphore.wait()

                    guard !shouldSkipSubtitle(subtitle, at: subIndex) else {
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

                    let (subtitleText, subtitleLines) = await recognizeText(from: subImage, at: subIndex)

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

    private func shouldSkipSubtitle(_ subtitle: Subtitle, at index: Int) -> Bool {
        if subtitle.imageWidth == 0 || subtitle.imageHeight == 0 {
            logger.warning("Skipping subtitle index \(index + 1) with empty image data!")
            return true
        }
        return false
    }

    private func recognizeText(from image: CGImage, at _: Int) async -> (String, [SubtitleLine]) {
        var subtitleLines: [SubtitleLine] = []
        var subtitleText = ""

        if !forceOldAPI, #available(macOS 15.0, *) {
            let request = createRecognizeTextRequest()
            let result = try? await request.perform(on: image) as [RecognizedTextObservation]
            subtitleText = processRecognizedText(
                result,
                subtitleLines: &subtitleLines,
                imageWidth: image.width,
                imageHeight: image.height)
        } else {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = getOCRMode()
            request.usesLanguageCorrection = !disableLanguageCorrection
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLanguages = language.split(separator: ",").map { String($0) }

            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let observations = request.results! as [VNRecognizedTextObservation]
            subtitleText = processVNRecognizedText(
                observations,
                subtitleLines: &subtitleLines,
                imageWidth: image.width,
                imageHeight: image.height)
        }

        return (subtitleText, subtitleLines)
    }

    @available(macOS 15.0, *)
    private func createRecognizeTextRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = getOCRMode()
        request.usesLanguageCorrection = !disableLanguageCorrection
        request.recognitionLanguages = language.split(separator: ",").map { Locale.Language(identifier: String($0)) }
        return request
    }

    @available(macOS 15.0, *)
    private func processRecognizedText(_ result: [RecognizedTextObservation]?, subtitleLines: inout [SubtitleLine],
                                       imageWidth: Int, imageHeight: Int) -> String {
        result?.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return "" }

            let string = candidate.string
            let confidence = candidate.confidence
            let stringRange = string.startIndex ..< string.endIndex
            let boundingBox = candidate.boundingBox(for: stringRange)!.boundingBox
            let rect = boundingBox.toImageCoordinates(CGSize(width: imageWidth, height: imageHeight), origin: .upperLeft)
            let line = SubtitleLine(
                text: string,
                confidence: confidence,
                x: max(0, Int(rect.minX)),
                width: Int(rect.size.width),
                y: max(0, Int(CGFloat(imageHeight) - rect.minY - rect.size.height)),
                height: Int(rect.size.height))
            subtitleLines.append(line)

            return string
        }.joined(separator: "\n") ?? ""
    }

    private func processVNRecognizedText(_ observations: [VNRecognizedTextObservation], subtitleLines: inout [SubtitleLine],
                                         imageWidth: Int, imageHeight: Int) -> String {
        observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return "" }

            let string = candidate.string
            let confidence = candidate.confidence
            let stringRange = string.startIndex ..< string.endIndex
            let boundingBox = try? candidate.boundingBox(for: stringRange)?.boundingBox ?? .zero
            let rect = VNImageRectForNormalizedRect(boundingBox ?? .zero, imageWidth, imageHeight)

            let line = SubtitleLine(
                text: string,
                confidence: confidence,
                x: max(0, Int(rect.minX)),
                width: Int(rect.size.width),
                y: max(0, Int(CGFloat(imageHeight) - rect.minY - rect.size.height)),
                height: Int(rect.size.height))
            subtitleLines.append(line)

            return string
        }.joined(separator: "\n")
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

    @available(macOS 15.0, *)
    private func getOCRMode() -> RecognizeTextRequest.RecognitionLevel {
        fastMode ? .fast : .accurate
    }

    private func getOCRMode() -> VNRequestTextRecognitionLevel {
        fastMode ? .fast : .accurate
    }
}
