//
// FFmpegStreamSelectionTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

#if FFMPEG
import ArgumentParser
import CFFmpeg
import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #93: the FFmpeg decoder opened a decoder for every subtitle stream, text ones included,
// without checking that it could, and let the demuxer read every other stream's packets in full.

private let sintelMKS = Bundle.module.url(forResource: "sintel.mks", withExtension: nil)!.path

private let textCues: [(text: String, start: TimeInterval, end: TimeInterval)] = [
    ("Hello there", 1.0, 2.5),
    ("General Kenobi", 3.0, 4.0),
    ("You are a bold one", 30.0, 32.0)
]

@Test func textSubtitleStreamsAreSkipped() throws {
    let directory = try makeOutputDirectory()
    let mkv = "\(directory)/text.mkv"
    try writeMKV(copyingStreamsOf: nil, textCues: textCues, to: mkv)
    try #require(streamCodecs(of: mkv) == [AV_CODEC_ID_SUBRIP])

    let ffmpeg = try FFmpeg(mkv)
    #expect(ffmpeg.subtitleTracks.isEmpty)
}

@Test func textOnlyInputIsReportedAsHavingNoBitmapSubtitles() async throws {
    let directory = try makeOutputDirectory()
    let mkv = "\(directory)/text.mkv"
    try writeMKV(copyingStreamsOf: nil, textCues: textCues, to: mkv)

    var runner = try macSubtitleOCR.parse([mkv, directory, "--ffmpeg-decoder"])
    await #expect(throws: ExitCode.failure) { try await runner.run() }
    let written = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".srt") }
    #expect(written.isEmpty)
}

/// A text stream next to bitmap ones changes nothing about how the bitmap ones decode.
@Test func bitmapStreamsBesideATextStreamDecodeAsAlone() throws {
    let directory = try makeOutputDirectory()
    let mkv = "\(directory)/mixed.mkv"
    try writeMKV(copyingStreamsOf: sintelMKS, textCues: textCues, to: mkv)
    try #require(streamCodecs(of: mkv) == [AV_CODEC_ID_HDMV_PGS_SUBTITLE, AV_CODEC_ID_DVD_SUBTITLE, AV_CODEC_ID_SUBRIP])

    let alone = try FFmpeg(sintelMKS).subtitleTracks
    let mixed = try FFmpeg(mkv).subtitleTracks
    #expect(alone.keys.sorted() == [0, 1])
    #expect(mixed.keys.sorted() == alone.keys.sorted())
    for (track, subtitles) in alone {
        let other = try #require(mixed[track])
        try #require(other.count == subtitles.count, "Track \(track)")
        for (a, b) in zip(subtitles, other) {
            #expect(a.startTimestamp == b.startTimestamp)
            #expect(a.endTimestamp == b.endTimestamp)
            #expect(a.imageData == b.imageData)
            #expect(a.imagePalette == b.imagePalette)
            #expect(a.imageXOffset == b.imageXOffset && a.imageYOffset == b.imageYOffset)
        }
    }
}

/// Only bitmap subtitle streams are OCR'd; text subtitles, video and audio are not.
@Test func onlyBitmapSubtitleCodecsAreSelected() throws {
    let cases: [(AVMediaType, AVCodecID, Bool)] = [
        (AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_HDMV_PGS_SUBTITLE, true),
        (AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_DVD_SUBTITLE, true),
        (AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_DVB_SUBTITLE, true),
        (AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_XSUB, true),
        (AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_SUBRIP, false),
        (AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_ASS, false),
        (AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_MOV_TEXT, false),
        (AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_NONE, false),
        (AVMEDIA_TYPE_VIDEO, AV_CODEC_ID_H264, false),
        (AVMEDIA_TYPE_AUDIO, AV_CODEC_ID_AC3, false)
    ]
    for (type, codec, expected) in cases {
        let parameters = try codecParameters(type, codec)
        defer { free(parameters) }
        let name = String(cString: avcodec_get_name(codec))
        #expect(FFStream.isBitmapSubtitle(parameters) == expected, "\(name)")
    }
}

/// A stream whose decoder cannot be set up throws a description of why, which the caller prints
/// once before skipping the stream, rather than crashing or failing on every packet.
@Test func streamWithoutADecoderFailsSetup() throws {
    // A codec FFmpeg knows of but has no decoder for.
    try #require(avcodec_find_decoder(AV_CODEC_ID_HDMV_TEXT_SUBTITLE) == nil)
    let parameters = try codecParameters(AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_HDMV_TEXT_SUBTITLE)
    defer { free(parameters) }

    #expect {
        _ = try FFStream(codecParameters: parameters, timeBase: AVRational(num: 1, den: 1000))
    } throws: { error in
        "\(error)".contains("no hdmv_text_subtitle decoder")
    }
}

