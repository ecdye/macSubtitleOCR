//
// SubtitleActors.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 10/25/24.
// Copyright © 2024 Ethan Dye. All rights reserved.
//

actor SubtitleAccumulator {
    var subtitles = [Subtitle]()
    var json = [SubtitleJSONResult]()

    func append(_ subtitle: Subtitle, _ json: SubtitleJSONResult) {
        subtitles.append(subtitle)
        self.json.append(json)
    }
}

actor AsyncSemaphore {
    private var permits: Int

    init(limit: Int) {
        permits = limit
    }

    func wait() async {
        while permits <= 0 {
            await Task.yield()
        }
        permits -= 1
    }

    func signal() {
        permits += 1
    }
}
