//
// DecoderComparisonTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/27/26.
// Copyright © 2026-2026 Ethan Dye. All rights reserved.
//

#if FFMPEG
import CryptoKit
import Foundation
@testable import macSubtitleOCR
import Testing

/// Runs the internal and FFmpeg decoders over the same inputs and holds the internal one to a checked
/// in baseline and to at least what FFmpeg achieves. See `Tests/Resources/README.md`.
///
/// One test rather than one per input: the inputs are measured one after another so their wall times
/// do not compete, and the report is printed as one set of tables.
@Test func decoderComparison() async throws {
    let environment = ProcessInfo.processInfo.environment
    let updateBaseline = environment["MACSUBTITLEOCR_UPDATE_BASELINE"] == "1"
    let timeLimit = environment["MACSUBTITLEOCR_SAMPLE_TIMEOUT"].flatMap(Double.init) ?? 900

    var samples = ComparisonSample.bundled
    if let directory = environment["MACSUBTITLEOCR_SAMPLES_DIR"], !directory.isEmpty {
        samples += try ComparisonSample.local(in: URL(fileURLWithPath: directory))
    }

    var results: [SampleResult] = []
    for sample in samples {
        // Printed first so that a decoder that traps, taking the test process with it, is named in the log.
        print("decoderComparison: measuring \(sample.name)")
        let internalRun = await DecoderRun.measure(sample, with: .internal, timeLimit: timeLimit)
        let ffmpegRun = await DecoderRun.measure(sample, with: .ffmpeg, timeLimit: timeLimit)
        results.append(SampleResult(sample: sample, internalRun: internalRun, ffmpegRun: ffmpegRun))
    }

    let report = ComparisonReport.markdown(for: results)
    print(report)
    if let summary = environment["GITHUB_STEP_SUMMARY"], let handle = FileHandle(forWritingAtPath: summary) {
        handle.seekToEndOfFile()
        handle.write(Data(report.utf8))
        try handle.close()
    }

    let baselineURL = try #require(Bundle.module.url(forResource: "decoder-baseline.json", withExtension: nil))
    var failures: [String] = []
    if updateBaseline {
        let baseline = baselineFrom(results)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/decoder-baseline.json")
        try baseline.write(to: source)
        print("decoderComparison: wrote \(source.path)")
    } else {
        let baseline = try DecoderBaseline.load(from: baselineURL)
        failures += baselineFailures(results, baseline)
    }
    failures += results.flatMap(\.comparisonFailures)

    for failure in failures {
        Issue.record(Comment(rawValue: failure))
    }
}

private func baselineFrom(_ results: [SampleResult]) -> DecoderBaseline {
    var inputs: [String: [String: DecoderBaseline.Entry]] = [:]
    for result in results {
        guard let key = result.sample.baselineKey, let reference = result.sample.referenceCues,
              case let .ran(run) = result.internalRun else { continue }
        for track in run.tracks {
            inputs[key, default: [:]][String(track.number)] =
                DecoderBaseline.Entry(CueScore(track.cues, against: reference))
        }
    }
    return DecoderBaseline(inputs: inputs)
}

private func baselineFailures(_ results: [SampleResult], _ baseline: DecoderBaseline) -> [String] {
    var failures: [String] = []
    for result in results {
        guard let key = result.sample.baselineKey, let reference = result.sample.referenceCues else { continue }
        guard case let .ran(run) = result.internalRun else {
            failures.append("\(key): the internal decoder did not run, \(result.internalRun.status)")
            continue
        }
        let recorded = Set(baseline.inputs[key]?.keys.compactMap { Int($0) } ?? [])
        let produced = Set(run.tracks.map(\.number))
        for missing in recorded.subtracting(produced).sorted() {
            failures.append("\(key) track \(missing): in the baseline but not decoded")
        }
        for track in run.tracks {
            failures += baseline.failures(for: CueScore(track.cues, against: reference), input: key,
                                          track: track.number)
        }
    }
    return failures
}

// MARK: - Samples

