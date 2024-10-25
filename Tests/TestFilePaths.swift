//
// TestFilePaths.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/19/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

enum TestFilePaths: CaseIterable {
    case sup
    case sub
    case mkv

    var path: String {
        switch self {
        case .sup:
            Bundle.module.url(forResource: "sintel.sup", withExtension: nil)!.path
        case .sub:
            Bundle.module.url(forResource: "sintel.sub", withExtension: nil)!.path
        case .mkv:
            Bundle.module.url(forResource: "sintel.mks", withExtension: nil)!.path
        }
    }
}
