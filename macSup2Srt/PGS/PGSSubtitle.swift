//
// PGSSubtitle.swift
// macSup2Srt
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

public struct PGSSubtitle {
    public var timestamp: TimeInterval = 0
    public var imageWidth: Int = 0
    public var imageHeight: Int = 0
    public var imageData: Data = .init()
    public var imagePalette: [UInt8] = []
    public var endTimestamp: TimeInterval = 0
}
