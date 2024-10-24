//
// macSubtitleOCRExperimentalOptions.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/24/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

import ArgumentParser

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
