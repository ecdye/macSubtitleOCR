//
// MKVFileHandler.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 9/22/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import Foundation
import os

class MKVFileHandler {
    // MARK: - Properties

    let fileHandle: FileHandle
    let endOfFile: UInt64
    let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "MKV")
    let ebmlParser: EBMLParser

    // MARK: - Lifecycle

    init(filePath: String) throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw macSubtitleOCRError.fileReadError("File does not exist at path: \(filePath)")
        }
        do {
            try fileHandle = FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        } catch {
            throw macSubtitleOCRError.fileReadError("Failed to open file: \(filePath)")
        }
        endOfFile = fileHandle.seekToEndOfFile()
        fileHandle.seek(toFileOffset: 0)
        ebmlParser = EBMLParser(fileHandle: fileHandle)
    }

    deinit {
        fileHandle.closeFile()
    }

    // MARK: - Functions

    func locateSegment() -> UInt64? {
        if let (segmentSize, _) = findElement(withID: EBML.segmentID) as? (UInt64, UInt32) {
            return segmentSize
        }
        return nil
    }

    func locateCluster() -> UInt64? {
        if let (clusterSize, _) = findElement(withID: EBML.cluster, avoidCluster: false) as? (UInt64, UInt32) {
            return clusterSize
        }
        return nil
    }

    // Find EBML element by ID, avoiding Cluster header
    func findElement(withID targetID: UInt32, _ tgtID2: UInt32? = nil, avoidCluster: Bool = true) -> (UInt64?, UInt32?) {
        var previousOffset = fileHandle.offsetInFile
        while let (elementID, elementSize) = tryParseElement() {
            guard fileHandle.offsetInFile < endOfFile else { return (nil, nil) }

            if elementID == EBML.cluster && avoidCluster {
                logger.debug("Encountered Cluster: seeking back to before the cluster header")
                fileHandle.seek(toFileOffset: previousOffset)
                return (nil, nil)
            }

            if elementID == targetID || (tgtID2 != nil && elementID == tgtID2!) {
                return (elementSize, elementID)
            } else {
                logger.debug("\(elementID.hex()) != \(targetID.hex()), skipping element")
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
            previousOffset = fileHandle.offsetInFile
        }
        return (nil, nil)
    }

    func tryParseElement() -> (elementID: UInt32, elementSize: UInt64)? {
        ebmlParser.readEBMLElement()
    }
}
