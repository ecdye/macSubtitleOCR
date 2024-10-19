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
        self = filter { $0 != 0x00 }
    }

    func getUInt16BE(at offset: Int = 0) -> UInt16? {
        guard count >= offset + 2 else { return nil }
        return withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self).bigEndian }
    }

    /* Useful for debugging purposes
     func hexEncodedString() -> String {
         map { String(format: "%02hhx", $0) }.joined()
     }
     */
}
