//
// PGSSubtitle.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

struct PGSSubtitle {
    var timestamp: TimeInterval = 0
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var imageData: Data = .init()
    var imagePalette: [UInt8] = []
    var endTimestamp: TimeInterval = 0
}
