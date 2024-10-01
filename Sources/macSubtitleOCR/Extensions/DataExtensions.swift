//
// DataExtensions.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

extension Data {
    // Function to remove null bytes (0x00) from Data
    mutating func removeNullBytes() {
        let nullByte: UInt8 = 0x00
        removeAll { $0 == nullByte }
    }

    func value<T: BinaryInteger>(ofType _: T.Type, at offset: Int, convertEndian: Bool = false) -> T? {
        let right = offset &+ MemoryLayout<T>.size
        guard offset >= 0, right > offset, right <= count else {
            return nil
        }
        let bytes = self[offset ..< right]
        if convertEndian {
            return bytes.reversed().reduce(0) { T($0) << 8 + T($1) }
        } else {
            return bytes.reduce(0) { T($0) << 8 + T($1) }
        }
    }
}
