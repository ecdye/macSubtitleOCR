//
// macSubtitleOCRTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import CoreGraphics
import CoreText
import Foundation
@testable import macSubtitleOCR
import Testing

let goodSRTPath = Bundle.module.url(forResource: "sintel.srt", withExtension: nil)!.path
let goodJSONPath = Bundle.module.url(forResource: "sintel.json", withExtension: nil)!.path
#if GITHUB_ACTIONS // Lower thread count for CI to avoid timeouts
let options = ["--json", "--max-threads", "1"]
#else
let options = ["--json"]
#endif

#if FFMPEG
@Test(.serialized, arguments: TestFilePaths.allCases.map(\.path))
func ffmpegDecoder(path: String) async throws {
    let outputPath = try makeOutputDirectory()
    let options = [path, outputPath, "--ffmpeg-decoder"] + options
    try await runTest(with: options)
}
#endif

@Test(.serialized, arguments: TestFilePaths.allCases.map(\.path))
func internalDecoder(path: String) async throws {
    let outputPath = try makeOutputDirectory()
    let options = [path, outputPath] + options
    try await runTest(with: options)
}

/// Each case needs its own directory: track numbers come from the input, so `sintel.mks` writes
/// track_1 and track_2 while the other inputs write track_0. Sharing one directory lets a case
/// assert against output another case left behind.
func makeOutputDirectory() throws -> String {
    let url = URL.temporaryDirectory.appendingPathComponent("macSubtitleOCRTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

/// Reads a JSON result with the per-line alternates dropped.
///
/// Which readings the recognizer offers below its best one, and in what order, changes between
/// releases of the framework far more readily than the reading it settles on, so they cannot be held
/// against a checked in reference. `alternatesAreOfferedPerLine` covers them instead.
private func withoutAlternates(atPath path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard var images = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return ""
    }
    for index in images.indices {
        if let lines = images[index]["lines"] as? [[String: Any]] {
            images[index]["lines"] = lines.map { line in
                line.filter { $0.key != "alternates" }
            }
        }
    }
    let stripped = try JSONSerialization.data(withJSONObject: images, options: [.prettyPrinted, .sortedKeys])
    return String(data: stripped, encoding: .utf8) ?? ""
}

private func runTest(with options: [String]) async throws {
    let outputPath = options[1]

    // Run tests
    var runner = try macSubtitleOCR.parse(options)
    try await runner.run()

    let tracks = try FileManager.default.contentsOfDirectory(atPath: outputPath)
        .compactMap { name -> Int? in
            guard name.hasPrefix("track_"), name.hasSuffix(".srt") else { return nil }
            return Int(name.dropFirst("track_".count).dropLast(".srt".count))
        }
        .sorted()

    #expect(!tracks.isEmpty)
    for track in tracks {
        try compareOutputs(with: outputPath, track: track)
    }
}

private func compareOutputs(with outputPath: String, track: Int) throws {
    let srtExpectedOutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
    let jsonExpectedOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
    let srtActualOutput = try String(contentsOfFile: "\(outputPath)/track_\(track).srt", encoding: .utf8)
    let jsonActualOutput = try withoutAlternates(atPath: "\(outputPath)/track_\(track).json")

    let srtMatch = similarityPercentage(of: srtExpectedOutput, and: srtActualOutput)
    let jsonMatch = similarityPercentage(of: jsonExpectedOutput, and: jsonActualOutput)

    #expect(srtMatch >= 85.0) // Lower threshold due to timestamp differences
    #expect(jsonMatch >= 95.0)
}

/// A PGS stream that ends mid-segment must be rejected or parsed, never read past the end of the buffer.
@Test func truncatedPGSStreamIsRejectedNotTrapped() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: TestFilePaths.sup.path))
    var parsedAnySubtitles = false

    for length in stride(from: 16, to: data.count, by: 4003) {
        let truncated = data.prefix(length)
        do {
            let pgs = try truncated.withUnsafeBytes { try PGS($0) }
            parsedAnySubtitles = parsedAnySubtitles || !pgs.subtitles.isEmpty
            for subtitle in pgs.subtitles {
                _ = subtitle.makeImageSource()
            }
        } catch is macSubtitleOCRError {
            // Reporting malformed input is fine; trapping on it is not.
        }
    }

    // Guard against the parser passing this test by rejecting everything.
    #expect(parsedAnySubtitles)
}

