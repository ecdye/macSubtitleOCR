//
// FuzzTestHelpers.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

/// A small, fixed pseudo-random generator, so every fuzz case is the same on every run and toolchain.
///
/// This is SplitMix64. The standard library's `random(in:using:)` may change how it maps the generator's
/// output between releases, so the helpers below draw from `next()` directly.
struct FuzzRandom: RandomNumberGenerator {
    // MARK: - Properties

    private var state: UInt64

    // MARK: - Lifecycle

    init(seed: UInt64) {
        state = seed
    }

    // MARK: - Functions

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A value in `0 ..< bound`, which must be positive.
    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// A value in `range`, which must not be empty.
    mutating func within(_ range: Range<Int>) -> Int {
        range.lowerBound + below(range.count)
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}

/// The seeds of a fuzz test that runs `count` cases by default. Set `MACSUBTITLEOCR_FUZZ_SCALE` to a
/// whole number to run that many times as many, to search further locally than CI does.
func fuzzSeeds(_ count: Int) -> Range<UInt64> {
    let scale = ProcessInfo.processInfo.environment["MACSUBTITLEOCR_FUZZ_SCALE"].flatMap { Int($0) } ?? 1
    return 0 ..< UInt64(count * max(scale, 1))
}

/// Changes `count` bytes of `data` at offsets drawn from `range` (the whole of `data` when nil), each by
/// flipping one bit or writing 0x00, 0xFF or a random byte, and returns a description of what was done.
@discardableResult
func mutateBytes(_ data: inout Data, count: Int, using rng: inout FuzzRandom, in range: Range<Int>? = nil) -> String {
    let range = range ?? 0 ..< data.count
    guard !range.isEmpty else { return "nothing to mutate" }
    var changes: [String] = []
    for _ in 0 ..< count {
        let offset = data.startIndex + rng.within(range)
        let old = data[offset]
        switch rng.below(4) {
        case 0: data[offset] ^= 1 << UInt8(rng.below(8))
        case 1: data[offset] = 0x00
        case 2: data[offset] = 0xFF
        default: data[offset] = rng.byte()
        }
        changes.append("\(offset): \(old.hex()) -> \(data[offset].hex())")
    }
    return changes.joined(separator: ", ")
}

/// Writes `value` big-endian into `width` bytes of `data` at `offset`.
func writeBigEndian(_ value: UInt64, width: Int, into data: inout Data, at offset: Int) {
    for byte in 0 ..< width {
        data[data.startIndex + offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * (width - 1 - byte)))
    }
}

/// Collects the fuzz cases of one test and checks that each one is survived.
///
/// A case passes if its body returns or throws a `macSubtitleOCRError`. Any other error, or a case that
/// takes longer than `slowCase`, is recorded as an issue naming the case, so a failure can be reproduced
/// from its name alone. A trap cannot be caught in process: set `MACSUBTITLEOCR_FUZZ_TRACE=1` to print
/// each case before it runs, and the last one printed is the one that trapped.
struct FuzzRun {
    // MARK: - Properties

    private static let trace = ProcessInfo.processInfo.environment["MACSUBTITLEOCR_FUZZ_TRACE"] == "1"
    private static let slowCase: Duration = .seconds(5)

    let name: String
    private(set) var cases = 0
    private(set) var returned = 0
    private(set) var subtitles = 0
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant

    // MARK: - Lifecycle

    init(_ name: String) {
        self.name = name
        start = clock.now
    }

    // MARK: - Functions

    /// Runs one case. `body` parses the mutated input and returns the subtitles it found, whose images
    /// are then built, since converting a decoded bitmap is as exposed to malformed input as parsing it.
    mutating func check(_ description: @autoclosure () -> String, _ body: () throws -> [Subtitle]) {
        let caseName = "\(name) case \(cases): \(description())"
        if Self.trace {
            FileHandle.standardError.write(Data("fuzz: \(caseName)\n".utf8))
        }
        cases += 1
        let caseStart = clock.now
        do {
            let found = try body()
            returned += 1
            subtitles += found.count
            buildImages(of: found)
        } catch is macSubtitleOCRError {
            // Rejecting malformed input is fine; trapping or hanging on it is not.
        } catch {
            Issue.record("\(caseName) threw \(error), not a macSubtitleOCRError")
        }
        let elapsed = clock.now - caseStart
        if Self.trace {
            FileHandle.standardError.write(Data("fuzz: done in \(elapsed)\n".utf8))
        }
        if elapsed > Self.slowCase {
            Issue.record("\(caseName) took \(elapsed)")
        }
    }

    /// Prints how many cases ran and how long they took, and checks that some cases still parsed, so a
    /// parser rejecting everything does not pass for robust.
    func finish() {
        let elapsed = clock.now - start
        print("\(name): \(cases) cases, \(returned) parsed, \(subtitles) subtitles, in \(elapsed)")
        #expect(returned > 0, "\(name): every case was rejected")
    }

    private func buildImages(of subtitles: [Subtitle]) {
        for subtitle in subtitles {
            guard let source = subtitle.makeImageSource() else { continue }
            _ = source.createImage(false)
        }
    }
}
