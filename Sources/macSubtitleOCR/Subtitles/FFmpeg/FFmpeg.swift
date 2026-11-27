//
// FFmpeg.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/10/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

#if FFMPEG
import CFFmpeg
import Foundation
import os

struct FFmpeg {
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "FFmpeg")
    private(set) var subtitleTracks = [Int: [Subtitle]]()

    // MARK: - Lifecycle

    init(_ sub: String) throws {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        // Open the input file
        if avformat_open_input(&fmtCtx, sub, nil, nil) != 0 {
            throw macSubtitleOCRError.fileReadError("Failed to open input file: \(sub)")
        }
        defer { avformat_close_input(&fmtCtx) }

        // Retrieve stream information
        if avformat_find_stream_info(fmtCtx, nil) < 0 {
            throw macSubtitleOCRError.ffmpegError("FFmpeg failed to find stream info")
        }

        // Iterate over all streams and find subtitle tracks
        var streamsToProcess = [Int: FFStream]()
        for i in 0 ..< Int(fmtCtx!.pointee.nb_streams) {
            let stream = fmtCtx!.pointee.streams[i]!.pointee
            if stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                let codecParameters = stream.codecpar
                let timeBase = stream.time_base
                let ffStream = FFStream(codecParameters: codecParameters, timeBase: timeBase)
                streamsToProcess[i] = ffStream
            }
        }

        processSubtitleTracks(fmtCtx: fmtCtx, streams: streamsToProcess)
    }

    // MARK: - Methods

    private mutating func processSubtitleTracks(fmtCtx: UnsafeMutablePointer<AVFormatContext>?,
                                                streams: [Int: FFStream]) {
        // Allocate packet
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var subtitle = AVSubtitle()
        var frames = [Int: [DecodedSubtitleFrame]]()

        // Read frames for the specific subtitle stream
        while av_read_frame(fmtCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let streamNumber = Int(packet!.pointee.stream_index)
            guard let stream = streams[streamNumber] else {
                continue // Skip if stream is not a subtitle stream
            }
            logger.debug("Got packet for stream \(streamNumber)")

            // Decode subtitle packet
            var gotSubtitle: Int32 = 0
            guard avcodec_decode_subtitle2(stream.codecContext, &subtitle, &gotSubtitle, packet) >= 0 else {
                logger.warning("Failed to decode subtitle for stream \(streamNumber), skipping...")
                continue
            }
            guard gotSubtitle != 0 else { continue }
            defer { avsubtitle_free(&subtitle) }

            // The decoder rescales the packet's timestamp to AV_TIME_BASE; the packet's own is the fallback.
            let presentationTime = subtitle.pts != Int64.min
                ? convertToTimeInterval(subtitle.pts, timeBase: AVRational(num: 1, den: AV_TIME_BASE))
                : convertToTimeInterval(packet!.pointee.pts, timeBase: stream.timeBase)

            // A frame with no rects is kept: it is what takes the caption before it off the screen.
            var rects: [DecodedSubtitleFrame.Rect] = []
            for i in 0 ..< Int(subtitle.num_rects) {
                if let rect = extractRect(subtitle.rects[i]!) {
                    rects.append(rect)
                }
            }
            let frame = DecodedSubtitleFrame(presentationTime: presentationTime,
                                             startDisplayTime: subtitle.start_display_time,
                                             endDisplayTime: subtitle.end_display_time,
                                             rects: rects)
            logger.debug("Track \(streamNumber) - \(presentationTime): \(rects.count) rects")
            frames[streamNumber, default: []].append(frame)
        }

        for (streamNumber, streamFrames) in frames {
            let subtitles = SubtitleTimeline.subtitles(from: streamFrames)
            if !subtitles.isEmpty {
                subtitleTracks[streamNumber] = subtitles
            }
        }
    }

    private func extractRect(_ rect: UnsafeMutablePointer<AVSubtitleRect>) -> DecodedSubtitleFrame.Rect? {
        let width = Int(rect.pointee.w)
        let height = Int(rect.pointee.h)
        let colors = Int(rect.pointee.nb_colors)
        guard rect.pointee.type == SUBTITLE_BITMAP, width > 0, height > 0, colors > 0,
              let bitmapData = rect.pointee.data.0, let paletteData = rect.pointee.data.1 else {
            return nil
        }

        // Entries are native endian 0xAARRGGBB words. Only `nb_colors` of them are guaranteed to exist.
        var palette: [UInt8] = []
        palette.reserveCapacity(min(colors, 256) * 4)
        for i in 0 ..< min(colors, 256) {
            #if _endian(little)
            let b = paletteData[i * 4 + 0]
            let g = paletteData[i * 4 + 1]
            let r = paletteData[i * 4 + 2]
            let a = paletteData[i * 4 + 3]
            #else
            let a = paletteData[i * 4 + 0]
            let r = paletteData[i * 4 + 1]
            let g = paletteData[i * 4 + 2]
            let b = paletteData[i * 4 + 3]
            #endif
            palette += [r, g, b, a]
        }

        // FFmpeg subtitle bitmaps may include padding at the end of each row.
        // Repack rows to a tightly packed width * height buffer so downstream OCR
        // interprets only actual image pixels.
        let lineSize = Int(rect.pointee.linesize.0)
        var indices = Data(capacity: width * height)
        for row in 0 ..< height {
            indices.append(UnsafeBufferPointer(start: bitmapData.advanced(by: row * lineSize), count: width))
        }

        return DecodedSubtitleFrame.Rect(x: Int(rect.pointee.x), y: Int(rect.pointee.y),
                                         width: width, height: height, indices: indices, palette: palette)
    }

    private func convertToTimeInterval(_ pts: some BinaryInteger, timeBase: AVRational) -> TimeInterval {
        let seconds = Double(pts) * av_q2d(timeBase)
        return TimeInterval(seconds)
    }
}
#endif
