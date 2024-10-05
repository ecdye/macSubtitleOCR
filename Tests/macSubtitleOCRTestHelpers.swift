//
// macSubtitleOCRTestHelpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/3/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

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
