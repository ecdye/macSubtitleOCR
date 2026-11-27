//
// DecoderMetrics.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

import Foundation

/// One cue of an SRT file.
struct SRTCue: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    /// The text with every run of spaces and line breaks made one space, so that how a decoder or a
    /// reference wraps a line does not count against it.
    var normalizedText: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Reads the cues of an SRT file.
enum SRTReader {
    static func cues(fromFileAt url: URL) throws -> [SRTCue] {
        try cues(from: String(contentsOf: url, encoding: .utf8))
    }

    /// The cues of `contents`, in the order they are written. A block without a timing line is skipped.
    static func cues(from contents: String) -> [SRTCue] {
        let normalized = contents
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SRTCue] = []
        var block: [Substring] = []

        func finishBlock() {
            defer { block.removeAll() }
            guard let timing = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let times = block[timing].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]) else { return }
            let text = block[(timing + 1)...].joined(separator: "\n")
            cues.append(SRTCue(start: start, end: end, text: text))
        }

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                finishBlock()
            } else {
                block.append(line)
            }
        }
        finishBlock()
        return cues
    }

    /// Seconds from an `HH:MM:SS,mmm` timestamp; a full stop is accepted in place of the comma.
    static func seconds(_ timestamp: String) -> TimeInterval? {
        // Anything after the time itself, such as SRT position coordinates, is ignored.
        guard let token = timestamp.split(separator: " ", omittingEmptySubsequences: true).first else { return nil }
        let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }
}

/// A cue of a decoder's output matched to the cue of a reference it stands for.
struct CuePair {
    let output: SRTCue
    let reference: SRTCue
}

enum CueMatcher {
    /// How far apart the starts of two cues that do not overlap may be and still be matched, in seconds.
    static let nearestStartWindow: TimeInterval = 1

    /// The longest a cue is expected to last, in seconds; only output cues starting this long before a
    /// reference cue are considered for it, which keeps matching long files linear in practice.
    static let longestCue: TimeInterval = 30

    /// Matches each reference cue, in time order, to at most one output cue, and each output cue to at
    /// most one reference cue: the unmatched output cue it overlaps most, or failing any overlap the
    /// one starting nearest to it within `nearestStartWindow`.
    static func pairs(_ output: [SRTCue], _ reference: [SRTCue]) -> [CuePair] {
        let output = output.sorted { $0.start < $1.start }
        var used = [Bool](repeating: false, count: output.count)
        var pairs: [CuePair] = []

        for ref in reference.sorted(by: { $0.start < $1.start }) {
            let earliest = ref.start - longestCue
            var low = 0, high = output.count
            while low < high {
                let mid = (low + high) / 2
                if output[mid].start < earliest {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            var best: (index: Int, overlap: TimeInterval)?
            var nearest: (index: Int, distance: TimeInterval)?
            var index = low
            while index < output.count, output[index].start <= ref.end + nearestStartWindow {
                defer { index += 1 }
                guard !used[index] else { continue }
                let cue = output[index]
                let overlap = min(cue.end, ref.end) - max(cue.start, ref.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (index, overlap)
                }
                let distance = abs(cue.start - ref.start)
                if distance <= nearestStartWindow, distance < (nearest?.distance ?? .infinity) {
                    nearest = (index, distance)
                }
            }

            if let chosen = best?.index ?? nearest?.index {
                used[chosen] = true
                pairs.append(CuePair(output: output[chosen], reference: ref))
            }
        }
        return pairs
    }
}

/// How one track of a decoder's output compares with a reference, which may be another decoder's output.
struct CueScore: Equatable {
    /// Cues in the output.
    let cues: Int
    /// Cues in the reference.
    let referenceCues: Int
    /// Reference cues matched to an output cue.
    let matched: Int
    /// Matched cues whose text is the same as the reference's once whitespace is normalized.
    let exact: Int
    /// The mean similarity of the text of matched cues, as a percentage.
    let meanSimilarity: Double
    let maxStartErrorMs: Int
    let meanStartErrorMs: Double
    let maxEndErrorMs: Int
    let meanEndErrorMs: Double

    init(_ output: [SRTCue], against reference: [SRTCue]) {
        let pairs = CueMatcher.pairs(output, reference)
        let startErrors = pairs.map { milliseconds($0.output.start - $0.reference.start) }
        let endErrors = pairs.map { milliseconds($0.output.end - $0.reference.end) }

        cues = output.count
        referenceCues = reference.count
        matched = pairs.count
        exact = pairs.count { $0.output.normalizedText == $0.reference.normalizedText }
        meanSimilarity = mean(pairs.map {
            similarityPercentage(of: $0.output.normalizedText, and: $0.reference.normalizedText)
        })
        maxStartErrorMs = startErrors.max() ?? 0
        meanStartErrorMs = mean(startErrors.map(Double.init))
        maxEndErrorMs = endErrors.max() ?? 0
        meanEndErrorMs = mean(endErrors.map(Double.init))
    }
}

private func milliseconds(_ seconds: TimeInterval) -> Int {
    Int((abs(seconds) * 1000).rounded())
}

/// The mean of `values` rounded to a tenth, or zero for none.
private func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return (values.reduce(0, +) / Double(values.count) * 10).rounded() / 10
}

/// The internal decoder's scores on the bundled inputs as last recorded, which it must not fall below.
///
/// Stored as `Tests/Resources/decoder-baseline.json`, keyed by input file name and then by track number.
struct DecoderBaseline: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let cues: Int
        let matched: Int
        let exact: Int
        let maxStartErrorMs: Int
        let meanStartErrorMs: Double
        let maxEndErrorMs: Int
        let meanEndErrorMs: Double

