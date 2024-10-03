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

// MARK: - Tests

@Test func pgsMKV() throws {
    // Setup files
    let outputPath = (FileManager.default.temporaryDirectory.path + "/output")
    let mkvPath = Bundle.module.url(forResource: "test.mkv", withExtension: nil)!.absoluteString
        .replacing("file://", with: "")
    let goodSRTPath = Bundle.module.url(forResource: "test.srt", withExtension: nil)!.absoluteString
        .replacing("file://", with: "")
    let goodJSONPath = Bundle.module.url(forResource: "test.json", withExtension: nil)!.absoluteString
        .replacing("file://", with: "")

    // Run tests
    let options = [mkvPath, outputPath, "--json", "--language-correction"]
    var runner = try macSubtitleOCR.parseAsRoot(options)
    try runner.run()

    // Compare output
    let srtExpectedOutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
    let srt0ActualOutput = try String(contentsOfFile: outputPath + "/track_0.srt", encoding: .utf8)
    let srt1ActualOutput = try String(contentsOfFile: outputPath + "/track_1.srt", encoding: .utf8)
    let jsonExpectedOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
    let json0ActualOutput = try String(contentsOfFile: outputPath + "/track_0.json", encoding: .utf8)
    let json1ActualOutput = try String(contentsOfFile: outputPath + "/track_1.json", encoding: .utf8)

    let srt0Match = similarityPercentage(srtExpectedOutput, srt0ActualOutput)
    let srt1Match = similarityPercentage(srtExpectedOutput, srt1ActualOutput)
    let json0Match = similarityPercentage(jsonExpectedOutput, json0ActualOutput)
    let json1Match = similarityPercentage(jsonExpectedOutput, json1ActualOutput)

    #expect(srt0Match >= 95.0)
    #expect(srt1Match >= 95.0)
    #expect(json0Match >= 95.0)
    #expect(json1Match >= 95.0)
}

@Test func pgsSUP() throws {
    // Setup files
    let outputPath = (FileManager.default.temporaryDirectory.path + "/output")
    let supPath = Bundle.module.url(forResource: "test.sup", withExtension: nil)!.absoluteString
        .replacing("file://", with: "")
    let goodSRTPath = Bundle.module.url(forResource: "test.srt", withExtension: nil)!.absoluteString
        .replacing("file://", with: "")
    let goodJSONPath = Bundle.module.url(forResource: "test.json", withExtension: nil)!.absoluteString
        .replacing("file://", with: "")

    // Run tests
    let options = [supPath, outputPath, "--json", "--language-correction"]
    var runner = try macSubtitleOCR.parseAsRoot(options)
    try runner.run()

    // Compare output
    let srtExpectedOutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
    let srtActualOutput = try String(contentsOfFile: outputPath + "/track_0.srt", encoding: .utf8)
    let jsonExpectedOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
    let jsonActualOutput = try String(contentsOfFile: outputPath + "/track_0.json", encoding: .utf8)

    let srtMatch = similarityPercentage(srtExpectedOutput, srtActualOutput)
    let jsonMatch = similarityPercentage(jsonExpectedOutput, jsonActualOutput)

    #expect(srtMatch >= 95.0)
    #expect(jsonMatch >= 95.0)
}

// MARK: - Helpers

// Function to compute the Levenshtein Distance between two strings
func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let lhsChars = Array(lhs)
    let rhsChars = Array(rhs)

    let lhsLength = lhsChars.count
    let rhsLength = rhsChars.count

    // If one of the strings is empty, the distance is the length of the other
    if lhsLength == 0 { return rhsLength }
    if rhsLength == 0 { return lhsLength }

    // Use two rows instead of the full matrix
    var previousRow = [Int](0 ... rhsLength)
    var currentRow = [Int](repeating: 0, count: rhsLength + 1)

    for i in 1 ... lhsLength {
        currentRow[0] = i

        for j in 1 ... rhsLength {
            let cost = lhsChars[i - 1] == rhsChars[j - 1] ? 0 : 1
            currentRow[j] = min(
                previousRow[j] + 1, // Deletion
                currentRow[j - 1] + 1, // Insertion
                previousRow[j - 1] + cost // Substitution
            )
        }

        // Swap the rows
        swap(&previousRow, &currentRow)
    }

    return previousRow[rhsLength]
}

// Function to calculate the similarity percentage
func similarityPercentage(_ lhs: String, _ rhs: String) -> Double {
    let distance = levenshteinDistance(lhs, rhs)
    let maxLength = max(lhs.count, rhs.count)

    if maxLength == 0 {
        return 100.0 // Both strings are empty, they match 100%
    }

    return (1.0 - Double(distance) / Double(maxLength)) * 100
}
