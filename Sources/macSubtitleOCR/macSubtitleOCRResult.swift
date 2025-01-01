//
// macSubtitleOCRResult.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/25/24.
// Copyright © 2024-2025 Ethan Dye. All rights reserved.
//

struct macSubtitleOCRResult {
    var trackNumber: Int
    var srt: [Subtitle]
    var json: [SubtitleJSONResult]
}

struct SubtitleJSONResult: Sendable {
    let index: Int
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
