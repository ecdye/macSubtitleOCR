//
// DVBSubtitleTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/26/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

#if FFMPEG
import ArgumentParser
import CFFmpeg
import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #42: a DVB subtitle track in MPEG-TS, read with the FFmpeg decoder, came out as one cue per
// line, the lines of each caption in reverse order, ending before they started. The stream here is
// built the way a broadcast carries captions: one region per line, a page timeout of ten seconds,
// and an empty page taking each caption down.

/// One caption: its lines from top to bottom, and when it is put up and taken down.
private struct Caption {
    var lines: [String]
    var start: TimeInterval
    var end: TimeInterval
}

private let captions = [
    Caption(lines: ["Love what they have done", "with the place"], start: 2.0, end: 5.0),
    Caption(lines: ["If I was a bird", "I would come and live here"], start: 5.5, end: 9.25),
    Caption(lines: ["Penguins, look"], start: 10.0, end: 12.5)
]

private let pageTimeout: UInt32 = 10000

@Test func dvbSubtitleCaptionsAreReadWholeInOrderWithTheirTimes() async throws {
    let directory = try makeOutputDirectory()
    let input = "\(directory)/captions.ts"
    try writeDVBSubtitleStream(captions, to: input)

    var runner = try macSubtitleOCR.parse([input, directory, "--ffmpeg-decoder", "--max-threads", "1"])
    try await runner.run()

    let srt = try String(contentsOfFile: "\(directory)/track_0.srt", encoding: .utf8)
    let cues = srt.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    try #require(cues.count == captions.count, "Expected one cue per caption, got:\n\(srt)")

    for (cue, caption) in zip(cues, captions) {
        let lines = cue.components(separatedBy: "\n")
        try #require(lines.count >= 3, "Malformed cue: \(cue)")
        let times = lines[1].components(separatedBy: " --> ").map(srtSeconds)
        let start = try #require(times.first ?? nil)
        let end = try #require(times.last ?? nil)
        #expect(abs(start - caption.start) < 0.002, "\(lines[1]) should start at \(caption.start)")
        // The empty page takes the caption down; the SRT writer may only shorten it to keep a gap
        // before the next caption.
        #expect(end <= caption.end + 0.002 && end >= caption.end - 0.1 - 0.002,
                "\(lines[1]) should end at \(caption.end)")
        #expect(end > start)

        let text = Array(lines[2...])
        #expect(text.count == caption.lines.count, "\(text) should be \(caption.lines)")
        for (read, expected) in zip(text, caption.lines) {
            #expect(similarityPercentage(of: expected, and: read) >= 90.0, "\(read) should be \(expected)")
        }
    }
}

/// A Matroska file holding only subtitles the internal decoder cannot read must say so rather than
/// write nothing and exit cleanly.
@Test func unsupportedSubtitleCodecIsReported() async throws {
    let directory = try makeOutputDirectory()
    let ts = "\(directory)/captions.ts"
    let mkv = "\(directory)/captions.mkv"
    try writeDVBSubtitleStream(captions, to: ts)
    try remux(ts, to: mkv)

    let parser = try MKVSubtitleExtractor(filePath: mkv)
    try parser.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
    #expect(parser.tracks.isEmpty)
    #expect(parser.skippedSubtitleCodecs == ["S_DVBSUB"])

    var runner = try macSubtitleOCR.parse([mkv, directory])
    await #expect(throws: ExitCode.failure) { try await runner.run() }
    let written = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".srt") }
    #expect(written.isEmpty)
}

private func srtSeconds(_ timestamp: String) -> TimeInterval? {
    let parts = timestamp.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: ",", with: ":").split(separator: ":").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / 1000
}

private struct FFmpegFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ result: Int32, _ what: String) throws {
    if result < 0 {
        throw FFmpegFailure(description: "\(what) failed: \(result)")
    }
}

