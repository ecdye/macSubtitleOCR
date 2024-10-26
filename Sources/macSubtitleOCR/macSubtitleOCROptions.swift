//
// macSubtitleOCROptions.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/24/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import ArgumentParser

struct Options: ParsableArguments {
    @Option(wrappedValue: "en", name: [.customShort("l"), .long],
            help: ArgumentHelp(
                "Comma-separated list of languages for OCR (ISO 639-1 codes)",
                valueName: "l"))
    var languages: String

    @Option(wrappedValue: 4, name: [.customShort("t"), .long],
            help: ArgumentHelp("Maximum number of threads to use for OCR", valueName: "n"))
    var maxThreads: Int

    @Option(name: [.customShort("w"), .long],
            help: ArgumentHelp("Comma-separated list of custom words to recognize", valueName: "w"))
    var customWords: String?

    @Flag(name: [.customShort("i"), .long], help: "Invert images before OCR")
    var invert = false

    @Flag(name: [.customShort("s"), .long], help: "Save extracted subtitle images to disk")
    var saveImages = false

    @Flag(name: [.customShort("j"), .long], help: "Save OCR results as raw JSON files")
    var json = false

    #if FFMPEG
        @Flag(name: [.customShort("f"), .long], help: "Use FFmpeg decoder")
        var ffmpegDecoder = false
    #endif

    @Flag(help: "Disable correction of 'l' to 'I' in OCR results")
    var disableICorrection = false
}

struct ExperimentalOptions: ParsableArguments {
    @Flag(help: "Force old API (experimental)")
    var forceOldAPI = false

    @Flag(help: "Save extracted subtitle file to disk (experimental)")
    var saveSubtitleFile = false

    @Flag(help: "Enable fast mode (experimental)")
    var fastMode = false

    @Flag(help: "Disable language correction (experimental)")
    var disableLanguageCorrection = false
}