        init(_ score: CueScore) {
            cues = score.cues
            matched = score.matched
            exact = score.exact
            maxStartErrorMs = score.maxStartErrorMs
            meanStartErrorMs = score.meanStartErrorMs
            maxEndErrorMs = score.maxEndErrorMs
            meanEndErrorMs = score.meanEndErrorMs
        }
    }

    /// How many fewer exactly read cues than recorded are accepted. Vision's readings of the same image
    /// differ slightly between macOS releases, so the runner in CI can read one cue differently from the
    /// machine the baseline was recorded on without the decoder having changed at all.
    static let exactCueSlack = 1

    /// How much larger, in milliseconds, a timing error may be than recorded. Timing does not depend on
    /// OCR, so this only absorbs rounding to the millisecond.
    static let timingSlackMs = 1.0

    var inputs: [String: [String: Entry]]

    static func load(from url: URL) throws -> DecoderBaseline {
        try JSONDecoder().decode(DecoderBaseline.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(contentsOf: "\n".utf8)
        try data.write(to: url, options: .atomic)
    }

    /// Every way `score` for `track` of `input` falls short of the recorded entry.
    ///
    /// The cue count must match exactly: a decoder that loses a cue or makes up one has regressed,
    /// and unlike the text, the number of cues does not depend on the OCR.
    func failures(for score: CueScore, input: String, track: Int) -> [String] {
        let label = "\(input) track \(track)"
        guard let entry = inputs[input]?[String(track)] else {
            return ["\(label): no baseline entry; regenerate it with MACSUBTITLEOCR_UPDATE_BASELINE=1"]
        }
        var failures: [String] = []
        if score.cues != entry.cues {
            failures.append("\(label): \(score.cues) cues, baseline \(entry.cues)")
        }
        if score.matched < entry.matched {
            failures.append("\(label): \(score.matched) cues matched to the reference, baseline \(entry.matched)")
        }
        if score.exact < entry.exact - Self.exactCueSlack {
            failures.append("\(label): \(score.exact) exact cues, baseline \(entry.exact) " +
                "(at most \(Self.exactCueSlack) fewer allowed)")
        }
        let timings: [(String, Double, Double)] = [
            ("max start error", Double(score.maxStartErrorMs), Double(entry.maxStartErrorMs)),
            ("mean start error", score.meanStartErrorMs, entry.meanStartErrorMs),
            ("max end error", Double(score.maxEndErrorMs), Double(entry.maxEndErrorMs)),
            ("mean end error", score.meanEndErrorMs, entry.meanEndErrorMs)
        ]
        for (name, actual, recorded) in timings where actual > recorded + Self.timingSlackMs {
            failures.append("\(label): \(name) \(actual) ms, baseline \(recorded) ms")
        }
        return failures
    }
}

/// The checks that hold the internal decoder to at least what the FFmpeg decoder achieves.
enum DecoderComparison {
    /// Every way `internalScore` is worse than `ffmpegScore` against the same reference.
    static func failures(internal internalScore: CueScore, ffmpeg ffmpegScore: CueScore,
                         label: String) -> [String] {
        var failures: [String] = []
        if internalScore.matched < ffmpegScore.matched {
            failures.append("\(label): internal matched \(internalScore.matched) reference cues, " +
                "FFmpeg \(ffmpegScore.matched)")
        }
        if internalScore.exact < ffmpegScore.exact {
            failures.append("\(label): internal read \(internalScore.exact) cues exactly, FFmpeg \(ffmpegScore.exact)")
        }
        let timings: [(String, Double, Double)] = [
            ("max start error", Double(internalScore.maxStartErrorMs), Double(ffmpegScore.maxStartErrorMs)),
            ("mean start error", internalScore.meanStartErrorMs, ffmpegScore.meanStartErrorMs),
            ("max end error", Double(internalScore.maxEndErrorMs), Double(ffmpegScore.maxEndErrorMs)),
            ("mean end error", internalScore.meanEndErrorMs, ffmpegScore.meanEndErrorMs)
        ]
        for (name, actual, other) in timings where actual > other + DecoderBaseline.timingSlackMs {
            failures.append("\(label): internal \(name) \(actual) ms, FFmpeg \(other) ms")
        }
        return failures
    }

    /// How many fewer cues than FFmpeg the internal decoder may produce for a track with no reference:
    /// one, or 1% of FFmpeg's count if that is more, because a cue OCR reads no text from is dropped
    /// from the SRT and the two decoders' images of the same cue can differ in how readable they are.
    static func allowedCueShortfall(ffmpegCues: Int) -> Int {
        max(1, ffmpegCues / 100)
    }
}
