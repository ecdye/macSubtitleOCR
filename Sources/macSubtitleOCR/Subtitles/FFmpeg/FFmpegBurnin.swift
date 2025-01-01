//
// FFmpegBurnin.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 1/1/25.
// Copyright © 2025-2025 Ethan Dye. All rights reserved.
//

#if FFMPEG
import CFFmpeg
import CoreGraphics
import Foundation
import os
import Vision

struct FFmpegBurnin {
    // MARK: - Properties

    private let logger = Logger(subsystem: "com.ecdye.macSubtitleOCR", category: "FFmpeg")
    private(set) var images = [Int: [Subtitle]]()
    private var imagesIndex = [Int: Int]()

    // MARK: - Lifecycle

    init(_ sub: String) throws {
        processMKVWithVision(mkvFilePath: sub)
        // var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        // // Open the input file
        // if avformat_open_input(&fmtCtx, sub, nil, nil) != 0 {
        //     throw macSubtitleOCRError.fileReadError("Failed to open input file: \(sub)")
        // }
        // defer { avformat_close_input(&fmtCtx) }

        // // Retrieve stream information
        // if avformat_find_stream_info(fmtCtx, nil) < 0 {
        //     throw macSubtitleOCRError.ffmpegError("FFmpeg failed to find stream info")
        // }

        // // Iterate over all streams and find subtitle tracks
        // var streamsToProcess = [Int: FFStream]()
        // for i in 0 ..< Int(fmtCtx!.pointee.nb_streams) {
        //     let stream = fmtCtx!.pointee.streams[i]!.pointee
        //     if stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
        //         let codecParameters = stream.codecpar
        //         let timeBase = stream.time_base
        //         let ffStream = FFStream(codecParameters: codecParameters, timeBase: timeBase)
        //         streamsToProcess[i] = ffStream
        //     }
        // }

        // processVideoTracks(fmtCtx: fmtCtx, streams: streamsToProcess)
    }

    // MARK: - Methods

    private mutating func processVideoTracks(fmtCtx: UnsafeMutablePointer<AVFormatContext>?,
                                             streams: [Int: FFStream]) {
        // Allocate packet
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        // Prepare a frame
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }

