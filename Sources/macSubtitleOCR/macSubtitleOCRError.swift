//
// macSubtitleOCRError.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

enum macSubtitleOCRError: Error {
    case fileReadError(_ string: String)
    case fileCreationError
    case fileWriteError
    case ffmpegError(_ string: String)
    case invalidInputFile(_ string: String)
    case invalidRLE(_ string: String)
    case invalidODSDataLength(length: Int)
    case invalidPDSDataLength(length: Int)
    case invalidODSDimensions(_ string: String)
    case invalidVobSubSubpicture(_ string: String)
}

extension macSubtitleOCRError: CustomStringConvertible {
    /// What went wrong, as told to the user when a subtitle or a track is skipped because of it.
    var description: String {
        switch self {
        case let .fileReadError(string), let .ffmpegError(string), let .invalidInputFile(string),
             let .invalidRLE(string), let .invalidODSDimensions(string), let .invalidVobSubSubpicture(string):
            string
        case .fileCreationError:
            "Failed to create a file"
        case .fileWriteError:
            "Failed to write a file"
        case let .invalidODSDataLength(length):
            "Invalid PGS object segment length \(length)"
        case let .invalidPDSDataLength(length):
            "Invalid PGS palette segment length \(length)"
        }
    }
}
