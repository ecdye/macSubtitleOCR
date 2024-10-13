//
// macSubtitleOCRTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

let supPath = Bundle.module.url(forResource: "test.sup", withExtension: nil)!.path
let subPath = Bundle.module.url(forResource: "test.sub", withExtension: nil)!.path
let mkvPath = Bundle.module.url(forResource: "test.mkv", withExtension: nil)!.path
let goodSRTPath = Bundle.module.url(forResource: "test.srt", withExtension: nil)!.path
let goodJSONPath = Bundle.module.url(forResource: "test.json", withExtension: nil)!.path
let ffmpegOptions = ["--json"]
let internalOptions = ["--json", "--internal-decoder"]

@Suite struct ffmpegDecoderTests {
    let srtExpectedOutput: String
    let jsonExpectedOutput: String

    init() throws {
        srtExpectedOutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
        jsonExpectedOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
    }

    @Test func ffmpegMKV_PGS() throws {
        let outputPath = URL.temporaryDirectory.path

        // Run tests
        let options = [mkvPath, outputPath] + ffmpegOptions
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()

        // Compare output
        let srt0ActualOutput = try String(contentsOfFile: outputPath + "/track_0.srt", encoding: .utf8)
        let srt1ActualOutput = try String(contentsOfFile: outputPath + "/track_1.srt", encoding: .utf8)
        let json0ActualOutput = try String(contentsOfFile: outputPath + "/track_0.json", encoding: .utf8)
        let json1ActualOutput = try String(contentsOfFile: outputPath + "/track_1.json", encoding: .utf8)

        let srt0Match = similarityPercentage(srtExpectedOutput, srt0ActualOutput)
        let srt1Match = similarityPercentage(srtExpectedOutput, srt1ActualOutput)
        let json0Match = similarityPercentage(jsonExpectedOutput, json0ActualOutput)
        let json1Match = similarityPercentage(jsonExpectedOutput, json1ActualOutput)

        // Lower threshold due to timestamp differences
        #expect(srt0Match >= 85.0)
        #expect(srt1Match >= 85.0)
        #expect(json0Match >= 95.0)
        #expect(json1Match >= 95.0)
    }

    @Test func ffmpegPGS() throws {
        let outputPath = URL.temporaryDirectory.path

        // Run tests
        let options = [supPath, outputPath] + ffmpegOptions
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()

        // Compare output
        let srtActualOutput = try String(contentsOfFile: outputPath + "/track_0.srt", encoding: .utf8)
        let jsonActualOutput = try String(contentsOfFile: outputPath + "/track_0.json", encoding: .utf8)

        let srtMatch = similarityPercentage(srtExpectedOutput, srtActualOutput)
        let jsonMatch = similarityPercentage(jsonExpectedOutput, jsonActualOutput)

        #expect(srtMatch >= 85.0) // Lower threshold due to timestamp differences
        #expect(jsonMatch >= 95.0)
    }

    @Test func ffmpegVobSub() throws {
        let outputPath = URL.temporaryDirectory.path

        // Run tests
        let options = [subPath, outputPath] + ffmpegOptions
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()

        // Compare output
        let srtActualOutput = try String(contentsOfFile: outputPath + "/track_0.srt", encoding: .utf8)
        let jsonActualOutput = try String(contentsOfFile: outputPath + "/track_0.json", encoding: .utf8)

        let srtMatch = similarityPercentage(srtExpectedOutput, srtActualOutput)
        let jsonMatch = similarityPercentage(jsonExpectedOutput, jsonActualOutput)

        #expect(srtMatch >= 85.0) // Lower threshold due to timestamp differences
        #expect(jsonMatch >= 95.0)
    }
}

@Suite struct internalDecoderTests {
    let srtExpectedOutput: String
    let jsonExpectedOutput: String

    init() throws {
        srtExpectedOutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
        jsonExpectedOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
    }

    @Test func internalMKV_PGS() throws {
        let outputPath = URL.temporaryDirectory.path

        // Run tests
        let options = [mkvPath, outputPath] + internalOptions
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()

        // Compare output
        let srt0ActualOutput = try String(contentsOfFile: outputPath + "/track_0.srt", encoding: .utf8)
        let srt1ActualOutput = try String(contentsOfFile: outputPath + "/track_1.srt", encoding: .utf8)
        let json0ActualOutput = try String(contentsOfFile: outputPath + "/track_0.json", encoding: .utf8)
        let json1ActualOutput = try String(contentsOfFile: outputPath + "/track_1.json", encoding: .utf8)

        let srt0Match = similarityPercentage(srtExpectedOutput, srt0ActualOutput)
        let srt1Match = similarityPercentage(srtExpectedOutput, srt1ActualOutput)
        let json0Match = similarityPercentage(jsonExpectedOutput, json0ActualOutput)
        let json1Match = similarityPercentage(jsonExpectedOutput, json1ActualOutput)

        // Lower threshold due to timestamp differences
        #expect(srt0Match >= 85.0)
        #expect(srt1Match >= 85.0)
        #expect(json0Match >= 95.0)
        #expect(json1Match >= 95.0)
    }

    @Test func internalPGS() throws {
        let outputPath = URL.temporaryDirectory.path

        // Run tests
        let options = [supPath, outputPath] + internalOptions
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()

        // Compare output
        let srtActualOutput = try String(contentsOfFile: outputPath + "/track_0.srt", encoding: .utf8)
        let jsonActualOutput = try String(contentsOfFile: outputPath + "/track_0.json", encoding: .utf8)

        let srtMatch = similarityPercentage(srtExpectedOutput, srtActualOutput)
        let jsonMatch = similarityPercentage(jsonExpectedOutput, jsonActualOutput)

        #expect(srtMatch >= 85.0) // Lower threshold due to timestamp differences
        #expect(jsonMatch >= 95.0)
    }

    @Test func internalVobSub() throws {
        let outputPath = URL.temporaryDirectory.path

        // Run tests
        let options = [subPath, outputPath] + internalOptions
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()

        // Compare output
        let srtActualOutput = try String(contentsOfFile: outputPath + "/track_0.srt", encoding: .utf8)
        let jsonActualOutput = try String(contentsOfFile: outputPath + "/track_0.json", encoding: .utf8)

        let srtMatch = similarityPercentage(srtExpectedOutput, srtActualOutput)
        let jsonMatch = similarityPercentage(jsonExpectedOutput, jsonActualOutput)

        #expect(srtMatch >= 85.0) // Lower threshold due to timestamp differences
        #expect(jsonMatch >= 95.0)
    }
}
