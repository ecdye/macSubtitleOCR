//
// macSubtitleOCRTestHelpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/3/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

// Function to compute the Levenshtein Distance between two strings
func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let empty = [Int](repeating: 0, count: rhs.count)
    var last = [Int](0 ... rhs.count)

    for (i, char1) in lhs.enumerated() {
        var cur = [i + 1] + empty
        for (j, char2) in rhs.enumerated() {
            cur[j + 1] = char1 == char2 ? last[j] : min(last[j], last[j + 1], cur[j]) + 1
        }
        last = cur
    }
    return last.last!
}

// Function to calculate the similarity percentage
func similarityPercentage(of lhs: String, and rhs: String) -> Double {
    let distance = levenshteinDistance(lhs, rhs)
    let maxLength = max(lhs.count, rhs.count)

    if maxLength == 0 {
        return 100.0 // Both strings are empty, they match 100%
    }

    return (1.0 - Double(distance) / Double(maxLength)) * 100
}
