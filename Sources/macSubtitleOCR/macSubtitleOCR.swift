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
nonisolated(unsafe) var stderr = FileHandleOutputStream(.standardError)

@main
struct macSubtitleOCR: AsyncParsableCommand {
    // MARK: - Properties

    static let configuration = CommandConfiguration(
        commandName: "macSubtitleOCR",
        abstract: "macSubtitleOCR - Convert bitmap subtitles into SubRip format using the macOS Vision framework")

    @Argument(help: "Input subtitle file (supported formats: .sup, .sub, .idx, .mkv)")
    var input: String

    @Argument(help: "Directory to save the output files")
    var outputDirectory: String

    @OptionGroup(title: "Options")
    var options: Options

    @OptionGroup(title: "Experimental Options", visibility: .hidden)
    var experimentalOptions: ExperimentalOptions

    // MARK: - Entrypoint

    mutating func run() async {
        // swiftformat:disable all
        do {
            let fileHandler = try macSubtitleOCRFileHandler(outputDirectory: outputDirectory)
            let results = try await processInput()
            try await saveResults(fileHandler: fileHandler, results: results)
        } catch let macSubtitleOCRError.fileReadError(string), let macSubtitleOCRError.invalidInputFile(string),
                let macSubtitleOCRError.ffmpegError(string), let macSubtitleOCRError.invalidRLE(string) {
            print("Error: \(string), exiting...", to: &stderr)
        } catch {
            print("Error: \(error.localizedDescription), exiting...", to: &stderr)
        }
        // swiftformat:enable all
    }

    // MARK: - Methods

    private mutating func processInput() async throws -> [macSubtitleOCRResult] {
        #if FFMPEG
        if options.ffmpegDecoder {
            try await processFFmpegDecoder()
        } else {
            try await processInternalDecoder()
        }
        #else
        try await processInternalDecoder()
        #endif
    }

    private mutating func processInternalDecoder() async throws -> [macSubtitleOCRResult] {
        var results: [macSubtitleOCRResult] = []

        if input.hasSuffix(".sub") || input.hasSuffix(".idx") {
            options.invert.toggle() // Invert the image if the input is a VobSub file
            let sub = try VobSub(
                URL(fileURLWithPath: input.replacingOccurrences(of: ".idx", with: ".sub")),
                URL(fileURLWithPath: input.replacingOccurrences(of: ".sub", with: ".idx")))
            let result = try await processSubtitle(sub.subtitles, trackNumber: 0)
            results.append(result)
            if sub.language != nil {
                options.languages += ",\(sub.language!)"
            }
        } else if input.hasSuffix(".mkv") || input.hasSuffix(".mks") {
            let mkvStream = try MKVSubtitleExtractor(filePath: input)
            try mkvStream.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
            for track in mkvStream.tracks {
                logger.debug("Found subtitle track: \(track.trackNumber), Codec: \(track.codecID)")
                if experimentalOptions.saveSubtitleFile {
                    mkvStream.saveSubtitleTrackData(
                        trackNumber: track.trackNumber,
                        outputDirectory: URL(fileURLWithPath: outputDirectory))
                }

                if track.language != nil {
                    options.languages += ",\(track.language!)"
                }

                if track.codecID == "S_HDMV/PGS" {
                    let pgs: PGS = try track.trackData
                        .withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                            try PGS(buffer)
                        }
                    let result = try await processSubtitle(pgs.subtitles, trackNumber: track.trackNumber)
                    results.append(result)
                } else if track.codecID == "S_VOBSUB" {
                    options.invert.toggle() // Invert the image if the input is VobSub
                    let vobSub: VobSub = try track.trackData
                        .withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                            try VobSub(buffer, track.idxData ?? "")
                        }
                    let result = try await processSubtitle(vobSub.subtitles, trackNumber: track.trackNumber)
                    results.append(result)
                    options.invert.toggle() // Reset the invert flag
                }
            }
        } else if input.hasSuffix(".sup") {
            // Open the PGS data stream
            let PGS = try PGS(URL(fileURLWithPath: input))
            let result = try await processSubtitle(PGS.subtitles, trackNumber: 0)
            results.append(result)
        } else {
            throw macSubtitleOCRError.invalidInputFile("Invalid input file type \((input as NSString).pathExtension)")
        }

        return results
    }

    #if FFMPEG
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
    #endif

    private func processSubtitle(_ subtitles: [Subtitle], trackNumber: Int) async throws -> macSubtitleOCRResult {
        let processor = createSubtitleProcessor(subtitles, trackNumber)
        return try await processor.process()
    }

    private func createSubtitleProcessor(_ subtitles: [Subtitle], _ trackNumber: Int) -> SubtitleProcessor {
        SubtitleProcessor(for: subtitles, from: trackNumber,
                          withOptions: options.invert, options.saveImages, options.languages,
                          options.customWords?.split(separator: ",").map(String.init), experimentalOptions.fastMode,
                          experimentalOptions.disableLanguageCorrection, options.disableICorrection,
                          experimentalOptions.forceOldAPI, outputDirectory, options.maxThreads)
    }

    private func saveResults(fileHandler: macSubtitleOCRFileHandler, results: [macSubtitleOCRResult]) async throws {
        for result in results {
            autoreleasepool {
                try? fileHandler.saveSRTFile(for: result)
                if options.json {
                    try? fileHandler.saveJSONFile(for: result)
                }
            }
        }
    }
}