        // Read frames for the specific subtitle stream
        while av_read_frame(fmtCtx, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let streamNumber = Int(packet!.pointee.stream_index)
            logger.debug("Got packet for stream \(streamNumber)")

            if streams[streamNumber] == nil {
                continue // Skip if stream is not a subtitle stream
            }
            let stream = streams[streamNumber]!

            // Send packet to decoder
            guard avcodec_send_packet(stream.codecContext, packet) >= 0 else {
                logger.warning("Failed to send packet for stream \(streamNumber), skipping...")
                continue
            }

            while avcodec_receive_frame(stream.codecContext, frame) >= 0 {
                // let pts = convertToTimeInterval(frame!.pointee.pts, timeBase: stream.timeBase)

                // Analyze the frame for burned-in subtitles
                analyzeFrameForSubtitles(frame!, streamNumber: streamNumber)
            }
        }
    }

    private mutating func analyzeFrameForSubtitles(_ frame: UnsafeMutablePointer<AVFrame>, streamNumber: Int) {
        // Convert the frame to an image format for OCR
        if imagesIndex[streamNumber] == nil {
            imagesIndex[streamNumber] = 1
        } else {
            imagesIndex[streamNumber]! += 1
        }
        guard let image = convertFrameToImage(frame) else {
            print("Skipping frame \(imagesIndex[streamNumber]!)")
            return
        }
        let pts = convertToTimeInterval(frame.pointee.pts, timeBase: frame.pointee.time_base)
        if images[streamNumber] == nil {
            images[streamNumber] = []
        }
        images[streamNumber]!.append(Subtitle(index: imagesIndex[streamNumber]!, startTimestamp: pts, image: image))
    }

    func convertFrameToImage(_ frame: UnsafeMutablePointer<AVFrame>) -> CGImage? {
        // Get frame dimensions
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)

        // Create a buffer for the pixel data in RGBA format
        guard let rgbaBuffer = av_malloc(width * height * 4) else {
            print("Failed to allocate RGBA buffer")
            return nil
        }
        defer { av_free(rgbaBuffer) }

        // Prepare the SwsContext for conversion
        guard let swsContext = sws_getContext(
            frame.pointee.width, frame.pointee.height, AVPixelFormat(frame.pointee.format),
            frame.pointee.width, frame.pointee.height, AV_PIX_FMT_RGBA,
            SWS_BILINEAR, nil, nil, nil) else {
            print("Failed to initialize swsContext")
            return nil
        }
        defer { sws_freeContext(swsContext) }

        // Prepare an array for the output frame lines
        var rgbaFrameData = [UnsafeMutablePointer<UInt8>?](repeating: nil, count: 4)
        var rgbaLineSize = [Int32](repeating: 0, count: 4)
        rgbaFrameData[0] = rgbaBuffer.assumingMemoryBound(to: UInt8.self)
        rgbaLineSize[0] = Int32(width * 4)

        // Convert the frame to RGBA format
        withUnsafePointer(to: frame.pointee.data) { dataPointer in
            withUnsafePointer(to: frame.pointee.linesize) { linesizePointer in
                let dataPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                let linesizePointer = UnsafeRawPointer(linesizePointer).assumingMemoryBound(to: Int32.self)
                sws_scale(
                    swsContext,
                    dataPointer,
                    linesizePointer,
                    0,
                    frame.pointee.height,
                    &rgbaFrameData,
                    &rgbaLineSize)
            }
        }

        // Create a CGDataProvider from the RGBA buffer
        guard let dataProvider = CGDataProvider(data: Data(
            bytesNoCopy: rgbaBuffer,
            count: width * height * 4,
            deallocator: .none) as CFData) else {
            print("Failed to create CGDataProvider")
            return nil
        }

        // Create the CGImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }

    private func convertToTimeInterval(_ pts: some BinaryInteger, timeBase: AVRational) -> TimeInterval {
        let seconds = Double(pts) * av_q2d(timeBase)
        return TimeInterval(seconds)
    }

    func processMKVWithVision(mkvFilePath: String) {
        // Initialize FFmpeg
        av_log_set_level(AV_LOG_QUIET)
        var fmtCtx: UnsafeMutablePointer<AVFormatContext>?

        // Open the file
        if avformat_open_input(&fmtCtx, mkvFilePath, nil, nil) != 0 {
            fatalError("Failed to open input file")
        }
        defer { avformat_close_input(&fmtCtx) }

        // Find the best video stream
        var avCodec: UnsafePointer<AVCodec>?
        let videoStreamIndex = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, &avCodec, 0)
        guard videoStreamIndex >= 0 else { fatalError("No video stream found") }

        var codecCtx = avcodec_alloc_context3(avCodec)
        defer { avcodec_free_context(&codecCtx) }

        avcodec_parameters_to_context(codecCtx, fmtCtx!.pointee.streams[Int(videoStreamIndex)]!.pointee.codecpar)
        guard let codec = avcodec_find_decoder(codecCtx!.pointee.codec_id) else {
            fatalError("Unsupported codec")
        }
        if avcodec_open2(codecCtx, codec, nil) < 0 {
            fatalError("Failed to open codec")
        }

        // Allocate frame and packet
        var frame = av_frame_alloc()
        var packet = av_packet_alloc()
        defer {
            av_frame_free(&frame)
            av_packet_free(&packet)
        }

        // Initialize Vision Request
        let textRequest = VNRecognizeTextRequest { request, error in
            guard error == nil else {
                print("Vision request error: \(error!.localizedDescription)")
                return
            }

            if let results = request.results as? [VNRecognizedTextObservation] {
                for observation in results {
                    print("Detected text: \(observation.topCandidates(1).first?.string ?? "")")
                }
            }
        }
        textRequest.recognitionLevel = .accurate
        textRequest.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.25)

        // Read frames and process
        while av_read_frame(fmtCtx, packet) >= 0 {
            if packet!.pointee.stream_index == videoStreamIndex {
                // Send packet to decoder
                if avcodec_send_packet(codecCtx, packet) >= 0 {
                    while avcodec_receive_frame(codecCtx, frame) >= 0 {
                        // Convert frame to CGImage
                        guard let cgImage = convertFrameToImage(frame!) else {
                            print("Failed to convert frame to CGImage")
                            continue
                        }

                        // Process image with Vision
                        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                        do {
                            try requestHandler.perform([textRequest])
                        } catch {
                            print("Failed to perform Vision request: \(error.localizedDescription)")
                        }
                    }
                }
            }
            av_packet_unref(packet)
        }

        // Free FFmpeg resources
        avformat_close_input(&fmtCtx)
    }
}
#endif
