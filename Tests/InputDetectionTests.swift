//
// InputDetectionTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import ArgumentParser
import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #97: the input type was told by a case-sensitive suffix, so `.MKV` or `.SUP` was rejected,
// and the other file of a VobSub pair was found by replacing `.idx` or `.sub` anywhere in the path,
// directory names included.

private func resource(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil)!
}

/// A fresh directory whose own name has `.sub` and `.idx` in it.
private func makeDottedDirectory() throws -> URL {
    let url = try URL(fileURLWithPath: makeOutputDirectory()).appendingPathComponent("x.sub.idx.dir")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Copies the test resource `name` into `directory` as `copyName`.
@discardableResult
private func copy(_ name: String, into directory: URL, as copyName: String) throws -> URL {
    let destination = directory.appendingPathComponent(copyName)
    try FileManager.default.copyItem(at: resource(name), to: destination)
    return destination
}

private func invalidInputMessage(_ body: () throws -> some Any) -> String? {
    do {
        _ = try body()
    } catch let macSubtitleOCRError.invalidInputFile(message) {
        return message
    } catch {
        return nil
    }
    return nil
}

private extension macSubtitleOCRInput {
    var vobSubPair: (sub: URL, idx: URL)? {
        if case let .vobSub(sub, idx) = self {
            (sub, idx)
        } else {
            nil
        }
    }
}

/// Checks that both files of a VobSub pair are in `directory`, with their extensions in some case.
private func expectVobSubPair(_ input: macSubtitleOCRInput, in directory: URL) throws -> (sub: URL, idx: URL) {
    let pair = try #require(input.vobSubPair)
    for (url, pathExtension) in [(pair.sub, "sub"), (pair.idx, "idx")] {
        #expect(url.deletingLastPathComponent().path == directory.path)
        #expect(url.pathExtension.lowercased() == pathExtension)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    return pair
}

@Test(arguments: [("SUB", "IDX"), ("Sub", "Idx"), ("sub", "IDX"), ("SUB", "idx")])
func vobSubPairIsFoundInAnyCase(subExtension: String, idxExtension: String) throws {
    let directory = try makeDottedDirectory()
    let sub = try copy("sintel.sub", into: directory, as: "movie.\(subExtension)")
    let idx = try copy("sintel.idx", into: directory, as: "movie.\(idxExtension)")

    for given in [sub, idx] {
        let pair = try expectVobSubPair(macSubtitleOCRInput(path: given.path), in: directory)
        #expect(given == sub ? pair.sub == sub : pair.idx == idx)
        #expect(try !VobSub(pair.sub, pair.idx).subtitles.isEmpty)
    }
}

@Test(arguments: ["sup", "SUP", "Sup"])
func pgsIsDetectedInAnyCase(pathExtension: String) throws {
    let directory = try makeDottedDirectory()
    let sup = try copy("sintel.sup", into: directory, as: "movie.\(pathExtension)")

    #expect(try macSubtitleOCRInput(path: sup.path) == .pgs(sup))
    #expect(try !PGS(sup).subtitles.isEmpty)
}

@Test(arguments: ["mkv", "MKV", "mks", "MKS", "Mkv"])
func matroskaIsDetectedInAnyCase(pathExtension: String) throws {
    let directory = try makeDottedDirectory()
    let mkv = try copy("sintel.mks", into: directory, as: "movie.\(pathExtension)")

    #expect(try macSubtitleOCRInput(path: mkv.path) == .matroska(mkv))
    let extractor = try MKVSubtitleExtractor(filePath: mkv.path)
    try extractor.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
    #expect(!extractor.tracks.isEmpty)
}

/// The directory's own `.sub` and `.idx` are left alone: only the file's extension is swapped.
@Test func dottedDirectoryNameIsNotRewritten() throws {
    let directory = try makeDottedDirectory()
    let sub = try copy("sintel.sub", into: directory, as: "movie.sub")
    let idx = try copy("sintel.idx", into: directory, as: "movie.idx")

    #expect(try macSubtitleOCRInput(path: sub.path) == .vobSub(sub: sub, idx: idx))
    #expect(try macSubtitleOCRInput(path: idx.path) == .vobSub(sub: sub, idx: idx))
}

@Test(arguments: [("sintel.sub", "movie.SUB", "movie.idx"), ("sintel.idx", "movie.Idx", "movie.sub")])
func missingVobSubSiblingIsReported(resourceName: String, copyName: String, expected: String) throws {
    let directory = try makeDottedDirectory()
    let given = try copy(resourceName, into: directory, as: copyName)

    let message = invalidInputMessage { try macSubtitleOCRInput(path: given.path) }
    #expect(message?.contains("Cannot find \(expected) beside \(copyName)") == true)
}

@Test func missingVobSubSiblingExitsWithFailure() async throws {
    let directory = try makeDottedDirectory()
    let sub = try copy("sintel.sub", into: directory, as: "movie.SUB")
    let output = try makeOutputDirectory()

    var runner = try macSubtitleOCR.parse([sub.path, output])
    await #expect(throws: ExitCode.failure) { try await runner.run() }
}

@Test(arguments: ["input.txt", "input.SRT", "input", "input.sub.txt"])
func unsupportedExtensionIsRejected(name: String) throws {
    let directory = try makeDottedDirectory()
    let path = directory.appendingPathComponent(name).path

    let message = invalidInputMessage { try macSubtitleOCRInput(path: path) }
    let pathExtension = URL(fileURLWithPath: path).pathExtension
    #expect(message?.hasPrefix("Invalid input file type \(pathExtension)") == true)
}

/// The whole run reads a VobSub in a dotted directory, its extensions in either case, and writes its track.
@Test(arguments: ["sub", "SUB"])
func vobSubInDottedDirectoryIsRecognized(subExtension: String) async throws {
    let directory = try makeDottedDirectory()
    let idxExtension = subExtension == "SUB" ? "IDX" : "idx"
    try copy("sintel.sub", into: directory, as: "movie.\(subExtension)")
    let idx = try copy("sintel.idx", into: directory, as: "movie.\(idxExtension)")
    let output = try makeOutputDirectory()

    var runner = try macSubtitleOCR.parse([idx.path, output])
    try await runner.run()
    let written = try FileManager.default.contentsOfDirectory(atPath: output).filter { $0.hasSuffix(".srt") }
    #expect(!written.isEmpty)
}

#if FFMPEG
/// The FFmpeg decoder is handed the `.idx` beside a `.sub` in any case, for its palette.
@Test func ffmpegDecoderFindsTheIndexInAnyCase() async throws {
    let directory = try makeDottedDirectory()
    let sub = try copy("sintel.sub", into: directory, as: "movie.SUB")
    #expect(macSubtitleOCRInput.vobSubIndex(for: sub) == nil)
    try copy("sintel.idx", into: directory, as: "movie.IDX")

    let idx = try #require(macSubtitleOCRInput.vobSubIndex(for: sub))
    #expect(idx.deletingLastPathComponent().path == directory.path)
    #expect(idx.pathExtension.lowercased() == "idx")
    #expect(try !FFmpeg(idx.path).subtitleTracks.isEmpty)

    let output = try makeOutputDirectory()
    var runner = try macSubtitleOCR.parse([sub.path, output, "--ffmpeg-decoder"])
    try await runner.run()
    let written = try FileManager.default.contentsOfDirectory(atPath: output).filter { $0.hasSuffix(".srt") }
    #expect(!written.isEmpty)
}
#endif
