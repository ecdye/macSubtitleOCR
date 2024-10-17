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
        let fileHandler = FileHandler(outputDirectory: outputDirectory)
        let results = try await processInput(fileHandler: fileHandler)
        try await saveResults(fileHandler: fileHandler, results: results)
    }

    // MARK: - Methods

    private func processInput(fileHandler: FileHandler) async throws -> [macSubtitleOCRResult] {
        if internalDecoder {
            try await processInternalDecoder(fileHandler: fileHandler)
        } else {
            try await processFFmpegDecoder(fileHandler: fileHandler)
        }
    }

    private func processInternalDecoder(fileHandler: FileHandler) async throws -> [macSubtitleOCRResult] {
        var results: [macSubtitleOCRResult] = []
        var intermediateFiles: [Int: String] = [:]

        if input.hasSuffix(".sub") || input.hasSuffix(".idx") {
            let sub = try VobSub(
                input.replacingOccurrences(of: ".idx", with: ".sub"),
                input.replacingOccurrences(of: ".sub", with: ".idx"))
            let result = try await processSubtitle(sub.subtitles, trackNumber: 0, fileHandler: fileHandler)
            results.append(result)
        } else if input.hasSuffix(".mkv") {
            let mkvStream = MKVSubtitleExtractor(filePath: input)
            try mkvStream.parseTracks(codec: "S_HDMV/PGS")
            for track in mkvStream.tracks {
                logger.debug("Found subtitle track: \(track.trackNumber), Codec: \(track.codecId)")
                if saveSubtitleFile {
                    intermediateFiles[track.trackNumber] = try mkvStream.getSubtitleTrackData(
                        trackNumber: track.trackNumber,
                        outputDirectory: URL(string: fileHandler.outputDirectory)!)!
                }

                // Open the PGS data stream
                let PGS = try PGS(mkvStream.tracks[track.trackNumber].trackData)
                let result = try await processSubtitle(
                    PGS.subtitles,
                    trackNumber: track.trackNumber,
                    fileHandler: fileHandler)
                results.append(result)
            }
        } else if input.hasSuffix(".sup") {
            // Open the PGS data stream
            let PGS = try PGS(URL(fileURLWithPath: input))
            let result = try await processSubtitle(PGS.subtitles, trackNumber: 0, fileHandler: fileHandler)
            results.append(result)
        }

        return results
    }

    private func processFFmpegDecoder(fileHandler _: FileHandler) async throws -> [macSubtitleOCRResult] {
        var results: [macSubtitleOCRResult] = []
        let ffmpeg = try FFmpeg(input)

        for result in ffmpeg.subtitleTracks {
            logger.debug("Processing subtitle track: \(result.key)")
            let processor = createSubtitleProcessor(subtitles: result.value, trackNumber: result.key)
            let result = try await processor.process()
            results.append(result)
        }

        return results
    }

    private func processSubtitle(_ subtitles: [Subtitle], trackNumber: Int,
                                 fileHandler _: FileHandler) async throws -> macSubtitleOCRResult {
        let processor = createSubtitleProcessor(subtitles: subtitles, trackNumber: trackNumber)
        return try await processor.process()
    }

    private func createSubtitleProcessor(subtitles: [Subtitle], trackNumber: Int) -> SubtitleProcessor {
        SubtitleProcessor(
            subtitles: subtitles,
            trackNumber: trackNumber,
            invert: false,
            saveImages: saveImages,
            language: language,
            fastMode: fastMode,
            disableLanguageCorrection: disableLanguageCorrection,
            forceOldAPI: forceOldAPI,
            outputDirectory: outputDirectory)
    }

    private func saveResults(fileHandler: FileHandler, results: [macSubtitleOCRResult]) async throws {
        for result in results {
            autoreleasepool {
                try? fileHandler.saveSRTFile(for: result)
                if json {
                    try? fileHandler.saveJSONFile(for: result)
                }
            }
        }
    }
}
