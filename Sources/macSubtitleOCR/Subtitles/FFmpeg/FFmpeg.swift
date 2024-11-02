//
// FFmpeg.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/10/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
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

        // Read frames for the specific subtitle stream
        while av_read_frame(fmtCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let streamNumber = Int(packet!.pointee.stream_index)
            if streams[streamNumber] == nil {
                continue // Skip if stream is not a subtitle stream
            }
            let stream = streams[streamNumber]!
            logger.debug("Got packet for stream \(streamNumber)")

            let codecId = stream.codecID
            let timeBase: AVRational
            if codecId == AV_CODEC_ID_HDMV_PGS_SUBTITLE {
                // This fix is assuming that the tracks were from MKV files and so were encoded with a double timebase
                // first of the normal MKV timebase (1/1000) and then the normal PGS timebase (1/90000)
                // for some reason, it seems like there is an extra 0 in the timebase, so we need to divide by 10.
                // This is a hacky fix and should be replaced with a better solution in the future.
                timeBase = av_mul_q(AVRational(num: 1, den: 1000), AVRational(num: 1, den: 900000))
                logger.debug("Fixed Stream TB to: \(timeBase.num)/\(timeBase.den)")
            } else {
                timeBase = stream.timeBase
            }

            // Decode subtitle packet
            var gotSubtitle: Int32 = 0
            guard avcodec_decode_subtitle2(stream.codecContext, &subtitle, &gotSubtitle, packet) > 0 else {
                logger.warning("Failed to decode subtitle for stream \(streamNumber), skipping...")
                continue
            }

            if gotSubtitle != 0 {
                defer { avsubtitle_free(&subtitle) }
                var trackSubtitles = subtitleTracks[streamNumber] ?? []
                for i in 0 ..< Int(subtitle.num_rects) {
                    let rect = subtitle.rects[i]!
                    let sub = extractImageData(from: rect, index: trackSubtitles.count + 1)
                    let pts = convertToTimeInterval(packet!.pointee.pts, timeBase: stream.timeBase)
                    sub.startTimestamp = pts + convertToTimeInterval(subtitle.start_display_time, timeBase: timeBase)
                    sub.endTimestamp = pts + convertToTimeInterval(subtitle.end_display_time, timeBase: timeBase)
                    logger.debug("Track \(streamNumber) - Times: \(sub.startTimestamp!) --> \(sub.endTimestamp!)")
                    trackSubtitles.append(sub)
                }
                subtitleTracks[streamNumber] = trackSubtitles
            }
        }
    }

    private func extractImageData(from rect: UnsafeMutablePointer<AVSubtitleRect>, index: Int) -> Subtitle {
        let subtitle = Subtitle(index: index, numberOfColors: Int(rect.pointee.nb_colors))

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
            logger.debug("Image size: \(subtitle.imageWidth!)x\(subtitle.imageHeight!)")

            let imageSize = Int(rect.pointee.linesize.0) * (subtitle.imageHeight ?? 0)
            if let bitmapData = rect.pointee.data.0 {
                let buffer = UnsafeBufferPointer(start: bitmapData, count: imageSize)
                subtitle.imageData = Data(buffer)
            }
        }

        return subtitle
    }

    private func convertToTimeInterval(_ pts: some BinaryInteger, timeBase: AVRational) -> TimeInterval {
        let seconds = Double(pts) * av_q2d(timeBase)
        return TimeInterval(seconds)
    }
}
#endif
