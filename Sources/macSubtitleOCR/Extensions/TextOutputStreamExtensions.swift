//
// TextOutputStreamExtensions.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/24/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

struct FileHandleOutputStream: TextOutputStream {
    private let fileHandle: FileHandle
    let encoding: String.Encoding

    init(_ fileHandle: FileHandle, encoding: String.Encoding = .utf8) {
        self.fileHandle = fileHandle
        self.encoding = encoding
    }

    mutating func write(_ string: String) {
        if let data = string.data(using: encoding) {
            fileHandle.write(data)
        }
    }
}
