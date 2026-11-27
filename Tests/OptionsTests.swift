//
// OptionsTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import ArgumentParser
@testable import macSubtitleOCR
import Testing

// Issue #75: --max-threads was never validated, so 0 started no OCR tasks and wrote empty
// output, and a negative value trapped on the task range.

@Test(arguments: [["-t", "0"], ["--max-threads", "0"], ["--max-threads=-1"]])
func maxThreadsBelowOneIsRejected(option: [String]) {
    let error = #expect(throws: (any Error).self) { try macSubtitleOCR.parse(["input.sup", "output"] + option) }
    let message = error.map { macSubtitleOCR.message(for: $0) } ?? ""
    #expect(message.contains("--max-threads must be at least 1"))
}

@Test func maxThreadsOfOneIsAccepted() throws {
    let command = try macSubtitleOCR.parse(["input.sup", "output", "-t", "1"])
    #expect(command.options.maxThreads == 1)
}

@Test func defaultMaxThreadsIsAccepted() throws {
    _ = try macSubtitleOCR.parse(["input.sup", "output"])
}
