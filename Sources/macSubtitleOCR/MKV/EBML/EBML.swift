//
// EBML.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/16/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation

enum EBML {
    static let block: UInt32 = 0xA1
    static let blockGroup: UInt32 = 0xA0
    /// The IDs a BlockGroup may hold: its own children, and the Void and CRC-32 elements allowed anywhere.
    static let blockGroupChildren: Set<UInt32> = [
        block, 0xA2, 0x75A1, 0x9B, 0xFA, 0xFB, 0xFD, 0xA4, 0x75A2, 0x8E, 0xC8, 0xEC, 0xBF
    ]
    static let chapters: UInt32 = 0x1043_A770
    static let cluster: UInt32 = 0x1F43_B675
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let seek: UInt32 = 0x4DBB
    static let seekHead: UInt32 = 0x114D_9B74
    static let seekID: UInt32 = 0x53AB
    static let seekPosition: UInt32 = 0x53AC
    static let segmentID: UInt32 = 0x1853_8067
    static let segmentInfo: UInt32 = 0x1549_A966
    /// The IDs a Segment may hold: SeekHead, Info, Tracks, Cluster, Cues, Attachments, Chapters and Tags, and
    /// the Void and CRC-32 elements allowed anywhere.
    static let segmentChildren: Set<UInt32> = [
        seekHead, segmentInfo, tracksID, cluster, 0x1C53_BB6B, 0x1941_A469, chapters, 0x1254_C367, 0xEC, 0xBF
    ]
    static let simpleBlock: UInt32 = 0xA3
    static let timestamp: UInt32 = 0xE7
    static let timestampScale: UInt32 = 0x2AD7B1
    static let tracksID: UInt32 = 0x1654_AE6B
    static let trackEntryID: UInt32 = 0xAE
    static let trackTypeID: UInt32 = 0x83
    static let trackNumberID: UInt32 = 0xD7
}
