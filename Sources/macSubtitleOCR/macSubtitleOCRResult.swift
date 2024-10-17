//
// macSubtitleOCRResult.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/25/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

struct macSubtitleOCRResult {
    var trackNumber: Int
    var srt: [Int: Subtitle]
    var json: [Int: SubtitleJSONResult]
}

struct SubtitleJSONResult: Sendable {
    let image: Int
    let lines: [SubtitleLine]
    let text: String
}

struct SubtitleLine: Sendable {
    let text: String
    let confidence: Float
    let x: Int
    let width: Int
    let y: Int
    let height: Int
}
