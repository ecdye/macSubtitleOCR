//
// SubtitleProcessor.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/17/24.
// Copyright © 2024-2025 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import Vision

struct SubtitleProcessor {
    private let subtitles: [Subtitle]
    private let trackNumber: Int
    private let invert: Bool
    private let saveImages: Bool
    private let language: String
    private let customWords: [String]?
    private let fastMode: Bool
    private let disableLanguageCorrection: Bool
    private let disableICorrection: Bool
    private let forceOldAPI: Bool
    private let outputDirectory: String
    private let maxConcurrentTasks: Int

    init(for subtitles: [Subtitle], from trackNumber: Int, withOptions invert: Bool, _ saveImages: Bool, _ language: String,
         _ customWords: [String]?, _ fastMode: Bool, _ disableLanguageCorrection: Bool, _ disableICorrection: Bool,
         _ forceOldAPI: Bool, _ outputDirectory: String, _ maxConcurrentTasks: Int) {
        self.subtitles = subtitles
        self.trackNumber = trackNumber
        self.invert = invert
        self.saveImages = saveImages
        self.language = language
        self.customWords = customWords
        self.fastMode = fastMode
        self.disableLanguageCorrection = disableLanguageCorrection
        self.disableICorrection = disableICorrection
        self.forceOldAPI = forceOldAPI
        self.outputDirectory = outputDirectory
        self.maxConcurrentTasks = maxConcurrentTasks
    }

    func process() async throws -> macSubtitleOCRResult {
        let accumulator = SubtitleAccumulator()
        let semaphore = AsyncSemaphore(limit: maxConcurrentTasks) // Limit concurrent tasks

        try await withThrowingDiscardingTaskGroup { group in
            for subtitle in subtitles {
                group.addTask {
                    // Wait for permission to start the task
                    await semaphore.wait()
                    let subIndex = subtitle.index

                    guard !shouldSkip(subtitle), let subImage = subtitle.createImage(invert) else {
                        print(
                            "Found invalid image for track: \(trackNumber), index: \(subIndex), creating an empty placeholder!")
                        subtitle.text = ""
                        await accumulator.append(subtitle, SubtitleJSONResult(index: subIndex, lines: [], text: ""))
                        await semaphore.signal()
                        return
                    }

                    // Save subtitle image as PNG if requested
                    if saveImages {
                        do {
                            try saveImage(subImage, index: subIndex)
                        } catch {
                            print(
                                "Error saving image \(trackNumber)-\(subIndex): \(error.localizedDescription)",
                                to: &stderr)
                        }
                    }

                    let (subtitleText, subtitleLines) = await recognizeText(from: subImage)
                    if language.contains("en"), !disableICorrection {
                        let pattern = #"\bl\b"# // Replace l with I when it's a single character
                        subtitle.text = subtitleText.replacingOccurrences(
                            of: pattern,
                            with: "I",
                            options: .regularExpression)
                    } else {
                        subtitle.text = subtitleText
                    }
                    subtitle.imageData = nil // Clear the image data to save memory

                    let jsonOut = SubtitleJSONResult(index: subIndex, lines: subtitleLines, text: subtitleText)

                    // Safely append to the arrays using the actor
                    await accumulator.append(subtitle, jsonOut)
                    await semaphore.signal()
                }
            }
        }

        return await macSubtitleOCRResult(trackNumber: trackNumber, srt: accumulator.subtitles, json: accumulator.json)
    }

    private func shouldSkip(_ subtitle: Subtitle) -> Bool {
        subtitle.imageWidth == 0 || subtitle.imageHeight == 0
    }

    private func recognizeText(from image: CGImage) async -> (String, [SubtitleLine]) {
        var text = ""
        var lines: [SubtitleLine] = []

        if !forceOldAPI, #available(macOS 15.0, *) {
            let request = createRecognizeTextRequest()
            let observations = try? await request.perform(on: image) as [RecognizedTextObservation]
            let size = CGSize(width: image.width, height: image.height)
            processRecognizedText(observations, &text, &lines, size)
        } else {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = getOCRMode()
            request.usesLanguageCorrection = !disableLanguageCorrection
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLanguages = language.split(separator: ",").map { String($0) }
            if let customWords {
                request.customWords = customWords
            }

            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            processRecognizedText(request.results, &text, &lines, image.width, image.height)
        }

        return (text, lines)
    }

    @available(macOS 15.0, *)
    private func createRecognizeTextRequest() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = getOCRMode()
        request.usesLanguageCorrection = !disableLanguageCorrection
        request.recognitionLanguages = language.split(separator: ",").map { Locale.Language(identifier: String($0)) }
        if let customWords {
            request.customWords = customWords
        }
        return request
    }

    @available(macOS 15.0, *)
    private func processRecognizedText(_ result: [RecognizedTextObservation]?, _ text: inout String,
                                       _ lines: inout [SubtitleLine], _ size: CGSize) {
        text = result?.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return "" }

            let string = candidate.string
            let confidence = candidate.confidence
            let stringRange = string.startIndex ..< string.endIndex
            let boundingBox = candidate.boundingBox(for: stringRange)?.boundingBox
            let rect = boundingBox?.toImageCoordinates(size, origin: .upperLeft) ?? .zero
            let line = SubtitleLine(
                text: string,
                confidence: confidence,
                x: max(0, Int(rect.minX)),
                width: Int(rect.size.width),
                y: max(0, Int(size.height - rect.minY - rect.size.height)),
                height: Int(rect.size.height))
            lines.append(line)

            return string
        }.joined(separator: "\n") ?? ""
    }

    private func processRecognizedText(_ observations: [VNRecognizedTextObservation]?, _ text: inout String,
                                       _ lines: inout [SubtitleLine], _ width: Int, _ height: Int) {
        text = observations?.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return "" }

            let string = candidate.string
            let confidence = candidate.confidence
            let stringRange = string.startIndex ..< string.endIndex
            let boundingBox = try? candidate.boundingBox(for: stringRange)?.boundingBox
            let rect = VNImageRectForNormalizedRect(boundingBox ?? .zero, width, height)

            let line = SubtitleLine(
                text: string,
                confidence: confidence,
                x: max(0, Int(rect.minX)),
                width: Int(rect.size.width),
                y: max(0, Int(CGFloat(height) - rect.minY - rect.size.height)),
                height: Int(rect.size.height))
            lines.append(line)

            return string
        }.joined(separator: "\n") ?? ""
    }

    private func saveImage(_ image: CGImage, index: Int) throws {
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
