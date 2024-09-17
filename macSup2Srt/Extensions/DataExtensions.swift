//
// DataExtensions.swift
// macSup2Srt
//
// Copyright (c) 2024 Ethan Dye
// Created by Ethan Dye on 9/16/24.
//

import Foundation

extension Data {
    // Function to remove null bytes (0x00) from Data
    mutating func removeNullBytes() {
        let nullByte: UInt8 = 0x00
        removeAll { $0 == nullByte }
    }
}