/// Builds a PGS segment: 2 byte magic, 4 byte PTS, 4 byte DTS, 1 byte type, 2 byte payload length.
private func pgsSegment(type: UInt8, payload: [UInt8]) -> [UInt8] {
    var segment: [UInt8] = Array("PG".utf8) + [0, 0, 0, 0] + [0, 0, 0, 0] + [type]
    segment += [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
    return segment + payload
}

/// An object claiming to be larger than the video it is composited onto must be left out, because
/// decoding it would reserve a buffer of `objectWidth * objectHeight`.
@Test func oversizedObjectIsRejected() throws {
    // Presentation composition segment declaring a 1920x1080 video.
    let presentation = pgsSegment(type: 0x16, payload: [0x07, 0x80, 0x04, 0x38] + [UInt8](repeating: 0, count: 7))
    // Palette definition segment holding a single entry, so a subtitle can be assembled.
    let palette = pgsSegment(type: 0x14, payload: [0x00, 0x00] + [0x00, 0x80, 0x80, 0x80, 0xFF])
    // Object definition segment, first and last in its sequence, claiming the largest dimensions the
    // 16 bit width and height fields allow.
    let object = pgsSegment(type: 0x15, payload: [0x00, 0x00, 0x00, 0xC0] + [0x00, 0x00, 0x04] +
        [0xFF, 0xFF, 0xFF, 0xFF] + [0x00, 0x00])

    let stream = Data(presentation + palette + object + pgsSegment(type: 0x80, payload: []))

    // Left out on its dimensions, before anything is decoded for it, without aborting the stream.
    let pgs = try stream.withUnsafeBytes { try PGS($0) }
    #expect(pgs.subtitles.isEmpty)
}

/// A decoded subtitle frame paired with the text it should OCR to.
private struct OCRSample: Decodable {
    let source: String
    let width: Int
    let height: Int
    let numberOfColors: Int
    let palette: Data
    let indices: Data
    let text: String
}

private struct OCRSamples: Decodable {
    let frames: [OCRSample]
}

/// Guards OCR accuracy on frames whose glyphs are anti-aliased and outlined.
///
/// The whole-file comparison in `compareOutputs` is dominated by timestamps, so it barely moves when
/// recognition degrades. These frames are compared as text alone, and they cover both a four color
/// VobSub palette and a 256 color PGS one, since the two degrade differently.
///
/// Each frame is a row of unrelated words, so the expected text is the word order the fixture was
/// built with rather than anything a decoder could infer.
@Test func recognizesAntiAliasedFrames() async throws {
    let url = try #require(Bundle.module.url(forResource: "ocr-samples.json", withExtension: nil))
    let samples = try JSONDecoder().decode(OCRSamples.self, from: Data(contentsOf: url)).frames
    #expect(!samples.isEmpty)

    let subtitles = samples.enumerated().map { offset, sample in
        Subtitle(index: offset + 1,
                 startTimestamp: TimeInterval(offset),
                 endTimestamp: TimeInterval(offset) + 1,
                 imageWidth: sample.width,
                 imageHeight: sample.height,
                 imageData: sample.indices,
                 imagePalette: [UInt8](sample.palette),
                 numberOfColors: sample.numberOfColors)
    }

    // One at a time: Vision crashes when it builds recognition engines concurrently.
    let processor = try SubtitleProcessor(for: subtitles, from: 0, withOptions: false, false, "en",
                                          nil, false, false, false, false, makeOutputDirectory(), 1)
    let recognized = try await processor.process().srt.reduce(into: [Int: String]()) { result, subtitle in
        result[subtitle.index] = subtitle.text ?? ""
    }

    for (offset, sample) in samples.enumerated() {
        let actual = recognized[offset + 1] ?? ""
        let score = similarityPercentage(of: sample.text, and: actual)
        #expect(score >= 90.0, "\(sample.source): expected \(sample.text), read \(actual) (\(score)%)")
    }
}

/// Characters drawn as Latin ones are repaired; characters that merely belong to another script are not.
@Test func latinConfusablesAreNormalized() {
    // Cyrillic а and Greek Α are indistinguishable from their Latin counterparts.
    #expect(LatinConfusables.normalize("Eurek\u{0430}") == "Eureka")
    #expect(LatinConfusables.normalize("\u{0391}I") == "AI")

    // Cyrillic Ч and т look nothing like a Latin letter, so guessing at them is not this function's job.
    #expect(LatinConfusables.normalize("\u{0427}\u{0442}\u{0442}") == "\u{0427}\u{0442}\u{0442}")

    // Text already in the Latin script is returned untouched, accents and all.
    #expect(LatinConfusables.normalize("Eureka") == "Eureka")
    #expect(LatinConfusables.normalize("café") == "café")
}

/// Every recognized line carries the other readings the recognizer offered, and none repeats the
/// reading that was chosen.
@Test func alternatesAreOfferedPerLine() async throws {
    let outputPath = try makeOutputDirectory()
    var runner = try macSubtitleOCR.parse([TestFilePaths.sup.path, outputPath, "--json", "--max-threads", "2"])
    try await runner.run()

    let data = try Data(contentsOf: URL(fileURLWithPath: "\(outputPath)/track_0.json"))
    let images = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let lines = images.compactMap { $0["lines"] as? [[String: Any]] }.flatMap(\.self)
    #expect(!lines.isEmpty)

    var linesWithAlternates = 0
    for line in lines {
        let text = try #require(line["text"] as? String)
        let alternates = try #require(line["alternates"] as? [String])
        #expect(!alternates.contains(text))
        #expect(Set(alternates).count == alternates.count)
        if !alternates.isEmpty {
            linesWithAlternates += 1
        }
    }
    #expect(linesWithAlternates > 0)
}

/// Language correction can discard an observation outright rather than return a reading its language
/// model cannot account for, which loses a subtitle holding nothing but a proper noun. Such a frame
/// must still be read: a cue with correct timing and no text at all reads as valid output, so losing
/// one is invisible to anyone not scanning the file for blanks.
@Test func textRejectedByLanguageCorrectionIsStillRead() async throws {
    let subtitle = try renderedSubtitle("APXGP", index: 1)
    let processor = try SubtitleProcessor(for: [subtitle], from: 0, withOptions: false, false, "en",
                                          nil, false, false, false, false, makeOutputDirectory(), 1)
    let recognized = try await processor.process().srt.first?.text ?? ""
    #expect(recognized == "APXGP")
}

/// A frame too small for the recognizer produces nothing at the size it arrives at, and enlarging it
/// is the difference between a reading and a cue with no text. A short line on a DVD subtitle, a lone
/// "Yes." answering a question, is small enough to land there.
@Test func frameTooSmallToRecognizeIsEnlarged() async throws {
    let subtitle = try renderedSubtitle("Wait", index: 1, pointSize: 7)
    let processor = try SubtitleProcessor(for: [subtitle], from: 0, withOptions: false, false, "en",
                                          nil, false, false, false, false, makeOutputDirectory(), 1)
    let recognized = try await processor.process().srt.first?.text ?? ""
    #expect(recognized == "Wait")
}

/// A subpicture is cropped to its ink and drawn over nothing, so its last glyph touches the edge of a
/// transparent frame. Read like that, the recognizer drops the glyph, most often a closing full stop.
@Test func glyphAtTheEdgeOfATransparentFrameIsRead() async throws {
    let subtitle = try renderedSubtitle("OK.", index: 1, pointSize: 28, padding: 0, transparent: true)
    let processor = try SubtitleProcessor(for: [subtitle], from: 0, withOptions: false, false, "en",
                                          nil, false, false, false, false, makeOutputDirectory(), 1)
    let recognized = try await processor.process().srt.first?.text ?? ""
    #expect(recognized == "OK.")
}

@Test func boxesFromThePreparedImageAreMappedBackToTheSubtitle() {
    let prepared = PreparedImage.Geometry(scale: 2, margin: 16)
    #expect(prepared.original(CGRect(x: 16, y: 16, width: 200, height: 40))
        == CGRect(x: 0, y: 0, width: 100, height: 20))
    #expect(prepared.original(CGRect(x: 36, y: 56, width: 10, height: 10))
        == CGRect(x: 10, y: 20, width: 5, height: 5))
}
