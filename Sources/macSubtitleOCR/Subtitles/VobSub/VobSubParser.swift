//
// VobSubParser.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/4/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
import os

struct VobSubParser {
    /// The color map and alpha a stream's subpictures select, as the set color (0x03) and set
    /// contrast (0x04) commands last set them.
    ///
    /// Like FFmpeg's `dvdsubdec`, which keeps them in its decoder context, they carry over from one
    /// subpicture of a stream to the next, so a subpicture without either command is drawn with the
    /// ones before it. Before any subpicture sets them they are all zero, as in FFmpeg: every color
    /// is the first of the idx palette and fully transparent.
    struct Colors {
        var colormap = [UInt8](repeating: 0, count: 4)
        var alpha = [UInt8](repeating: 0, count: 4)
    }

    // MARK: - Properties

    let subtitle: Subtitle
    /// The stream's colors after this subpicture, for the next one to start from.
    private(set) var colors: Colors
    /// The idx palette's 16 RGB colors, or nil when the idx has no palette.
    private let masterPalette: [UInt8]?
    private let substream: Int?
    private let delay: TimeInterval

    // MARK: - Lifecycle

    /// Read the subpicture whose first packet is at `offset`.
    ///
    /// - Parameters:
    ///   - idxPalette: The idx palette's 16 RGB colors, or nil when the idx has no palette.
    ///   - substream: The idx stream index the subpicture belongs to, or nil to read every packet.
    ///     A packet belongs to stream `n` when the low 5 bits of its substream ID are `n`, as FFmpeg
    ///     checks it. DVD subpictures use IDs `0x20 + n`, and VobSub tracks extracted from an MKV
    ///     are written with `0x00` for stream 0, which this also accepts.
    ///   - delay: The idx `delay:` in seconds, added to the presentation timestamp of the packet.
    ///   - colors: The stream's colors as the subpictures before this one left them.
    init(index: Int, buffer: UnsafeRawBufferPointer, timestamp: TimeInterval, offset: UInt64,
         nextOffset: UInt64, idxPalette: [UInt8]?, substream: Int? = nil, delay: TimeInterval = 0,
         colors: Colors = Colors()) throws {
        subtitle = Subtitle(index: index, startTimestamp: timestamp, imageData: .init(), numberOfColors: 16)
        masterPalette = idxPalette
        self.substream = substream
        self.delay = delay
        self.colors = colors
        try readSubFrame(buffer: buffer, offset: offset, nextOffset: nextOffset)
        try decodeImage()
        decodePalette()
    }

    // MARK: - Methods

