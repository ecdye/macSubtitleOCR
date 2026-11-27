//
// VobSubIDXTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

@Test func vobSubIDXReadsLanguageFromStandardIDLine() throws {
    let idx = try VobSubIDX("id: en, index: 0\n")
    #expect(idx.language == "en")
}

@Test func vobSubIDXReadsLanguageWithoutTrailingComma() throws {
    let idx = try VobSubIDX("id: en\n")
    #expect(idx.language == "en")
}

@Test func vobSubIDXIgnoresIDLineWithoutLanguage() throws {
    let idx = try VobSubIDX("id:\n")
    #expect(idx.language == nil)
}

@Test func vobSubIDXTrimsSpacesAroundLanguage() throws {
    let idx = try VobSubIDX("id:   fr ,index: 1\n")
    #expect(idx.language == "fr")
}

@Test func vobSubIDXKeepsLanguageWhenLaterIDLineIsEmpty() throws {
    let idx = try VobSubIDX("id: de, index: 0\nid: , index: 1\n")
    #expect(idx.language == "de")
}

@Test func vobSubIDXReadsTimestampWithAndWithoutTrailingComma() throws {
    let idx = try VobSubIDX("""
    timestamp: 00:00:01:500, filepos: 000000000
    timestamp: 00:01:02:250 filepos: 000001800
    """)
    #expect(idx.timestamps == [1.5, 62.25])
    #expect(idx.offsets == [0, 0x1800])
}
