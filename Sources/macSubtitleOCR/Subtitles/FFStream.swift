//
// FFStream.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/10/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import CFFmpeg

class FFStream {
    var index: Int
    var codec: UnsafePointer<AVCodec>?
    var codecID: AVCodecID
    var codecContext: UnsafeMutablePointer<AVCodecContext>?
    var codecParameters: UnsafeMutablePointer<AVCodecParameters>?
    var timeBase: AVRational

    init(index: Int, codecParameters: UnsafeMutablePointer<AVCodecParameters>?, timeBase: AVRational) {
        self.index = index
        codecID = codecParameters!.pointee.codec_id
        codec = avcodec_find_decoder(codecID)
        codecContext = avcodec_alloc_context3(codec)
        avcodec_parameters_to_context(codecContext, codecParameters)
        avcodec_open2(codecContext, codec, nil)
        self.timeBase = timeBase
    }

    deinit {
        avcodec_free_context(&codecContext)
    }
}
