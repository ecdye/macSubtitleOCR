//
// FFmpeg.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/9/24.
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
        var streamsToProcess: [Int] = []
        for i in 0 ..< Int(fmtCtx!.pointee.nb_streams) {
            let stream = fmtCtx!.pointee.streams[i]
            if stream!.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
                // Handle subtitle stream
                streamsToProcess.append(i)
            }
        }

        try processSubtitleTracks(fmtCtx: fmtCtx, streamIndex: streamsToProcess)
        // Clean up
        avformat_close_input(&fmtCtx)
    }

    // MARK: - Private Methods

    private mutating func processSubtitleTracks(fmtCtx: UnsafeMutablePointer<AVFormatContext>?, streamIndex: [Int]) throws {
        logger.debug("Processing subtitle track \(streamIndex)")
        var codecCtx: UnsafeMutablePointer<AVCodecContext>?
        let stream = fmtCtx!.pointee.streams[streamIndex[0]]!
        let codecId = stream.pointee.codecpar.pointee.codec_id

        guard let codec = avcodec_find_decoder(codecId) else {
            fatalError("Could not find subtitle decoder")
        }

        // Allocate codec context
        codecCtx = avcodec_alloc_context3(codec)
        guard codecCtx != nil else {
            fatalError("Could not allocate codec context")
        }
        defer { avcodec_free_context(&codecCtx) }

        // Copy codec parameters to codec context
        if avcodec_parameters_to_context(codecCtx, stream.pointee.codecpar) < 0 {
            fatalError("Failed to copy codec parameters")
        }
        if avcodec_open2(codecCtx, codec, nil) < 0 {
            fatalError("Could not open codec")
        }

        let subtitleTimeBase = stream.pointee.time_base

        // Allocate packet
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        var subtitle = AVSubtitle()
        let timeBase: Double = (codecId == AV_CODEC_ID_DVD_SUBTITLE) ? 1000 : 900000000

        // Read frames for the specific subtitle stream
        while av_read_frame(fmtCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            logger.debug("Got packet for stream \(packet!.pointee.stream_index)")
            if streamIndex.contains(Int(packet!.pointee.stream_index)) {
                let streamIndex = Int(packet!.pointee.stream_index)
                var gotSubtitle: Int32 = 0

                // Decode subtitle packet
                let ret = avcodec_decode_subtitle2(codecCtx, &subtitle, &gotSubtitle, packet)
                if ret < 0 {
                    logger.warning("Error decoding subtitle for stream \(streamIndex), skipping...")
                    continue
                }

                if gotSubtitle != 0 {
                    var trackSubtitles = subtitleTracks[streamIndex] ?? []
                    for i in 0 ..< Int(subtitle.num_rects) {
                        let rect = subtitle.rects[i]!
                        let sub = extractImageData(from: rect)
                        let pts = convertPTSToTimeInterval(
                            pts: packet!.pointee.pts,
                            timeBase: subtitleTimeBase)
                        sub.startTimestamp = pts + TimeInterval(subtitle.start_display_time) / timeBase
                        sub.endTimestamp = pts + TimeInterval(subtitle.end_display_time) / timeBase
                        logger.debug("Track \(streamIndex) - Times: \(sub.startTimestamp!) --> \(sub.endTimestamp!)")
                        trackSubtitles.append(sub)
                    }
                    subtitleTracks[streamIndex] = trackSubtitles

                    avsubtitle_free(&subtitle)
                }
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