    mutating func readSubFrame(buffer: UnsafeRawBufferPointer, offset: UInt64, nextOffset: UInt64) throws {
        var firstPacketFound = false
        var controlOffset: Int?
        var controlSize: Int?
        var controlHeaderCopied = 0
        var controlHeader = Data()
        var relativeControlOffset = 0
        var rleLengthFound = 0

        guard var offset = Int(exactly: offset), offset < buffer.count else {
            throw macSubtitleOCRError.invalidVobSubSubpicture(
                "VobSub offset \(offset) is past the end of the file (\(buffer.count) bytes)")
        }
        // Where the subpicture's packets end: the next subtitle's filepos, or the end of the file
        // when the idx does not list them in order.
        let end = nextOffset > offset ? Int(min(nextOffset, UInt64(buffer.count))) : buffer.count
        repeat {
            let startOffset = offset
            // Padding ending the previous pack, or packets of other streams, can stand where the next
            // pack header is expected. The bytes from `startOffset` to the subpicture's own PES packet,
            // whatever they hold, push the control sequences further on.
            offset = try skipOtherPackets(buffer, from: offset, to: end)
            guard offset < end, (try? buffer.bigEndian(UInt32.self, at: offset)) == MPEG2PacketType.psPacket else {
                guard firstPacketFound else {
                    throw macSubtitleOCRError.invalidVobSubSubpicture("No VobSub PS packet at offset \(offset)")
                }
                print("No VobSub PS packet at offset \(offset), trying to decode anyway")
                break
            }
            offset += 4

            offset += 6 // System clock reference
            offset += 3 // Multiplexer rate
            let stuffingLength = try buffer.bigEndian(UInt8.self, at: offset) & 7
            offset += 1 + Int(stuffingLength)

            // A system header, padding, or packets of other streams can come before the subpicture's
            // packet in its pack, which may hold none of it.
            offset = try skipOtherPackets(buffer, from: offset, to: end)
            if firstPacketFound, offset < end,
               (try? buffer.bigEndian(UInt32.self, at: offset)) == MPEG2PacketType.psPacket {
                controlOffset! += offset - startOffset
                continue
            }

            guard (try? buffer.bigEndian(UInt32.self, at: offset)) == MPEG2PacketType.pesPacket else {
                guard firstPacketFound else {
                    throw macSubtitleOCRError.invalidVobSubSubpicture("No VobSub PES packet at offset \(offset)")
                }
                print("No VobSub PES packet at offset \(offset), trying to decode anyway")
                break
            }
            offset += 4

            let pesLength = try Int(buffer.bigEndian(UInt16.self, at: offset))
            if pesLength == 0 {
                throw macSubtitleOCRError.invalidVobSubSubpicture("VobSub PES packet length is 0 at offset \(offset)")
            }
            offset += 2
            let nextPSOffset = offset + pesLength
            guard nextPSOffset <= buffer.count else {
                throw macSubtitleOCRError.invalidVobSubSubpicture(
                    "VobSub PES packet at offset \(offset) runs \(nextPSOffset - buffer.count) bytes past the end of the file")
            }

            offset += 1 // Skip PES miscellaneous data
            let extByteOne = try buffer.bigEndian(UInt8.self, at: offset)
            offset += 1
            // The PTS flag, not the header length, says whether a timestamp is present: a packet
            // continuing a subpicture may pad its header with 0xFF stuffing bytes instead.
            let firstPacket = (extByteOne & 0x80) == 0x80

            let ptsDataLength = try Int(buffer.bigEndian(UInt8.self, at: offset))
            offset += 1

            // Packets of the other streams in the file can sit between the packets of this subpicture.
            let streamID = try buffer.bigEndian(UInt8.self, at: offset + ptsDataLength)
            if let substream, Int(streamID & 0x1F) != substream {
                guard firstPacketFound else {
                    throw macSubtitleOCRError.invalidVobSubSubpicture(
                        "VobSub packet at offset \(startOffset) belongs to substream " +
                            "\(String(format: "0x%02X", streamID)), not stream \(substream)")
                }
                // Skip the packet whole. The control sequences then start that much further on.
                controlOffset! += nextPSOffset - startOffset
                offset = nextPSOffset
                continue
            }

            if firstPacket, ptsDataLength >= 5 {
                let pts = try (0 ..< 5).map { try buffer.bigEndian(UInt8.self, at: offset + $0) }
                var presentationTimestamp: UInt64 = 0
                presentationTimestamp = UInt64(pts[4]) >> 1
                presentationTimestamp += UInt64(pts[3]) << 7
                presentationTimestamp += UInt64(pts[2] & 0xFE) << 14
                presentationTimestamp += UInt64(pts[1]) << 22
                presentationTimestamp += UInt64(pts[0] & 0x0E) << 29
                subtitle.startTimestamp = TimeInterval(presentationTimestamp) / 90000 + delay
            }
            offset += ptsDataLength

            offset += 1 // Stream ID, checked above

            var trueHeaderSize = offset - startOffset
            if firstPacket, ptsDataLength >= 5 {
                let size = try Int(buffer.bigEndian(UInt16.self, at: offset))
                offset += 2
                relativeControlOffset = try Int(buffer.bigEndian(UInt16.self, at: offset))
                offset += 2
                // The control sequences follow the 4 byte size and control offset and the RLE data,
                // and end the subpicture.
                guard relativeControlOffset >= 4, relativeControlOffset <= size else {
                    throw macSubtitleOCRError.invalidVobSubSubpicture(
                        "VobSub control offset \(relativeControlOffset) at offset \(offset - 2) " +
                            "is outside its subpicture of \(size) bytes")
                }
                guard offset - 4 + size <= buffer.count else {
                    throw macSubtitleOCRError.invalidVobSubSubpicture(
                        "VobSub subpicture of \(size) bytes at offset \(offset - 4) runs past the end of the file")
                }
                let rleSize = relativeControlOffset - 4
                controlSize = size - rleSize - 4 // 4 bytes for the size and control offset
                controlOffset = offset + rleSize
                trueHeaderSize = offset - startOffset
                firstPacketFound = true
            } else if firstPacketFound {
                controlOffset! += trueHeaderSize
            } else {
                throw macSubtitleOCRError.invalidVobSubSubpicture(
                    "VobSub packet at offset \(startOffset) does not start a subpicture")
            }
            guard offset <= nextPSOffset else {
                throw macSubtitleOCRError.invalidVobSubSubpicture(
                    "VobSub PES header at offset \(startOffset) runs past the end of its packet")
            }

            let difference = max(0, nextPSOffset - controlOffset! - controlHeaderCopied)
            let rleFragmentSize = nextPSOffset - offset - difference
            guard rleFragmentSize >= 0 else {
                throw macSubtitleOCRError.invalidVobSubSubpicture(
                    "VobSub control data at offset \(controlOffset! + controlHeaderCopied) starts inside a packet header")
            }
            subtitle.imageData!.append(contentsOf: buffer[offset ..< offset + rleFragmentSize])
            rleLengthFound += rleFragmentSize
            offset += rleFragmentSize

            let bytesToCopy = difference <= 0 ? 0 : min(difference, controlSize! - controlHeaderCopied)
            controlHeader.append(contentsOf: buffer[offset ..< offset + bytesToCopy])
            controlHeaderCopied += bytesToCopy

            offset = nextPSOffset
        } while offset < nextOffset && controlHeaderCopied < controlSize!

        if controlHeaderCopied < controlSize! {
            print("Failed to read control header completely, \(controlHeaderCopied)/\(controlSize!), errors may occur")
            for _ in controlHeaderCopied ..< controlSize! {
                controlHeader.append(0xFF)
            }
        }

        parseControlSequences(controlHeader, offset: relativeControlOffset)
    }

