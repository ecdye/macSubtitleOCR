//
// mkvProtocol.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/20/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation

protocol MKVFileHandling {
    var fileHandle: FileHandle { get }
    var eof: UInt64 { get }
    var timestampScale: Double { get set }

    func locateSegment() -> UInt64?
    func locateCluster() -> UInt64?
    func findElement(withID targetID: UInt32, _ tgtID2: UInt32?, avoidCluster: Bool) -> (UInt64?, UInt32?)
}

protocol MKVSubtitleExtracting {
    func getSubtitleTrackData(trackNumber: Int, outPath: String) throws -> String?
}

protocol MKVTrackParsing {
    var tracks: [MKVTrack] { get set }
    func parseTracks(codec: String) throws
}
