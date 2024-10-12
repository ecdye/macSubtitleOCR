//
// FFmpeg.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/10/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import CFFmpeg
import Foundation
import os

struct FFmpeg {
    // MARK: - Properties

    private var logger = Logger(subsystem: "github.ecdye.macSubtitleOCR", category: "FFmpeg")
    private(set) var subtitleTracks = [Int: [Subtitle]]()

    // MARK: - Lifecycle

    init(_ sub: String) throws {
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        // Open the input file
        if avformat_open_input(&fmtCtx, sub, nil, nil) != 0 {
            fatalError("Could not open input file")
        }
        defer { avformat_close_input(&fmtCtx) }

        // Retrieve stream information
        if avformat_find_stream_info(fmtCtx, nil) < 0 {
            fatalError("Could not find stream info")
        }

        // Iterate over all streams and find subtitle tracks
        var streamsToProcess: [FFStream] = []
        for i in 0 ..< Int(fmtCtx!.pointee.nb_streams) {
            let stream = fmtCtx!.pointee.streams[i]
            if stream!.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                let codecParameters = stream!.pointee.codecpar
                let timeBase = stream!.pointee.time_base
                let stream = FFStream(codecParameters: codecParameters, timeBase: timeBase)
                streamsToProcess.append(stream)
            }
        }

        processSubtitleTracks(fmtCtx: fmtCtx, streams: streamsToProcess)
    }

    // MARK: - Methods

    private mutating func processSubtitleTracks(fmtCtx: UnsafeMutablePointer<AVFormatContext>?, streams: [FFStream]) {
        // Allocate packet
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var subtitle = AVSubtitle()

        // Read frames for the specific subtitle stream
        while av_read_frame(fmtCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let streamNumber = Int(packet!.pointee.stream_index)
            let stream = streams[streamNumber]
            logger.debug("Got packet for stream \(streamNumber)")

            let codecId = stream.codecID
            let timeBase: Double = (codecId == AV_CODEC_ID_DVD_SUBTITLE) ? 1000 : 900000000
            var gotSubtitle: Int32 = 0

            // Decode subtitle packet
            let ret = avcodec_decode_subtitle2(stream.codecContext, &subtitle, &gotSubtitle, packet)
            if ret < 0 {
                logger.warning("Error decoding subtitle for stream \(streamNumber), skipping...")
                continue
            }

            if gotSubtitle != 0 {
                defer { avsubtitle_free(&subtitle) }
                var trackSubtitles = subtitleTracks[streamNumber] ?? []
                for i in 0 ..< Int(subtitle.num_rects) {
                    let rect = subtitle.rects[i]!
                    let sub = extractImageData(from: rect)
                    let pts = convertPTSToTimeInterval(
                        pts: packet!.pointee.pts,
                        timeBase: stream.timeBase)
                    sub.startTimestamp = pts + TimeInterval(subtitle.start_display_time) / timeBase
                    sub.endTimestamp = pts + TimeInterval(subtitle.end_display_time) / timeBase
                    logger.debug("Track \(streamNumber) - Times: \(sub.startTimestamp!) --> \(sub.endTimestamp!)")
                    trackSubtitles.append(sub)
                }
                subtitleTracks[streamNumber] = trackSubtitles
            }
        }
    }

    private func extractImageData(from rect: UnsafeMutablePointer<AVSubtitleRect>) -> Subtitle {
        let subtitle = Subtitle(numberOfColors: Int(rect.pointee.nb_colors))

        // Check if the subtitle is an image (bitmap)
        if rect.pointee.type == SUBTITLE_BITMAP {
            // Extract palette (if available)
            if rect.pointee.nb_colors > 0, let paletteData = rect.pointee.data.1 {
                if subtitle.imagePalette == nil {
                    subtitle.imagePalette = []
                }
                for i in 0 ..< 256 {
                    let r = paletteData[i * 4 + 0]
                    let g = paletteData[i * 4 + 1]
                    let b = paletteData[i * 4 + 2]
                    let a = paletteData[i * 4 + 3]

                    subtitle.imagePalette?.append(contentsOf: [r, g, b, a])
                }
            }

            // Extract image data (bitmap)
            subtitle.imageWidth = Int(rect.pointee.w)
            subtitle.imageHeight = Int(rect.pointee.h)
            subtitle.imageXOffset = Int(rect.pointee.linesize.0)
            logger.debug("Image size: \(subtitle.imageWidth!)x\(subtitle.imageHeight!)")

            let imageSize = (subtitle.imageXOffset ?? 0) * (subtitle.imageHeight ?? 0)
            if let bitmapData = rect.pointee.data.0 {
                let buffer = UnsafeBufferPointer(start: bitmapData, count: imageSize)
                subtitle.imageData = Data(buffer)
            }
        }

        return subtitle
    }

    private func convertPTSToTimeInterval(pts: Int64, timeBase: AVRational) -> TimeInterval {
        let seconds = Double(pts) * av_q2d(timeBase)
        return TimeInterval(seconds)
    }
}
