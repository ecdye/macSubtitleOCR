//
// MKVTrack.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

struct MKVTrack {
    var trackNumber: Int
    var codecID: String
    var trackData: Data
    var idxData: String?
    var language: String?
}