    /// Skip the packets at `offset`, up to `end`, that are not a pack header or private stream 1.
    ///
    /// DVD packs are filled out to 2048 bytes with padding packets (0xBE), a pack header may be
    /// followed by a system header (0xBB), and packets of the video and audio streams can sit
    /// between the packets of a subpicture. Each of these gives its length in the 16 bits after its
    /// start code, and FFmpeg's MPEG-PS demuxer skips them by it.
    ///
    /// - Returns: The offset of the first start code that is not one of them, or `end`.
    private func skipOtherPackets(_ buffer: UnsafeRawBufferPointer, from offset: Int, to end: Int) throws -> Int {
        var offset = offset
        while offset < end, let startCode = try? buffer.bigEndian(UInt32.self, at: offset),
              startCode >> 8 == 0x01, startCode & 0xFF >= 0xBB, startCode != MPEG2PacketType.pesPacket {
            // A packet is at least its 6 byte start code and length, so each one skipped moves on.
            let packetEnd = try offset + 6 + Int(buffer.bigEndian(UInt16.self, at: offset + 4))
            guard packetEnd <= end else {
                throw macSubtitleOCRError.invalidVobSubSubpicture(
                    "VobSub packet \(String(format: "0x%08X", startCode)) at offset \(offset) runs " +
                        "\(packetEnd - end) bytes past the end of its subpicture")
            }
            offset = packetEnd
        }
        return offset
    }

    /// Walk the subpicture's chain of control sequences, as ffmpeg's `decode_dvd_subtitles` does.
    ///
    /// Each sequence is a delay, the offset of the next sequence, and commands ending in 0xFF;
    /// the last sequence points at itself. `header` holds the bytes from `controlStart`, the
    /// offset of the first sequence within the subpicture. The start and stop display commands
    /// usually sit in different sequences, so reading only the first loses the end time.
    private mutating func parseControlSequences(_ header: Data, offset controlStart: Int) {
        let presented = subtitle.startTimestamp!
        var sequence = controlStart
        while true {
            let local = sequence - controlStart
            guard local >= 0, let date = header.getUInt16BE(at: local),
                  let next = header.getUInt16BE(at: local + 2) else {
                print("Control sequence for subtitle \(subtitle.index) lies outside its header, errors may occur")
                return
            }
            // A delay counts in units of 1024/90000 s from the presentation timestamp. ffmpeg
            // rounds it down to whole milliseconds; the shift needs more than the 16 bits it is read in.
            let delay = TimeInterval((Int(date) << 10) / 90) / 1000
            parseCommands(header, from: local + 4, at: presented + delay, openEnded: date == 0xFFFF)
            let nextSequence = Int(next)
            if nextSequence == sequence {
                return
            }
            if nextSequence < sequence {
                print("Invalid control sequence offset for subtitle \(subtitle.index), errors may occur")
                return
            }
            sequence = nextSequence
        }
    }