/// An input measured by the harness.
struct ComparisonSample {
    /// How the input is named in the report.
    let name: String
    /// The file the internal decoder reads: a `.sup`, `.sub` or `.mkv`/`.mks`.
    let input: URL
    /// The `.idx` of a VobSub, which FFmpeg is given in place of the `.sub`.
    let idx: URL?
    let reference: URL?
    /// Further command line options, from a `<name>.options` file beside a local sample.
    let arguments: [String]
    /// The key of the input in the baseline, for the bundled inputs only.
    let baselineKey: String?
    let referenceCues: [SRTCue]?

    init(name: String, input: URL, idx: URL? = nil, reference: URL?, arguments: [String] = [],
         baselineKey: String? = nil) {
        self.name = name
        self.input = input
        self.idx = idx
        self.reference = reference
        self.arguments = arguments
        self.baselineKey = baselineKey
        referenceCues = reference.flatMap { try? SRTReader.cues(fromFileAt: $0) }
    }

    static var bundled: [ComparisonSample] {
        let reference = URL(fileURLWithPath: goodSRTPath)
        return TestFilePaths.allCases.map { file in
            let input = URL(fileURLWithPath: file.path)
            let idx = input.pathExtension == "sub" ? input.deletingPathExtension().appendingPathExtension("idx") : nil
            return ComparisonSample(name: input.lastPathComponent, input: input, idx: idx, reference: reference,
                                    baselineKey: input.lastPathComponent)
        }
    }

    /// Every `.sup`, `.idx` with its `.sub`, `.mkv` and `.mks` under `directory`, searched recursively.
    ///
    /// A `<name>.srt` beside an input is its reference, and a `<name>.options` holds further command
    /// line options, separated by whitespace, such as `-l ar`. An input with the same size and leading
    /// mebibyte as one already found is a copy of it and is measured once.
    static func local(in directory: URL) throws -> [ComparisonSample] {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw macSubtitleOCRError.fileReadError("Cannot read the samples directory \(directory.path)")
        }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { ["sup", "idx", "mkv", "mks"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }

        var seen: [String: String] = [:]
        var samples: [ComparisonSample] = []
        for file in files {
            let base = file.deletingPathExtension()
            // Resolved the same way as `directory`, which may drop a /private prefix, but without
            // following the file itself if it is a link.
            let folder = file.deletingLastPathComponent().resolvingSymlinksInPath().path
            let name = String((folder + "/" + file.lastPathComponent).dropFirst(directory.path.count + 1))
            var input = file
            var idx: URL?
            if file.pathExtension.lowercased() == "idx" {
                input = base.appendingPathExtension("sub")
                idx = file
                guard FileManager.default.fileExists(atPath: input.path) else {
                    print("decoderComparison: skipping \(name), it has no .sub")
                    continue
                }
            }
            let fingerprint = try fingerprint(of: input)
            if let original = seen[fingerprint] {
                print("decoderComparison: skipping \(name), a copy of \(original)")
                continue
            }
            seen[fingerprint] = name

            let srt = base.appendingPathExtension("srt")
            let options = base.appendingPathExtension("options")
            let arguments = (try? String(contentsOf: options, encoding: .utf8))?
                .split(whereSeparator: \.isWhitespace).map(String.init) ?? []
            samples.append(ComparisonSample(
                name: name, input: input, idx: idx,
                reference: FileManager.default.fileExists(atPath: srt.path) ? srt : nil,
                arguments: arguments))
        }
        return samples
    }

    private static func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 1 << 20) ?? Data()
        let digest = SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(digest)"
    }
}

// MARK: - Running a decoder

enum Decoder: String {
    case `internal`
    case ffmpeg = "FFmpeg"
}

/// The settings `SubtitleProcessor` is made with, read from the command line the CLI would be given.
private struct ProcessorSettings {
    let languages: String
    let invert: Bool
    let customWords: [String]?
    let fastMode: Bool
    let disableLanguageCorrection: Bool
    let disableICorrection: Bool
    let forceOldAPI: Bool
    let maxThreads: Int

    init(_ command: macSubtitleOCR) {
        languages = command.options.languages
        invert = command.options.invert
        customWords = command.options.customWords?.split(separator: ",").map(String.init)
        fastMode = command.experimentalOptions.fastMode
        disableLanguageCorrection = command.experimentalOptions.disableLanguageCorrection
        disableICorrection = command.options.disableICorrection
        forceOldAPI = command.experimentalOptions.forceOldAPI
        maxThreads = command.options.maxThreads
    }
}

