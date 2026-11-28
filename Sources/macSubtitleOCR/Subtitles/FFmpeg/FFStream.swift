//
// FFStream.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/10/24.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

#if FFMPEG
import CFFmpeg
import Foundation

/// An opened decoder for one bitmap subtitle stream.
final class FFStream {
    struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var codecContext: UnsafeMutablePointer<AVCodecContext>?
    let timeBase: AVRational
    /// The timestamp of the last packet read, in `timeBase`, for a subtitle the decoder gives up when
    /// flushed without a timestamp of its own. `Int64.min` is AV_NOPTS_VALUE.
    var lastPacketPTS = Int64.min

    /// Whether a stream with these parameters holds bitmap subtitles, the only kind that is OCR'd.
    static func isBitmapSubtitle(_ codecParameters: UnsafePointer<AVCodecParameters>) -> Bool {
        guard codecParameters.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE,
              let descriptor = avcodec_descriptor_get(codecParameters.pointee.codec_id) else {
            return false
        }
        return descriptor.pointee.props & AV_CODEC_PROP_BITMAP_SUB != 0
    }

    /// Finds and opens a decoder for the stream, throwing `SetupError` if any step fails.
    init(codecParameters: UnsafePointer<AVCodecParameters>, timeBase: AVRational) throws {
        self.timeBase = timeBase
        let codecID = codecParameters.pointee.codec_id
        let name = String(cString: avcodec_get_name(codecID))
        guard let codec = avcodec_find_decoder(codecID) else {
            throw SetupError(description: "no \(name) decoder in this FFmpeg build")
        }
        guard let context = avcodec_alloc_context3(codec) else {
            throw SetupError(description: "could not allocate a \(name) decoder")
        }
        codecContext = context
        // deinit frees the context if a later step throws.
        var result = avcodec_parameters_to_context(context, codecParameters)
        guard result >= 0 else {
            throw SetupError(description: "could not configure the \(name) decoder: \(Self.errorString(result))")
        }
        // Packets are timed in the stream's time base. Without it, the decoder cannot rescale their
        // timestamps into AVSubtitle.pts, nor turn packet durations into end times.
        context.pointee.pkt_timebase = timeBase
        result = avcodec_open2(context, codec, nil)
        guard result >= 0 else {
            throw SetupError(description: "could not open the \(name) decoder: \(Self.errorString(result))")
        }
    }

    deinit {
        avcodec_free_context(&codecContext)
    }

    private static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(AV_ERROR_MAX_STRING_SIZE))
        guard av_strerror(code, &buffer, buffer.count) == 0 else {
            return "error \(code)"
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