@Test func bitmapStreamSetsUpItsDecoder() throws {
    let parameters = try codecParameters(AVMEDIA_TYPE_SUBTITLE, AV_CODEC_ID_HDMV_PGS_SUBTITLE)
    defer { free(parameters) }
    let stream = try FFStream(codecParameters: parameters, timeBase: AVRational(num: 1, den: 1000))
    #expect(avcodec_is_open(stream.codecContext) != 0)
}

// MARK: - Helpers

/// Codec parameters for a stream of `type` and `codec`, to be released with `free(_:)`.
private func codecParameters(_ type: AVMediaType,
                             _ codec: AVCodecID) throws -> UnsafeMutablePointer<AVCodecParameters> {
    let parameters = try #require(avcodec_parameters_alloc())
    parameters.pointee.codec_type = type
    parameters.pointee.codec_id = codec
    return parameters
}

private func free(_ parameters: UnsafeMutablePointer<AVCodecParameters>) {
    var parameters: UnsafeMutablePointer<AVCodecParameters>? = parameters
    avcodec_parameters_free(&parameters)
}

private struct FFmpegFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ result: Int32, _ what: String) throws {
    if result < 0 {
        throw FFmpegFailure(description: "\(what) failed: \(result)")
    }
}

private func streamCodecs(of path: String) throws -> [AVCodecID] {
    var context: UnsafeMutablePointer<AVFormatContext>?
    try check(avformat_open_input(&context, path, nil, nil), "Opening \(path)")
    defer { avformat_close_input(&context) }
    return (0 ..< Int(context!.pointee.nb_streams)).map { context!.pointee.streams[$0]!.pointee.codecpar.pointee.codec_id }
}

/// Writes a Matroska file holding every stream of `input`, if given, followed by a SubRip stream
/// carrying `textCues`.
private func writeMKV(copyingStreamsOf input: String?,
                      textCues: [(text: String, start: TimeInterval, end: TimeInterval)],
                      to output: String) throws {
    var inputContext: UnsafeMutablePointer<AVFormatContext>?
    if let input {
        try check(avformat_open_input(&inputContext, input, nil, nil), "Opening \(input)")
        try check(avformat_find_stream_info(inputContext, nil), "Reading stream info")
    }
    defer { avformat_close_input(&inputContext) }
    let inputStreams = Int(inputContext?.pointee.nb_streams ?? 0)

    var outputContext: UnsafeMutablePointer<AVFormatContext>?
    try check(avformat_alloc_output_context2(&outputContext, nil, "matroska", output), "Allocating the muxer")
    defer { avformat_free_context(outputContext) }

    for i in 0 ..< inputStreams {
        let source = inputContext!.pointee.streams[i]!
        let copy = try #require(avformat_new_stream(outputContext, nil))
        try check(avcodec_parameters_copy(copy.pointee.codecpar, source.pointee.codecpar), "Copying parameters")
        copy.pointee.codecpar.pointee.codec_tag = 0
    }
    let text = try #require(avformat_new_stream(outputContext, nil))
    text.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
    text.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_SUBRIP
    text.pointee.time_base = AVRational(num: 1, den: 1000)

    try check(avio_open(&outputContext!.pointee.pb, output, AVIO_FLAG_WRITE), "Opening \(output)")
    defer { avio_closep(&outputContext!.pointee.pb) }
    try check(avformat_write_header(outputContext, nil), "Writing the header")

    var packet = av_packet_alloc()
    defer { av_packet_free(&packet) }
    for cue in textCues {
        let bytes = Array(cue.text.utf8)
        try check(av_new_packet(packet, Int32(bytes.count)), "Allocating a packet")
        packet!.pointee.data.update(from: bytes, count: bytes.count)
        packet!.pointee.stream_index = text.pointee.index
        let timeBase = text.pointee.time_base
        packet!.pointee.pts = av_rescale_q(Int64((cue.start * 1000).rounded()), AVRational(num: 1, den: 1000), timeBase)
        packet!.pointee.dts = packet!.pointee.pts
        packet!.pointee.duration = av_rescale_q(Int64(((cue.end - cue.start) * 1000).rounded()),
                                                AVRational(num: 1, den: 1000), timeBase)
        try check(av_interleaved_write_frame(outputContext, packet), "Writing \(cue.text)")
    }
    if inputContext != nil {
        while av_read_frame(inputContext, packet) >= 0 {
            let index = Int(packet!.pointee.stream_index)
            av_packet_rescale_ts(packet, inputContext!.pointee.streams[index]!.pointee.time_base,
                                 outputContext!.pointee.streams[index]!.pointee.time_base)
            try check(av_interleaved_write_frame(outputContext, packet), "Writing a packet")
        }
    }
    try check(av_write_trailer(outputContext), "Writing the trailer")
}
#endif
