//
// macSubtitleOCR.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/2/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import ArgumentParser
import os
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "main")
nonisolated(unsafe) var stderr = FileHandleOutputStream(.standardError)

@main
struct macSubtitleOCR: AsyncParsableCommand {
    // MARK: - Properties

    static let configuration = CommandConfiguration(
        commandName: "macSubtitleOCR",
        abstract: "macSubtitleOCR - Convert bitmap subtitles into SubRip format using the macOS Vision framework")

    @Argument(help: "Input subtitle file (supported formats: .sup, .sub, .idx, .mkv, .mks)")
    var input: String

    @Argument(help: "Directory to save the output files")
    var outputDirectory: String

    @OptionGroup(title: "Options")
    var options: Options

    @OptionGroup(title: "Experimental Options", visibility: .hidden)
    var experimentalOptions: ExperimentalOptions

    // MARK: - Entrypoint

    mutating func run() async throws {
        var failedTracks: [Int] = []
        // swiftformat:disable all
        do {
            let fileHandler = try macSubtitleOCRFileHandler(outputDirectory: outputDirectory)
            failedTracks = try await processInput(writingTo: fileHandler)
        } catch let macSubtitleOCRError.fileReadError(string), let macSubtitleOCRError.invalidInputFile(string),
                let macSubtitleOCRError.ffmpegError(string), let macSubtitleOCRError.invalidRLE(string),
                let macSubtitleOCRError.invalidODSDimensions(string) {
            print("Error: \(string), exiting...", to: &stderr)
            throw ExitCode.failure
        } catch {
            print("Error: \(error.localizedDescription), exiting...", to: &stderr)
            throw ExitCode.failure
        }
        // swiftformat:enable all

        // Every other track has been written; the run still fails so that a script can tell.
        guard failedTracks.isEmpty else {
            let count = failedTracks.count
            print("Error: \(count) subtitle track\(count == 1 ? "" : "s") failed, exiting...", to: &stderr)
            throw ExitCode.failure
        }
    }

    // MARK: - Methods

    /// Reads the input and processes each of its subtitle tracks, returning the numbers of the tracks that
    /// failed. An input that cannot be read at all throws.
    private func processInput(writingTo fileHandler: macSubtitleOCRFileHandler) async throws -> [Int] {
        #if FFMPEG
        if options.ffmpegDecoder {
            try await processFFmpegDecoder(writingTo: fileHandler)
        } else {
            try await processInternalDecoder(writingTo: fileHandler)
        }
        #else
        try await processInternalDecoder(writingTo: fileHandler)
        #endif
    }

    private func processInternalDecoder(writingTo fileHandler: macSubtitleOCRFileHandler) async throws -> [Int] {
        var failedTracks: [Int] = []

        switch try macSubtitleOCRInput(path: input, hint: Self.ffmpegHint) {
        case let .vobSub(subURL, idxURL):
            let sub = try VobSub(subURL, idxURL)
            // Each stream of the idx, usually one per language, is its own track, numbered by its index.
            for track in sub.tracks {
                await processTrack(track.index, languages: languages(adding: track.language),
                                   writingTo: fileHandler, failedTracks: &failedTracks) {
                    if let failure = track.failure {
                        throw macSubtitleOCRError.invalidInputFile(failure)
                    }
                    return track.subtitles
                }
            }
        case let .matroska(url):
            let mkvStream = try MKVSubtitleExtractor(filePath: url.path)
            try mkvStream.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
            if mkvStream.tracks.isEmpty {
                let found = mkvStream.skippedSubtitleCodecs
                let detail = found.isEmpty ? "no subtitle tracks" : "only \(found.joined(separator: ", "))"
                throw macSubtitleOCRError.invalidInputFile(
                    "No PGS or VobSub subtitle tracks found, the file has \(detail)\(Self.ffmpegHint)")
            }
            for track in mkvStream.tracks {
                logger.debug("Found subtitle track: \(track.trackNumber), Codec: \(track.codecID)")
                await processTrack(track.trackNumber, languages: languages(adding: track.language),
                                   writingTo: fileHandler, failedTracks: &failedTracks) {
                    if experimentalOptions.saveSubtitleFile {
                        try mkvStream.saveSubtitleTrackData(track,
                                                            outputDirectory: URL(fileURLWithPath: outputDirectory))
                    }
                    return try track.subtitles()
                }
            }
        case let .pgs(url):
            // Open the PGS data stream
            let PGS = try PGS(url)
            await processTrack(0, languages: options.languages, writingTo: fileHandler,
                               failedTracks: &failedTracks) { PGS.subtitles }
        }

        return failedTracks
    }