/// One subtitle track as a decoder hands it over, before OCR.
private struct DecodedTrack {
    let number: Int
    let language: String?
    let subtitles: [Subtitle]
}

private struct NoBitmapTracks: Error {}

private struct TimedOut: Error {
    let seconds: Double
}

/// The SRT cues a decoder produced for one track, and how long OCR took for it.
struct TrackOutput {
    let number: Int
    let cues: [SRTCue]
    let ocrSeconds: Double
}

enum RunOutcome {
    case ran(DecoderRun)
    case noBitmapTracks
    case failed(String)

    /// A short description, safe to put in a Markdown table cell.
    var status: String {
        switch self {
        case .ran: "ok"
        case .noBitmapTracks: "no bitmap tracks"
        case let .failed(reason):
            reason.replacingOccurrences(of: "|", with: "\\|").split(whereSeparator: \.isNewline).joined(separator: " ")
        }
    }
}

struct DecoderRun {
    let decodeSeconds: Double
    let tracks: [TrackOutput]

    var ocrSeconds: Double {
        tracks.map(\.ocrSeconds).reduce(0, +)
    }

    /// Decodes `sample` with `decoder` and OCRs every track as the CLI would, timing the two apart.
    static func measure(_ sample: ComparisonSample, with decoder: Decoder, timeLimit: Double) async -> RunOutcome {
        do {
            #if GITHUB_ACTIONS // As the other tests do in CI, to avoid timeouts.
            let base = ["--max-threads", "1"]
            #else
            let base: [String] = []
            #endif
            let command = try macSubtitleOCR.parse([sample.input.path, NSTemporaryDirectory()] + base +
                sample.arguments)
            let settings = ProcessorSettings(command)
            let decoderRun = try await withTimeLimit(timeLimit) {
                try await Self.run(sample, with: decoder, settings: settings)
            }
            return .ran(decoderRun)
        } catch is NoBitmapTracks {
            return .noBitmapTracks
        } catch let error as TimedOut {
            return .failed("timed out after \(Int(error.seconds)) s")
        } catch {
            return .failed("threw: \(error)")
        }
    }

