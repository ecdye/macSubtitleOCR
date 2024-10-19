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

private let logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "main")

struct ExperimentalOptions: ParsableArguments {
    @Flag(help: "Use internal decoder (experimental)")
    var internalDecoder = false

    @Flag(help: "Force old API (experimental)")
    var forceOldAPI = false

    @Flag(help: "Save extracted subtitle file to disk (experimental)")
    var saveSubtitleFile = false

    @Flag(help: "Enable fast mode (experimental)")
    var fastMode = false

    @Flag(help: "Disable language correction (experimental)")
    var disableLanguageCorrection = false
}

// The main struct representing the macSubtitleOCR command-line tool.
@main
struct macSubtitleOCR: AsyncParsableCommand {
    // MARK: - Properties

    static let configuration = CommandConfiguration(
        commandName: "macSubtitleOCR",
        abstract: "macSubtitleOCR - Convert bitmap subtitles into SubRip format using the macOS OCR engine")

    @Argument(help: "Input subtitle file (supported formats: .sup, .sub, .idx, .mkv)")
    var input: String

    @Argument(help: "Directory to save the output files")
    var outputDirectory: String

    @Option(wrappedValue: "en", name: [.customShort("l"), .long],
            help: ArgumentHelp(
                "Comma-separated list of languages for OCR (ISO 639-1 codes)",
                valueName: "l"))
    var languages: String

    @Option(wrappedValue: 4, name: [.customShort("t"), .long],
            help: ArgumentHelp("Maximum number of threads to use for OCR", valueName: "n"))
    var maxThreads: Int

    @Flag(name: [.customShort("i"), .long], help: "Invert images before OCR")
    var invert = false

    @Flag(name: [.customShort("s"), .long], help: "Save extracted subtitle images to disk")
    var saveImages = false

    @Flag(name: [.customShort("j"), .long], help: "Save OCR results as raw JSON files")
    var json = false

    @OptionGroup(title: "Experimental Options", visibility: .hidden)
    var experimentalOptions: ExperimentalOptions

    // MARK: - Entrypoint

    func run() async throws {
        let fileHandler = FileHandler(outputDirectory: outputDirectory)
        let results = try await processInput()
        try await saveResults(fileHandler: fileHandler, results: results)
    }

    // MARK: - Methods

    private func processInput() async throws -> [macSubtitleOCRResult] {
        if experimentalOptions.internalDecoder {
            try await processInternalDecoder()
        } else {
            try await processFFmpegDecoder()
        }
    }

    private func processInternalDecoder() async throws -> [macSubtitleOCRResult] {
        var results: [macSubtitleOCRResult] = []

        if input.hasSuffix(".sub") || input.hasSuffix(".idx") {
            let sub = try VobSub(
                input.replacingOccurrences(of: ".idx", with: ".sub"),
                input.replacingOccurrences(of: ".sub", with: ".idx"))
            let result = try await processSubtitle(sub.subtitles, trackNumber: 0)
            results.append(result)
        } else if input.hasSuffix(".mkv") {
            let mkvStream = MKVSubtitleExtractor(filePath: input)
            try mkvStream.parseTracks(codec: "S_HDMV/PGS")
            for track in mkvStream.tracks {
                logger.debug("Found subtitle track: \(track.trackNumber), Codec: \(track.codecId)")
                if experimentalOptions.saveSubtitleFile {
                    mkvStream.saveSubtitleTrackData(
                        trackNumber: track.trackNumber,
                        outputDirectory: URL(fileURLWithPath: outputDirectory))
                }

                // Open the PGS data stream
                let pgs: PGS = try mkvStream.tracks[track.trackNumber].trackData
                    .withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                        try PGS(buffer)
                    }
                let result = try await processSubtitle(pgs.subtitles, trackNumber: track.trackNumber)
                results.append(result)
            }
        } else if input.hasSuffix(".sup") {
            // Open the PGS data stream
            let PGS = try PGS(URL(fileURLWithPath: input))
            let result = try await processSubtitle(PGS.subtitles, trackNumber: 0)
            results.append(result)
        }

        return results
    }

    private func processFFmpegDecoder() async throws -> [macSubtitleOCRResult] {
        var results: [macSubtitleOCRResult] = []
        let ffmpeg = try FFmpeg(input)

        for result in ffmpeg.subtitleTracks {
            logger.debug("Processing subtitle track: \(result.key)")
            let result = try await processSubtitle(result.value, trackNumber: result.key)
            results.append(result)
        }

        return results
    }

    private func processSubtitle(_ subtitles: [Subtitle], trackNumber: Int) async throws -> macSubtitleOCRResult {
        let processor = createSubtitleProcessor(subtitles, trackNumber)
        return try await processor.process()
    }

    private func createSubtitleProcessor(_ subtitles: [Subtitle], _ trackNumber: Int) -> SubtitleProcessor {
        SubtitleProcessor(
            subtitles: subtitles,
            trackNumber: trackNumber,
            invert: invert,
            saveImages: saveImages,
            language: languages,
            fastMode: experimentalOptions.fastMode,
            disableLanguageCorrection: experimentalOptions.disableLanguageCorrection,
            forceOldAPI: experimentalOptions.forceOldAPI,
            outputDirectory: outputDirectory,
            maxConcurrentTasks: maxThreads)
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
