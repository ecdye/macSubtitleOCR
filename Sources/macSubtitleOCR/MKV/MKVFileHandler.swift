import Foundation
import os

class MKVFileHandler: MKVFileHandling {
    var fileHandle: FileHandle
    var eof: UInt64
    var timestampScale: Double = 1000000.0 // Default value if not specified in a given MKV file
    var logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "mkv")

    init(filePath: String) throws {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw macSubtitleOCRError.fileReadError
        }
        self.fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))
        self.eof = fileHandle.seekToEndOfFile()
        fileHandle.seek(toFileOffset: 0)
    }

    deinit {
        fileHandle.closeFile()
    }

    func locateSegment() -> UInt64? {
        if let (segmentSize, _) = findElement(withID: EBML.segmentID, avoidCluster: true) as? (UInt64, UInt32) {
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
        while let (elementID, elementSize, elementOffset) = tryParseElement() {
            // Ensure we stop if we have reached or passed the EOF
            if fileHandle.offsetInFile >= eof {
                return (nil, nil)
            }

            // If, by chance, we find a TimestampScale element, update it from the default
            if elementID == EBML.timestampScale {
                timestampScale = Double(readFixedLengthNumber(
                    fileHandle: fileHandle,
                    length: Int(elementSize)))
                // swiftformat:disable:next redundantSelf
                logger.debug("Found timestamp scale: \(self.timestampScale)")
                return (nil, nil)
            }

            // If a Cluster header is encountered, seek back to the start of the Cluster
            if elementID == EBML.cluster && avoidCluster {
                logger.debug("Encountered Cluster: seeking back to before the cluster header")
                fileHandle.seek(toFileOffset: elementOffset)
                return (nil, nil)
            }

            // If the element matches the target ID (or secondary ID), return its size
            if elementID == targetID || (tgtID2 != nil && elementID == tgtID2!) {
                return (elementSize, elementID)
            } else {
                // Skip over the element's data by seeking to its end
                logger.debug("Found: \(elementID), but not \(targetID), skipping element")
                fileHandle.seek(toFileOffset: fileHandle.offsetInFile + elementSize)
            }
        }

        return (nil, nil)
    }

    func tryParseElement() -> (elementID: UInt32, elementSize: UInt64, oldOffset: UInt64)? {
        let oldOffset = fileHandle.offsetInFile
        let (elementID, elementSize) = readEBMLElement(from: fileHandle)
        return (elementID, elementSize, oldOffset: oldOffset)
    }
}
