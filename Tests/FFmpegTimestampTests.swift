//
// FFmpegTimestampTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

#if FFMPEG
import CFFmpeg
import Foundation
@testable import macSubtitleOCR
import Testing

// Issue #148: the decoder context was never given the packets' time base, so the decoder could not
// rescale their timestamps into AVSubtitle.pts and every subtitle fell back to its packet's own.

private let samples = ["sintel.sup", "sintel.sub", "sintel.mks"]

private func resource(_ name: String) -> String {
    Bundle.module.url(forResource: name, withExtension: nil)!.path
}

@Test func decoderIsGivenThePacketTimeBase() throws {
    var allocated = avcodec_parameters_alloc()
    defer { avcodec_parameters_free(&allocated) }
    let parameters = try #require(allocated)
    parameters.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
    parameters.pointee.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE

    let timeBase = AVRational(num: 1, den: 90000)
    let stream = try FFStream(codecParameters: parameters, timeBase: timeBase)
    let packetTimeBase = try #require(stream.codecContext).pointee.pkt_timebase
    #expect(packetTimeBase.num == timeBase.num && packetTimeBase.den == timeBase.den)
}

/// Every subtitle the decoder puts out carries its packet's timestamp, rescaled to AV_TIME_BASE.
@Test(arguments: samples) func decodedSubtitlesCarryTheirPacketTimestamp(sample: String) throws {
    let times = try decodedTimes(of: resource(sample))
    try #require(!times.isEmpty)
    for time in times {
        #expect(time.subtitle == av_rescale_q(time.packet, time.timeBase, AVRational(num: 1, den: AV_TIME_BASE)),
                "Stream \(time.stream) packet at \(time.packet)")
    }
}

/// Timing each subtitle by AVSubtitle.pts starts every cue where its packet's timestamp says.
@Test(arguments: samples) func cuesStartAtTheirPacketTimestamp(sample: String) throws {
    let path = resource(sample)
    var packetTimes = [Int: [TimeInterval]]()
    for time in try decodedTimes(of: path) {
        packetTimes[time.stream, default: []].append(Double(time.packet) * av_q2d(time.timeBase))
    }

    let tracks = try FFmpeg(path).subtitleTracks
    try #require(!tracks.isEmpty)
    #expect(tracks.keys.sorted() == packetTimes.keys.sorted())
    for (stream, subtitles) in tracks {
        let times = try #require(packetTimes[stream])
        for subtitle in subtitles {
            let start = try #require(subtitle.startTimestamp)
            #expect(times.contains { abs($0 - start) < 0.000_001 }, "Stream \(stream) cue at \(start)")
        }
    }
}

// MARK: - Helpers

private struct DecodedTime {
    var stream: Int
    var timeBase: AVRational
    var packet: Int64
    var subtitle: Int64
}

/// Decodes every bitmap subtitle stream of `path` through `FFStream`, pairing each packet's timestamp
/// with the one on the subtitle it decodes to.
private func decodedTimes(of path: String) throws -> [DecodedTime] {
    var format: UnsafeMutablePointer<AVFormatContext>?
    try #require(avformat_open_input(&format, path, nil, nil) == 0)
    defer { avformat_close_input(&format) }
    try #require(avformat_find_stream_info(format, nil) >= 0)

    var streams = [Int: FFStream]()
    for i in 0 ..< Int(format!.pointee.nb_streams) {
        let stream = format!.pointee.streams[i]!
        if FFStream.isBitmapSubtitle(stream.pointee.codecpar) {
            streams[i] = try FFStream(codecParameters: stream.pointee.codecpar, timeBase: stream.pointee.time_base)
        }
    }

    var packet = av_packet_alloc()
    defer { av_packet_free(&packet) }
    var times: [DecodedTime] = []
    while av_read_frame(format, packet) >= 0 {
        defer { av_packet_unref(packet) }
        let index = Int(packet!.pointee.stream_index)
        guard let stream = streams[index], packet!.pointee.pts != Int64.min else { continue }
        var subtitle = AVSubtitle()
        var gotSubtitle: Int32 = 0
        guard avcodec_decode_subtitle2(stream.codecContext, &subtitle, &gotSubtitle, packet) >= 0,
              gotSubtitle != 0 else { continue }
        times.append(DecodedTime(stream: index, timeBase: stream.timeBase, packet: packet!.pointee.pts,
                                 subtitle: subtitle.pts))
        avsubtitle_free(&subtitle)
    }
    return times
}
#endif