    /// Points at the FFmpeg decoder when the internal one cannot read an input, if this build has it.
    private static var ffmpegHint: String {
        #if FFMPEG
        "; the FFmpeg decoder (--ffmpeg-decoder) reads other formats, such as DVB subtitles"
        #else
        ""
        #endif
    }

    #if FFMPEG
    private func processFFmpegDecoder(writingTo fileHandler: macSubtitleOCRFileHandler) async throws -> [Int] {
        var failedTracks: [Int] = []
        // A bare VobSub .sub is a plain MPEG-PS stream: FFmpeg only gets the palette and frame size when
        // it opens the .idx, and without them it guesses a palette that turns filled glyphs hollow.
        var ffmpegInput = input
        let inputURL = URL(fileURLWithPath: input)
        if inputURL.pathExtension.lowercased() == "sub", let idx = macSubtitleOCRInput.vobSubIndex(for: inputURL) {
            ffmpegInput = idx.path
        }
        let ffmpeg = try FFmpeg(ffmpegInput)

        if ffmpeg.subtitleTracks.isEmpty {
            throw macSubtitleOCRError.invalidInputFile("No bitmap subtitles found in \(input)")
        }

        for (trackNumber, subtitles) in ffmpeg.subtitleTracks.sorted(by: { $0.key < $1.key }) {
            logger.debug("Processing subtitle track: \(trackNumber)")
            await processTrack(trackNumber, languages: options.languages, writingTo: fileHandler,
                               failedTracks: &failedTracks) { subtitles }
        }

        return failedTracks
    }
    #endif

    /// The recognition languages for one track: the requested list plus the track's own language.
    ///
    /// Built fresh for each track. Appending onto `options.languages` instead leaves every track
    /// carrying the languages of the tracks before it, so in a file with several subtitle tracks the
    /// later ones are recognized with the earlier tracks' languages taking priority.
    private func languages(adding trackLanguage: String?) -> String {
        guard let trackLanguage else { return options.languages }
        return "\(options.languages),\(trackLanguage)"
    }

    /// Decodes, recognizes and writes one track, adding its number to `failedTracks` if any step fails.
    ///
    /// The track's SRT, and its JSON when asked for, are written as soon as it is done, so a later track
    /// that fails, or a run that is stopped, does not lose it. A track that fails is reported on stderr and
    /// the other tracks are processed all the same.
    private func processTrack(_ trackNumber: Int, languages: String, writingTo fileHandler: macSubtitleOCRFileHandler,
                              failedTracks: inout [Int], decode: () throws -> [Subtitle]) async {
        do {
            let subtitles = try decode()
            let result = try await processSubtitle(subtitles, trackNumber: trackNumber, languages: languages)
            try autoreleasepool {
                try fileHandler.saveSRTFile(for: result)
                if options.json {
                    try fileHandler.saveJSONFile(for: result)
                }
            }
        } catch {
            let message = (error as? macSubtitleOCRError)?.description ?? error.localizedDescription
            print("Error: track \(trackNumber) failed: \(message), skipping it...", to: &stderr)
            failedTracks.append(trackNumber)
        }
    }

    private func processSubtitle(_ subtitles: [Subtitle], trackNumber: Int,
                                 languages: String) async throws -> macSubtitleOCRResult {
        let processor = createSubtitleProcessor(subtitles, trackNumber, languages)
        return try await processor.process()
    }

    private func createSubtitleProcessor(_ subtitles: [Subtitle], _ trackNumber: Int,
                                         _ languages: String) -> SubtitleProcessor {
        SubtitleProcessor(for: subtitles, from: trackNumber,
                          withOptions: options.invert, options.saveImages, languages,
                          options.customWords?.split(separator: ",").map(String.init), experimentalOptions.fastMode,
                          experimentalOptions.disableLanguageCorrection, options.disableICorrection,
                          experimentalOptions.forceOldAPI, outputDirectory, options.maxThreads)
    }
}