/// Encodes `captions` as DVB subtitles in an MPEG-TS file, the way FFmpeg's own command line does:
/// one page with a region per line at the caption's start, and an empty page at its end.
private func writeDVBSubtitleStream(_ captions: [Caption], to path: String) throws {
    let width: Int32 = 720
    let height: Int32 = 576

    var formatContext: UnsafeMutablePointer<AVFormatContext>?
    try check(avformat_alloc_output_context2(&formatContext, nil, "mpegts", path), "Allocating the muxer")
    defer { avformat_free_context(formatContext) }
    // The muxer otherwise delays every timestamp by twice this, which would shift the expected times.
    formatContext!.pointee.max_delay = 0

    let encoder = try #require(avcodec_find_encoder(AV_CODEC_ID_DVB_SUBTITLE))
    var codecContext = avcodec_alloc_context3(encoder)
    defer { avcodec_free_context(&codecContext) }
    codecContext!.pointee.width = width
    codecContext!.pointee.height = height
    codecContext!.pointee.time_base = AVRational(num: 1, den: 1000)
    try check(avcodec_open2(codecContext, encoder, nil), "Opening the encoder")

    let stream = try #require(avformat_new_stream(formatContext, nil))
    try check(avcodec_parameters_from_context(stream.pointee.codecpar, codecContext), "Copying codec parameters")
    stream.pointee.time_base = AVRational(num: 1, den: 90000)

    try check(avio_open(&formatContext!.pointee.pb, path, AVIO_FLAG_WRITE), "Opening \(path)")
    defer { avio_closep(&formatContext!.pointee.pb) }
    try check(avformat_write_header(formatContext, nil), "Writing the header")

    for caption in captions {
        // Each line is drawn on its own and placed under the one before it, as a broadcaster would.
        var y = 400
        var rects: [(Subtitle, Int)] = []
        for (number, line) in caption.lines.enumerated() {
            let drawn = try renderedSubtitle(line, index: number + 1, pointSize: 28, transparent: true)
            rects.append((drawn, y))
            y += drawn.imageHeight! + 12
        }
        try writePage(rects, at: caption.start, formatContext: formatContext!, codecContext: codecContext!,
                      stream: stream)
        try writePage([], at: caption.end, formatContext: formatContext!, codecContext: codecContext!,
                      stream: stream)
    }

    try check(av_write_trailer(formatContext), "Writing the trailer")
}

