//
// macSubtitleOCRTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/18/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

@Suite struct macSubtitleOCRTests {
    @Test func pgsMKV() throws {
        // Setup files
        let manager = FileManager.default
        let srtPath = (manager.temporaryDirectory.path + "/test.srt")
        let jsonPath = (manager.temporaryDirectory.path + "/test.json")
        let mkvPath = Bundle.module.url(forResource: "test.mkv", withExtension: nil)!.absoluteString.replacing("file://", with: "")
        let goodSRTPath = Bundle.module.url(forResource: "test.srt", withExtension: nil)!.absoluteString.replacing("file://", with: "")
        let goodJSONPath = Bundle.module.url(forResource: "test.json", withExtension: nil)!.absoluteString.replacing("file://", with: "")

        // Run tests
        let options = [mkvPath, srtPath, "--json", jsonPath, "--language-correction"]
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()

        // Compare output
        let srtExpectedOutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
        let srtActualOutput = try String(contentsOfFile: srtPath, encoding: .utf8)
        let jsonExpectedOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
        let jsonActualOutput = try String(contentsOfFile: jsonPath, encoding: .utf8)

        let srtMatch = similarityPercentage(srtExpectedOutput, srtActualOutput)
        let jsonMatch = similarityPercentage(jsonExpectedOutput, jsonActualOutput)

        #expect(srtMatch >= 90.0)
        #expect(jsonMatch >= 90.0)
    }

    @Test func pgsSUP() throws {
        // Setup files
        let manager = FileManager.default
        let srtPath = (manager.temporaryDirectory.path + "/test.srt")
        let jsonPath = (manager.temporaryDirectory.path + "/test.json")
        let supPath = Bundle.module.url(forResource: "test.sup", withExtension: nil)!.absoluteString.replacing("file://", with: "")
        let goodSRTPath = Bundle.module.url(forResource: "test.srt", withExtension: nil)!.absoluteString.replacing("file://", with: "")
        let goodJSONPath = Bundle.module.url(forResource: "test.json", withExtension: nil)!.absoluteString.replacing("file://", with: "")

        // Run tests
        let options = [supPath, srtPath, "--json", jsonPath, "--language-correction"]
        var runner = try macSubtitleOCR.parseAsRoot(options)
        try runner.run()

        // Compare output
        let srtExpectedOutput = try String(contentsOfFile: goodSRTPath, encoding: .utf8)
        let srtActualOutput = try String(contentsOfFile: srtPath, encoding: .utf8)
        let jsonExpectedOutput = try String(contentsOfFile: goodJSONPath, encoding: .utf8)
        let jsonActualOutput = try String(contentsOfFile: jsonPath, encoding: .utf8)

        let srtMatch = similarityPercentage(srtExpectedOutput, srtActualOutput)
        let jsonMatch = similarityPercentage(jsonExpectedOutput, jsonActualOutput)

        #expect(srtMatch >= 90.0)
        #expect(jsonMatch >= 90.0)
    }

    // Function to compute the Levenshtein Distance between two strings
    func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let lhsLength = lhsChars.count
        let rhsLength = rhsChars.count

        var distanceMatrix = [[Int]](repeating: [Int](repeating: 0, count: rhsLength + 1), count: lhsLength + 1)

        // Initialize the matrix
        for i in 0 ... lhsLength {
            distanceMatrix[i][0] = i
        }
        for j in 0 ... rhsLength {
            distanceMatrix[0][j] = j
        }

        // Compute the distance
        for i in 1 ... lhsLength {
            for j in 1 ... rhsLength {
                let cost = lhsChars[i - 1] == rhsChars[j - 1] ? 0 : 1
                distanceMatrix[i][j] = min(
                    distanceMatrix[i - 1][j] + 1, // Deletion
                    distanceMatrix[i][j - 1] + 1, // Insertion
                    distanceMatrix[i - 1][j - 1] + cost // Substitution
                )
            }
        }

        return distanceMatrix[lhsLength][rhsLength]
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
}
