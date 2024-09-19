//
// SRTError.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/19/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

public enum SRTError: Error {
    case invalidFormat
    case invalidTimeFormat
    case fileNotFound
    case fileReadError
    case fileWriteError
}