    /// Apply one control sequence's commands, which take effect at `time`.
    ///
    /// The image is taken from the first sequence that describes it, since a later one
    /// only repeats it or changes its contrast to fade it. The stream's colors, though, are left as
    /// the last command set them, as FFmpeg leaves them for the next subpicture.
    ///
    /// `openEnded` marks a sequence with the largest delay, 0xFFFF, about 745.6 s. Authoring
    /// tools give the stop command that delay to mean the subpicture stays until the next one
    /// replaces it, so its stop sets no end time and the SRT writer times it. Only that exact value
    /// is taken this way; any smaller delay is a real, if long, display time.
    private mutating func parseCommands(_ header: Data, from start: Int, at time: TimeInterval, openEnded: Bool) {
        var index = start
        while index < header.count {
            let command = header[index]
            index += 1
            let operands = [0x03: 2, 0x04: 2, 0x05: 6, 0x06: 4][command] ?? 0
            guard index + operands <= header.count else {
                print("Control command \(command) for subtitle \(subtitle.index) is truncated, errors may occur")
                return
            }
            switch command {
            case 0x00:
                break // Forced display: shown whatever the player's subtitle setting.
            case 0x01:
                subtitle.startTimestamp = time
            case 0x02:
                subtitle.endTimestamp = openEnded ? nil : time
            case 0x03, 0x04:
                let values = [header[index + 1] & 0x0F, header[index + 1] >> 4, header[index] & 0x0F, header[index] >> 4]
                if command == 0x03 {
                    colors.colormap = values
                    subtitle.imagePalette = subtitle.imagePalette ?? values
                } else {
                    colors.alpha = values
                    subtitle.imageAlpha = subtitle.imageAlpha ?? values
                }
            case 0x05:
                if subtitle.imageXOffset == nil, subtitle.imageYOffset == nil {
                    subtitle.imageXOffset = Int(header[index]) << 4 | Int(header[index + 1] >> 4)
                    subtitle.imageWidth = (Int(header[index + 1] & 0x0F) << 8 | Int(header[index + 2]))
                        - subtitle.imageXOffset! + 1
                    subtitle.imageYOffset = Int(header[index + 3]) << 4 | Int(header[index + 4] >> 4)
                    subtitle.imageHeight = (Int(header[index + 4] & 0x0F) << 8 | Int(header[index + 5]))
                        - subtitle.imageYOffset! + 1
                }
            case 0x06:
                if subtitle.evenOffset == nil, subtitle.oddOffset == nil {
                    subtitle.evenOffset = Int(header.getUInt16BE(at: index)!) - 4
                    subtitle.oddOffset = Int(header.getUInt16BE(at: index + 2)!) - 4
                }
            default:
                return // 0xFF ends the sequence; like ffmpeg, so does a command it does not know.
            }
            index += operands
        }
    }

    /// Turn the four idx palette indices and alphas the subpicture selects into RGBA colors.
    ///
    /// A subpicture without a set color or set contrast command uses the stream's colors from the
    /// subpictures before it, as FFmpeg does.
    ///
    /// With an idx palette each color is the entry its index selects, as in FFmpeg; an entry past
    /// the end of a short palette is black. Without one the colors are the grays `layeredGrays`
    /// picks for OCR.
    private func decodePalette() {
        let colormap = subtitle.imagePalette ?? colors.colormap
        let alpha = subtitle.imageAlpha ?? colors.alpha
        subtitle.imageAlpha = alpha

        let grays = masterPalette == nil
            ? Self.layeredGrays(image: subtitle.imageData ?? Data(), width: subtitle.imageWidth ?? 0, alpha: alpha)
            : nil
        var palette = [UInt8](repeating: 0, count: 4 * 4)
        for i in 0 ..< 4 {
            if let grays {
                palette[4 * i] = grays[i]
                palette[4 * i + 1] = grays[i]
                palette[4 * i + 2] = grays[i]
            } else if let masterPalette {
                let entry = 3 * Int(colormap[i])
                if entry + 2 < masterPalette.count {
                    palette[4 * i] = masterPalette[entry]
                    palette[4 * i + 1] = masterPalette[entry + 1]
                    palette[4 * i + 2] = masterPalette[entry + 2]
                }
            }
            palette[4 * i + 3] = alpha[i] * 0x11
        }

        subtitle.imagePalette = palette
    }

