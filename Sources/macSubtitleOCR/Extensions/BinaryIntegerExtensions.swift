//
// BinaryIntegerExtensions.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/20/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

extension BinaryInteger {
    /// Returns a formatted hexadecimal string with `0x` prefix.
    func hex() -> String {
        String(format: "0x%0X", self as! CVarArg)
    }
}
