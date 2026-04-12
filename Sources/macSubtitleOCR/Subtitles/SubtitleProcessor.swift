//
// SubtitleProcessor.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/17/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import Vision

private struct OCRSubtitleTaskInput: Sendable {
    let index: Int
    let startTimestamp: TimeInterval?
    let endTimestamp: TimeInterval?
    let imageSource: SubtitleImageSource?

    init(_ subtitle: Subtitle) {
        index = subtitle.index
        startTimestamp = subtitle.startTimestamp
        endTimestamp = subtitle.endTimestamp
        imageSource = subtitle.makeImageSource()
    }

    func makeSubtitle(text: String) -> Subtitle {
        Subtitle(index: index, text: text, startTimestamp: startTimestamp, endTimestamp: endTimestamp)
    }
}

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
        let taskSemaphore = AsyncSemaphore(limit: maxConcurrentTasks)
        let textRecognitionSemaphore = AsyncSemaphore(limit: shouldSerializeModernTextRecognition ? 1 : maxConcurrentTasks)
        let taskInputs = subtitles.map(OCRSubtitleTaskInput.init)

        try await withThrowingDiscardingTaskGroup { group in
            for taskInput in taskInputs {
                group.addTask {
                    await taskSemaphore.wait()
                    defer { Task { await taskSemaphore.signal() } }

                    let subIndex = taskInput.index

                    guard !shouldSkip(taskInput), let imageSource = taskInput.imageSource,
                          let subImage = imageSource.createImage(invert) else {
                        print(
                            "Found invalid image for track: \(trackNumber), index: \(subIndex), creating an empty placeholder!")
                        await accumulator.append(taskInput.makeSubtitle(text: ""),
                                                 SubtitleJSONResult(index: subIndex, lines: [], text: ""))
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

                    let (subtitleText, subtitleLines) = await recognizeText(from: subImage,
                                                                            textRecognitionSemaphore: textRecognitionSemaphore)
                    let correctedText: String
                    if language.contains("en"), !disableICorrection {
                        let pattern = #"\bl\b"# // Replace l with I when it's a single character
                        correctedText = subtitleText.replacingOccurrences(
                            of: pattern,
                            with: "I",
                            options: .regularExpression)
                    } else {
                        correctedText = subtitleText
                    }

                    let jsonOut = SubtitleJSONResult(index: subIndex, lines: subtitleLines, text: correctedText)

                    await accumulator.append(taskInput.makeSubtitle(text: correctedText), jsonOut)
                }
            }
        }

        return await macSubtitleOCRResult(trackNumber: trackNumber, srt: accumulator.subtitles, json: accumulator.json)
    }

    private var shouldSerializeModernTextRecognition: Bool {
        guard !forceOldAPI else {
            return false
        }
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    private func shouldSkip(_ taskInput: OCRSubtitleTaskInput) -> Bool {
        guard let imageSource = taskInput.imageSource else {
            return true
        }
        return imageSource.width == 0 || imageSource.height == 0
    }

    private func recognizeText(from image: CGImage, textRecognitionSemaphore: AsyncSemaphore) async -> (String, [SubtitleLine]) {
        var text = ""
        var lines: [SubtitleLine] = []

        if !forceOldAPI, #available(macOS 15.0, *) {
            await textRecognitionSemaphore.wait()
            let observations: [RecognizedTextObservation]?
            do {
                let request = createRecognizeTextRequest()
                observations = try await request.perform(on: image) as [RecognizedTextObservation]
            } catch {
                observations = nil
            }
            await textRecognitionSemaphore.signal()
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