    /// The gray to draw each of the four colors in when the idx has no palette, from how they are
    /// layered in the image.
    ///
    /// DVD subtitles are a light text body inside a dark outline, sometimes with an anti-aliasing
    /// color or a second outline around it, but which of the four colors plays which part varies
    /// from disc to disc. The visible colors are ranked by how deep inside the ink their pixels lie
    /// on average, counting the steps from each pixel to the nearest transparent pixel or the edge
    /// of the image: the body, enclosed by the outline, lies deepest. The innermost color is white
    /// and the outermost black, with any between them spread evenly, so the inverted image Vision
    /// reads is dark text on white, as with a typical palette. Transparent colors, and visible ones
    /// no pixel uses, are black; ties go to the lower color.
    ///
    /// FFmpeg's `guess_palette` instead spreads the colors from black to white in the order they
    /// are numbered, which usually makes the body the darkest and turns filled glyphs hollow.
    static func layeredGrays(image: Data, width: Int, alpha: [UInt8]) -> [UInt8] {
        var grays = [UInt8](repeating: 0, count: 4)
        guard width > 0, alpha.count == 4 else { return grays }
        let height = image.count / width
        var pixels = [Int](repeating: 0, count: 4)
        var depths = [Int](repeating: 0, count: 4)
        image.withUnsafeBytes { (image: UnsafeRawBufferPointer) in
            // The city block distance of each pixel from the nearest transparent one, in two passes;
            // the pixels around the image count as transparent.
            var distance = [Int](repeating: 0, count: width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let color = Int(image[y * width + x])
                    guard color < 4, alpha[color] != 0 else { continue }
                    let left = x > 0 ? distance[y * width + x - 1] : 0
                    let above = y > 0 ? distance[(y - 1) * width + x] : 0
                    distance[y * width + x] = min(left, above) + 1
                }
            }
            for y in (0 ..< height).reversed() {
                for x in (0 ..< width).reversed() where distance[y * width + x] > 0 {
                    let right = x < width - 1 ? distance[y * width + x + 1] : 0
                    let below = y < height - 1 ? distance[(y + 1) * width + x] : 0
                    distance[y * width + x] = min(distance[y * width + x], min(right, below) + 1)
                    let color = Int(image[y * width + x])
                    pixels[color] += 1
                    depths[color] += distance[y * width + x]
                }
            }
        }

        // Innermost first: the greatest mean depth, compared without dividing.
        let layers = (0 ..< 4).filter { pixels[$0] > 0 }.sorted { a, b in
            let lhs = depths[a] * pixels[b]
            let rhs = depths[b] * pixels[a]
            return lhs != rhs ? lhs > rhs : a < b
        }
        let outermost = layers.count - 1
        for (depth, color) in layers.enumerated() {
            grays[color] = outermost == 0 ? 0xFF : UInt8(0xFF * (outermost - depth) / outermost)
        }
        return grays
    }

    private func decodeImage() throws {
        let rleData = RLEData(
            data: subtitle.imageData ?? Data(),
            width: subtitle.imageWidth ?? 0,
            height: subtitle.imageHeight ?? 0,
            evenOffset: subtitle.evenOffset ?? 0,
            oddOffset: subtitle.oddOffset ?? 0)
        subtitle.imageData = try rleData.decodeVobSub()
    }
}

private extension UnsafeRawBufferPointer {
    /// Read a big-endian integer at `offset`, throwing if it does not lie wholly within the buffer.
    ///
    /// `loadUnaligned` and subscripting only check their bounds in debug builds, and offsets in a
    /// VobSub come from the file, so a malformed one would otherwise read outside the buffer.
    func bigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) throws -> T {
        guard offset >= 0, offset <= count - MemoryLayout<T>.size else {
            throw macSubtitleOCRError.invalidVobSubSubpicture(
                "VobSub subpicture runs past the end of the file at offset \(offset)")
        }
        return T(bigEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