    private static func run(_ sample: ComparisonSample, with decoder: Decoder,
                            settings: ProcessorSettings) async throws -> DecoderRun {
        let clock = ContinuousClock()
        let decodeStart = clock.now
        // In track number order, which is how the two decoders' tracks are paired. The MKV parser hands its
        // tracks over in no fixed order.
        let decoded = try (decoder == .internal ? decodeInternal(sample) : decodeFFmpeg(sample))
            .sorted { $0.number < $1.number }
        let decodeSeconds = seconds(decodeStart.duration(to: clock.now))
        guard !decoded.isEmpty else { throw NoBitmapTracks() }

        var tracks: [TrackOutput] = []
        for track in decoded {
            // As the CLI does, the internal decoder adds the track's own language and FFmpeg does not.
            var languages = settings.languages
            if decoder == .internal, let language = track.language {
                languages += ",\(language)"
            }
            let directory = try makeOutputDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }

            let ocrStart = clock.now
            let processor = SubtitleProcessor(for: track.subtitles, from: track.number, withOptions: settings.invert,
                                              false, languages, settings.customWords, settings.fastMode,
                                              settings.disableLanguageCorrection, settings.disableICorrection,
                                              settings.forceOldAPI, directory, settings.maxThreads)
            let result = try await processor.process()
            let ocrSeconds = seconds(ocrStart.duration(to: clock.now))

            try macSubtitleOCRFileHandler(outputDirectory: directory).saveSRTFile(for: result)
            let srt = URL(fileURLWithPath: directory).appendingPathComponent("track_\(track.number).srt")
            let cues = FileManager.default.fileExists(atPath: srt.path) ? try SRTReader.cues(fromFileAt: srt) : []
            tracks.append(TrackOutput(number: track.number, cues: cues, ocrSeconds: ocrSeconds))
        }
        return DecoderRun(decodeSeconds: decodeSeconds, tracks: tracks)
    }

    /// Mirrors `processInternalDecoder`, stopping before OCR.
    private static func decodeInternal(_ sample: ComparisonSample) throws -> [DecodedTrack] {
        let input = sample.input
        switch input.pathExtension.lowercased() {
        case "sup":
            return try [DecodedTrack(number: 0, language: nil, subtitles: PGS(input).subtitles)]
        case "sub":
            let idx = sample.idx ?? input.deletingPathExtension().appendingPathExtension("idx")
            return try VobSub(input, idx).tracks.map {
                DecodedTrack(number: $0.index, language: $0.language, subtitles: $0.subtitles)
            }
        case "mkv", "mks":
            let mkv = try MKVSubtitleExtractor(filePath: input.path)
            try mkv.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
            return try mkv.tracks.compactMap { track in
                let subtitles: [Subtitle]
                switch track.codecID {
                case "S_HDMV/PGS":
                    subtitles = try track.trackData.withUnsafeBytes { try PGS($0) }.subtitles
                case "S_VOBSUB":
                    subtitles = try track.trackData.withUnsafeBytes { try VobSub($0, track.idxData ?? "") }.subtitles
                default:
                    return nil
                }
                return DecodedTrack(number: track.trackNumber, language: track.language, subtitles: subtitles)
            }
        default:
            throw macSubtitleOCRError.invalidInputFile("Unsupported input \(input.lastPathComponent)")
        }
    }

    /// Mirrors `processFFmpegDecoder`, stopping before OCR.
    private static func decodeFFmpeg(_ sample: ComparisonSample) throws -> [DecodedTrack] {
        let ffmpeg = try FFmpeg((sample.idx ?? sample.input).path)
        return ffmpeg.subtitleTracks.sorted { $0.key < $1.key }.map {
            DecodedTrack(number: $0.key, language: nil, subtitles: $0.value)
        }
    }
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Resumes a continuation once, whichever of the work and the time limit finishes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, any Error>) {
        lock.withLock {
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

/// The result of `work`, or `TimedOut` if it takes longer than `seconds`.
///
/// Decoding is synchronous and cannot be cancelled, so work that runs over is abandoned rather than
/// stopped; it keeps running in the background until the test process exits.
private func withTimeLimit<T: Sendable>(_ seconds: Double,
                                        _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        let worker = Task {
            do {
                try await once.resume(with: .success(work()))
            } catch {
                once.resume(with: .failure(error))
            }
        }
        Task {
            guard await (try? Task.sleep(for: .seconds(seconds))) != nil else { return }
            once.resume(with: .failure(TimedOut(seconds: seconds)))
            worker.cancel()
        }
    }
}

// MARK: - Results

/// One input measured with both decoders.
struct SampleResult {
    let sample: ComparisonSample
    let internalRun: RunOutcome
    let ffmpegRun: RunOutcome

    /// The tracks of the two decoders paired in order: their track numbers differ, FFmpeg numbering
    /// the streams of a file and the internal decoder using the MKV track number or VobSub stream index.
    var pairedTracks: [(internal: TrackOutput, ffmpeg: TrackOutput)] {
        guard case let .ran(internalRun) = internalRun, case let .ran(ffmpegRun) = ffmpegRun else { return [] }
        return Array(zip(internalRun.tracks, ffmpegRun.tracks))
    }

    /// Every way the internal decoder did worse than FFmpeg on this input.
    var comparisonFailures: [String] {
        guard case let .ran(ffmpegRun) = ffmpegRun else { return [] }
        guard case let .ran(internalRun) = internalRun else {
            return ["\(sample.name): FFmpeg decoded it but the internal decoder \(internalRun.status)"]
        }
        var failures: [String] = []
        if internalRun.tracks.count < ffmpegRun.tracks.count {
            failures.append("\(sample.name): internal decoded \(internalRun.tracks.count) tracks, " +
                "FFmpeg \(ffmpegRun.tracks.count)")
        }
        for (internalTrack, ffmpegTrack) in pairedTracks {
            let label = "\(sample.name) track \(internalTrack.number)"
            let shortfall = ffmpegTrack.cues.count - internalTrack.cues.count
            let allowed = DecoderComparison.allowedCueShortfall(ffmpegCues: ffmpegTrack.cues.count)
            if shortfall > allowed {
                failures.append("\(label): internal produced \(internalTrack.cues.count) cues, " +
                    "FFmpeg \(ffmpegTrack.cues.count)")
            }
            if let reference = sample.referenceCues {
                failures += DecoderComparison.failures(internal: CueScore(internalTrack.cues, against: reference),
                                                       ffmpeg: CueScore(ffmpegTrack.cues, against: reference),
                                                       label: label)
            }
        }
        return failures
    }
}

// MARK: - Report

enum ComparisonReport {
    static func markdown(for results: [SampleResult]) -> String {
        var lines = ["## Decoder comparison", ""]

        lines += [
            "### Against the reference SRT",
            "",
            "Exact: cues whose text equals the reference's. Errors are max / mean in ms over matched cues.",
            "",
            "| Input | Track | Decoder | Cues | Matched / ref | Exact | Similarity % | Start err | End err |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"
        ]
        for result in results {
            guard let reference = result.sample.referenceCues else { continue }
            for (decoder, outcome) in [(Decoder.internal, result.internalRun), (.ffmpeg, result.ffmpegRun)] {
                guard case let .ran(run) = outcome else {
                    lines.append("| \(result.sample.name) | | \(decoder.rawValue) | \(outcome.status) | | | | | |")
                    continue
                }
                for track in run.tracks {
                    let score = CueScore(track.cues, against: reference)
                    lines.append("| \(result.sample.name) | \(track.number) | \(decoder.rawValue) | \(score.cues) | " +
                        "\(score.matched) / \(score.referenceCues) | \(score.exact) | " +
                        "\(format(score.meanSimilarity)) | \(errors(score.maxStartErrorMs, score.meanStartErrorMs)) | " +
                        "\(errors(score.maxEndErrorMs, score.meanEndErrorMs)) |")
                }
            }
        }

        lines += [
            "",
            "### Internal against FFmpeg",
            "",
            "Tracks paired in order. Same text: paired cues read identically. Differences are max / mean in ms.",
            "",
            "| Input | Track (int / FFmpeg) | Cues int | Cues FFmpeg | Δ | Paired | Same text | Similarity % | " +
                "Start Δ | End Δ |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        ]
        for result in results {
            let paired = result.pairedTracks
            if paired.isEmpty {
                lines.append("| \(result.sample.name) | internal: \(result.internalRun.status); " +
                    "FFmpeg: \(result.ffmpegRun.status) | | | | | | | | |")
            }
            for (internalTrack, ffmpegTrack) in paired {
                let score = CueScore(internalTrack.cues, against: ffmpegTrack.cues)
                lines.append("| \(result.sample.name) | \(internalTrack.number) / \(ffmpegTrack.number) | " +
                    "\(score.cues) | \(score.referenceCues) | \(score.cues - score.referenceCues) | \(score.matched) | " +
                    "\(score.exact) | \(format(score.meanSimilarity)) | " +
                    "\(errors(score.maxStartErrorMs, score.meanStartErrorMs)) | " +
                    "\(errors(score.maxEndErrorMs, score.meanEndErrorMs)) |")
            }
        }

        lines += [
            "",
            "### Wall time (reported, not asserted)",
            "",
            "| Input | Decoder | Status | Decode / parse s | OCR s | Total s |",
            "| --- | --- | --- | ---: | ---: | ---: |"
        ]
        for result in results {
            for (decoder, outcome) in [(Decoder.internal, result.internalRun), (.ffmpeg, result.ffmpegRun)] {
                if case let .ran(run) = outcome {
                    lines.append("| \(result.sample.name) | \(decoder.rawValue) | ok | \(format(run.decodeSeconds, 3)) | " +
                        "\(format(run.ocrSeconds, 2)) | \(format(run.decodeSeconds + run.ocrSeconds, 2)) |")
                } else {
                    lines.append("| \(result.sample.name) | \(decoder.rawValue) | \(outcome.status) | | | |")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func errors(_ max: Int, _ mean: Double) -> String {
        "\(max) / \(format(mean))"
    }

    private static func format(_ value: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}
#endif
