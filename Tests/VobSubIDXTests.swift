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

// MARK: - Streams

@Test func vobSubIDXSplitsTimestampsByStream() throws {
    let idx = try VobSubIDX("""
    palette: 000000, ffffff
    id: en, index: 0
    timestamp: 00:00:01:000, filepos: 000000000
    timestamp: 00:00:05:000, filepos: 000001000
    id: fr, index: 1
    timestamp: 00:00:02:000, filepos: 000000800
    timestamp: 00:00:06:000, filepos: 000001800
    """)
    #expect(idx.streams.map(\.index) == [0, 1])
    #expect(idx.streams.map(\.language) == ["en", "fr"])
    #expect(idx.streams.map(\.timestamps) == [[1, 5], [2, 6]])
    #expect(idx.streams.map(\.offsets) == [[0, 0x1000], [0x800, 0x1800]])
    #expect(idx.palette == [0, 0, 0, 0xFF, 0xFF, 0xFF])
    // The single-stream accessors describe the first stream only.
    #expect(idx.timestamps == [1, 5])
    #expect(idx.offsets == [0, 0x1000])
    #expect(idx.language == "en")
}

@Test func vobSubIDXPutsTimestampsBeforeAnyIDInStreamZero() throws {
    let idx = try VobSubIDX("""
    timestamp: 00:00:01:000, filepos: 000000000
    id: fr, index: 1
    timestamp: 00:00:02:000, filepos: 000000800
    id: en, index: 0
    timestamp: 00:00:03:000, filepos: 000001000
    """)
    #expect(idx.streams.map(\.index) == [0, 1])
    #expect(idx.streams.map(\.language) == ["en", "fr"])
    #expect(idx.streams.map(\.timestamps) == [[1, 3], [2]])
}

@Test func vobSubIDXKeepsStreamsWithoutTimestamps() throws {
    let idx = try VobSubIDX("id: en, index: 0\nid: fr, index: 1\n")
    #expect(idx.streams.map(\.index) == [0, 1])
    #expect(idx.streams.map(\.timestamps) == [[], []])
}

@Test func vobSubIDXRejectsAStreamIndexWithoutASubstreamID() {
    #expect(throws: macSubtitleOCRError.self) { _ = try VobSubIDX("id: en, index: 32\n") }
}

// MARK: - Delay

@Test func vobSubIDXAppliesDelayLikeFFmpeg() throws {
    // As in FFmpeg's vobsub_read_header, each delay replaces the last one and carries on into
    // later id blocks; missing fields are 0.
    let idx = try VobSubIDX("""
    id: en, index: 0
    timestamp: 00:00:10:000, filepos: 000000000
    delay: 00:00:01:500
    timestamp: 00:00:20:000, filepos: 000000800
    delay: -00:00:00:250
    timestamp: 00:00:30:000, filepos: 000001000
    id: fr, index: 1
    timestamp: 00:00:40:000, filepos: 000001800
    delay: +0:0:2
    timestamp: 00:00:50:000, filepos: 000002000
    """)
    #expect(idx.streams.map(\.timestamps) == [[10, 21.5, 29.75], [39.75, 52]])
    #expect(idx.streams.map(\.delays) == [[0, 1.5, -0.25], [-0.25, 2]])
}

@Test func vobSubIDXDelayCanMoveATimestampBeforeZero() throws {
    let idx = try VobSubIDX("""
    delay: -00:00:01:000
    timestamp: 00:00:00:500, filepos: 000000000
    """)
    #expect(idx.timestamps == [-0.5])
}
