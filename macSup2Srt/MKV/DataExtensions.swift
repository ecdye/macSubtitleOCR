//
//  DataExtensions.swift
//  macSup2Srt
//
//  Created by Ethan Dye on 9/14/24.
//

import Foundation

extension Data {
    // Function to remove null bytes (0x00) from Data
    mutating func removeNullBytes() {
        let nullByte: UInt8 = 0x00
        self.removeAll { $0 == nullByte }
    }
}
