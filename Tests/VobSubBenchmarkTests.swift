//
// VobSubBenchmarkTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import CryptoKit
import Foundation
@testable import macSubtitleOCR
import Testing

/// Times the internal VobSub decoder alone, without OCR, and prints a digest of everything it decoded so
/// that two builds can be checked to give the same result. Set VOBSUB_BENCHMARK to the path of a `.sub`
/// with its `.idx` beside it, or to `1` for `sintel.sub`, preferably with
/// `swift test -c release -Xswiftc -enable-testing --filter vobSubBenchmark`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOBSUB_BENCHMARK"] != nil))
func vobSubBenchmark() throws {
    let setting = try #require(ProcessInfo.processInfo.environment["VOBSUB_BENCHMARK"])
    let sub = setting == "1" ? URL(fileURLWithPath: TestFilePaths.sub.path) : URL(fileURLWithPath: setting)
    let idx = sub.deletingPathExtension().appendingPathExtension("idx")
    let clock = ContinuousClock()

    var vobSub: VobSub?
    let parse = try clock.measure {
        vobSub = try VobSub(sub, idx)
    }
    let tracks = try #require(vobSub).tracks

    var images = 0
    let render = clock.measure {
        for track in tracks {
            for subtitle in track.subtitles where subtitle.makeImageSource()?.createImage(false) != nil {
                images += 1
            }
        }
    }

    var hasher = SHA256()
    func add(_ value: some Any) {
        hasher.update(data: Data(String(describing: value).utf8))
    }
    for track in tracks {
        add(track.index)
        add(track.language as Any)
        for subtitle in track.subtitles {
            add([
                subtitle.index,
                subtitle.imageXOffset,
                subtitle.imageYOffset,
                subtitle.imageWidth,
                subtitle.imageHeight,
                subtitle.evenOffset,
                subtitle.oddOffset,
                subtitle.numberOfColors
            ])
            add([subtitle.startTimestamp, subtitle.endTimestamp])
            add(subtitle.imagePalette as Any)
            add(subtitle.imageAlpha as Any)
            hasher.update(data: subtitle.imageData ?? Data())
        }
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let count = tracks.reduce(0) { $0 + $1.subtitles.count }
    var ffmpeg = ""
    #if FFMPEG
    let ffmpegParse = try clock.measure {
        _ = try FFmpeg(idx.path)
    }
    ffmpeg = ", FFmpeg \(ffmpegParse)"
    #endif
    print("""
    vobSubBenchmark: \(count) subtitles in \(tracks.count) tracks, \(images) images; \
    parse \(parse)\(ffmpeg), images \(render); digest \(digest)
    """)
}
