//
// TextOutputStreamExtensions.swift
// macSup2Srt
//
// Copyright (c) 2024 Ethan Dye
// Created by Ethan Dye on 9/16/24.
//

import Foundation

public struct StandardErrorOutputStream: TextOutputStream {
    public mutating func write(_ string: String) { fputs(string, stderr) }
}
