//
// PGSSubtitle.swift
// macSup2Srt
//
// Copyright (c) 2024 Ethan Dye
// Created by Ethan Dye on 9/16/24.
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
