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
    case mkv_pgs
    case mkv_vobsub
    case mkv_pgs_vobsub

    var path: String {
        switch self {
        case .sup:
            Bundle.module.url(forResource: "sintel.sup", withExtension: nil)!.path
        case .sub:
            Bundle.module.url(forResource: "sintel.sub", withExtension: nil)!.path
        case .mkv_pgs:
            Bundle.module.url(forResource: "sintel_pgs.mks", withExtension: nil)!.path
        case .mkv_vobsub:
            Bundle.module.url(forResource: "sintel_vobsub.mks", withExtension: nil)!.path
        case .mkv_pgs_vobsub:
            Bundle.module.url(forResource: "sintel_pgs_vobsub.mks", withExtension: nil)!.path
        }
    }
}