/// Encodes and muxes one page holding `rects`, each a drawn line and the row it is placed at.
private func writePage(_ rects: [(Subtitle, Int)], at time: TimeInterval,
                       formatContext: UnsafeMutablePointer<AVFormatContext>,
                       codecContext: UnsafeMutablePointer<AVCodecContext>,
                       stream: UnsafeMutablePointer<AVStream>) throws {
    // Buffers handed to FFmpeg, released once the page is encoded.
    var allocations: [UnsafeMutableRawPointer] = []
    defer { allocations.forEach { $0.deallocate() } }

    var rectPointers: [UnsafeMutablePointer<AVSubtitleRect>?] = []
    for (drawn, y) in rects {
        let rect = UnsafeMutablePointer<AVSubtitleRect>.allocate(capacity: 1)
        allocations.append(UnsafeMutableRawPointer(rect))
        rect.initialize(to: AVSubtitleRect())

        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: drawn.imageData!.count)
        allocations.append(UnsafeMutableRawPointer(pixels))
        drawn.imageData!.copyBytes(to: pixels, count: drawn.imageData!.count)

        // FFmpeg palettes are native endian 0xAARRGGBB words.
        let colors = drawn.numberOfColors!
        let palette = UnsafeMutablePointer<UInt32>.allocate(capacity: colors)
        allocations.append(UnsafeMutableRawPointer(palette))
        let rgba = drawn.imagePalette!
        for i in 0 ..< colors {
            palette[i] = UInt32(rgba[i * 4 + 3]) << 24 | UInt32(rgba[i * 4]) << 16
                | UInt32(rgba[i * 4 + 1]) << 8 | UInt32(rgba[i * 4 + 2])
        }

        rect.pointee.type = SUBTITLE_BITMAP
        rect.pointee.x = 40
        rect.pointee.y = Int32(y)
        rect.pointee.w = Int32(drawn.imageWidth!)
        rect.pointee.h = Int32(drawn.imageHeight!)
        rect.pointee.nb_colors = Int32(colors)
        rect.pointee.data.0 = pixels
        rect.pointee.data.1 = UnsafeMutableRawPointer(palette).assumingMemoryBound(to: UInt8.self)
        rect.pointee.linesize.0 = Int32(drawn.imageWidth!)
        rectPointers.append(rect)
    }

    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    defer { buffer.deallocate() }

    let size = try rectPointers.withUnsafeMutableBufferPointer { pointers in
        var subtitle = AVSubtitle()
        subtitle.format = 0
        subtitle.start_display_time = 0
        subtitle.end_display_time = pageTimeout
        subtitle.num_rects = UInt32(pointers.count)
        subtitle.rects = pointers.baseAddress
        subtitle.pts = Int64((time * Double(AV_TIME_BASE)).rounded())
        let size = avcodec_encode_subtitle(codecContext, buffer, 1 << 20, &subtitle)
        try check(size, "Encoding the page at \(time)")
        return size
    }

    var packet = av_packet_alloc()
    defer { av_packet_free(&packet) }
    try check(av_new_packet(packet, size), "Allocating a packet")
    packet!.pointee.data.update(from: buffer, count: Int(size))
    packet!.pointee.stream_index = stream.pointee.index
    packet!.pointee.pts = av_rescale_q(Int64((time * 1000).rounded()), AVRational(num: 1, den: 1000),
                                       stream.pointee.time_base)
    packet!.pointee.dts = packet!.pointee.pts
    try check(av_interleaved_write_frame(formatContext, packet), "Writing the page at \(time)")
}

/// Copies every stream of `input` into a new container, chosen by the extension of `output`.
private func remux(_ input: String, to output: String) throws {
    var inputContext: UnsafeMutablePointer<AVFormatContext>?
    try check(avformat_open_input(&inputContext, input, nil, nil), "Opening \(input)")
    defer { avformat_close_input(&inputContext) }
    try check(avformat_find_stream_info(inputContext, nil), "Reading stream info")

    var outputContext: UnsafeMutablePointer<AVFormatContext>?
    try check(avformat_alloc_output_context2(&outputContext, nil, nil, output), "Allocating the muxer")
    defer { avformat_free_context(outputContext) }

    for i in 0 ..< Int(inputContext!.pointee.nb_streams) {
        let source = inputContext!.pointee.streams[i]!
        let copy = try #require(avformat_new_stream(outputContext, nil))
        try check(avcodec_parameters_copy(copy.pointee.codecpar, source.pointee.codecpar), "Copying parameters")
        copy.pointee.codecpar.pointee.codec_tag = 0
    }

    try check(avio_open(&outputContext!.pointee.pb, output, AVIO_FLAG_WRITE), "Opening \(output)")
    defer { avio_closep(&outputContext!.pointee.pb) }
    try check(avformat_write_header(outputContext, nil), "Writing the header")

    var packet = av_packet_alloc()
    defer { av_packet_free(&packet) }
    while av_read_frame(inputContext, packet) >= 0 {
        let index = Int(packet!.pointee.stream_index)
        av_packet_rescale_ts(packet, inputContext!.pointee.streams[index]!.pointee.time_base,
                             outputContext!.pointee.streams[index]!.pointee.time_base)
        try check(av_interleaved_write_frame(outputContext, packet), "Writing a packet")
    }
    try check(av_write_trailer(outputContext), "Writing the trailer")
}
#endif
