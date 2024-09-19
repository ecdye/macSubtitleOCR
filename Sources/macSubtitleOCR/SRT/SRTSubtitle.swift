//
// SRTSubtitle.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

public struct SRTSubtitle {
    public var index: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
}
