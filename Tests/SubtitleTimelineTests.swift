//
// SubtitleTimelineTests.swift
// macSubtitleOCR
//
// Created by Ethan Dye on 11/26/26.
// Copyright © 2024-2026 Ethan Dye. All rights reserved.
//

import Foundation
@testable import macSubtitleOCR
import Testing

// These cover the rules that turn decoded bitmap subtitle frames into cues, which issue #42 found
// broken for DVB subtitles: each line of a caption came out as its own cue, in reverse order, with
// end times before their start times.

/// A solid `width` x `height` rect drawn in one opaque color, on a two-entry palette.
private func solidRect(x: Int = 0, y: Int, width: Int = 4, height: Int = 2,
                       color: [UInt8] = [255, 255, 255, 255]) -> DecodedSubtitleFrame.Rect {
    DecodedSubtitleFrame.Rect(x: x, y: y, width: width, height: height,
                              indices: Data(repeating: 1, count: width * height),
                              palette: [0, 0, 0, 0] + color)
}

/// `AVSubtitle` start and end display times are milliseconds whatever the stream's time base. DVB
/// subtitles carry a page timeout of 10000 ms, which scaled by a 1/90000 MPEG-TS time base came out
/// as 0.111 s.
@Test func displayTimesAreMilliseconds() throws {
    let frame = DecodedSubtitleFrame(presentationTime: 2, startDisplayTime: 500, endDisplayTime: 10000,
                                     rects: [solidRect(y: 0)])
    let subtitle = try #require(SubtitleTimeline.subtitles(from: [frame]).first)
    #expect(subtitle.startTimestamp == 2.5)
    #expect(subtitle.endTimestamp == 12)
}

/// DVB takes a caption down by sending a page with no regions, well before the page timeout runs out.
@Test func emptyFrameEndsTheCaptionBeforeIt() {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 2.0, endDisplayTime: 10000, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 5.0, endDisplayTime: 10000, rects: []),
        DecodedSubtitleFrame(presentationTime: 5.1, endDisplayTime: 10000, rects: [solidRect(y: 4)])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    #expect(subtitles.count == 2)
    #expect(subtitles.map(\.index) == [1, 2])
    #expect(subtitles[0].startTimestamp == 2.0)
    #expect(subtitles[0].endTimestamp == 5.0)
    #expect(subtitles[1].startTimestamp == 5.1)
    #expect(subtitles[1].endTimestamp == 15.1)
}

/// PGS frames stay until replaced (`UInt32.max`), so each ends when the next frame arrives, and the
/// last is left for the SRT writer to give a default length.
@Test func captionWithoutTimeoutEndsAtTheNextFrame() {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 1, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 3, rects: [solidRect(y: 8)]),
        DecodedSubtitleFrame(presentationTime: 4, rects: []),
        DecodedSubtitleFrame(presentationTime: 6, rects: [solidRect(y: 0)])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    #expect(subtitles.map(\.startTimestamp) == [1, 3, 6])
    #expect(subtitles.map(\.endTimestamp) == [3, 4, nil])
}

/// FFmpeg's DVD subtitle decoder reports a stop command with the largest delay, 0xFFFF units of
/// 1024/90000 s, as 745642 ms. VobSub uses it for a subpicture with no set end, so the end is left
/// for the SRT writer, as the internal decoder leaves it, unless an empty frame clears the screen.
@Test func dvdStopAtTheLargestDelayLeavesTheEndUnknown() {
    #expect(DecodedSubtitleFrame.unknownEnd == 745642)
    let frames = [
        DecodedSubtitleFrame(presentationTime: 1, endDisplayTime: 745642, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 30, endDisplayTime: 745642, rects: [solidRect(y: 8)]),
        DecodedSubtitleFrame(presentationTime: 32, rects: []),
        DecodedSubtitleFrame(presentationTime: 40, endDisplayTime: 745642, rects: [solidRect(y: 0)])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    #expect(subtitles.map(\.startTimestamp) == [1, 30, 40])
    #expect(subtitles.map(\.endTimestamp) == [nil, 32, nil])
}

/// A long timeout that is not the 0xFFFF sentinel is still a real end time, as is a DVB page timeout.
@Test func otherLongTimeoutsAreRealEndTimes() {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 1, endDisplayTime: 745631, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 1000, endDisplayTime: 255000, rects: [solidRect(y: 8)])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    let ends: [TimeInterval?] = [1 + 745.631, 1255]
    #expect(subtitles.map(\.endTimestamp) == ends)
}

/// A container duration, such as a Matroska BlockDuration, ends a frame whose stream end is unknown, as
/// the internal decoder uses BlockDuration for a subpicture with no end time. The next frame still cuts it
/// short, and a frame with a real end keeps it.
@Test func packetDurationEndsAFrameWithAnUnknownEnd() {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 1, endDisplayTime: 745642, packetDuration: 2000,
                             rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 5, endDisplayTime: 745642, packetDuration: 9000,
                             rects: [solidRect(y: 8)]),
        DecodedSubtitleFrame(presentationTime: 7, endDisplayTime: 2992, packetDuration: 2000,
                             rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 20, endDisplayTime: 745642, rects: [solidRect(y: 8)])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    let ends: [TimeInterval?] = [3, 7, 7 + 2.992, nil]
    #expect(subtitles.map(\.endTimestamp) == ends)
}

/// A frame that stays until replaced ends when the next frame arrives, whatever the container says, as the
/// internal PGS decoder ends it at the next display set.
@Test func packetDurationDoesNotEndAFrameThatStaysUntilReplaced() {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 1, packetDuration: 500, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 3, packetDuration: 4000, rects: [solidRect(y: 8)]),
        DecodedSubtitleFrame(presentationTime: 4, rects: []),
        DecodedSubtitleFrame(presentationTime: 6, packetDuration: 1500, rects: [solidRect(y: 0)])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    #expect(subtitles.map(\.endTimestamp) == [3, 4, nil])
}

/// A container duration that does not reach past the frame's start display time is not an end.
@Test func packetDurationBeforeTheStartIsIgnored() {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 1, startDisplayTime: 500, endDisplayTime: 745642,
                             packetDuration: 500, rects: [solidRect(y: 0)])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    #expect(subtitles.map(\.endTimestamp) == [nil])
}

/// No caption may end before it starts, whatever order the frames come in.
@Test func captionsNeverEndBeforeTheyStart() throws {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 9, endDisplayTime: 10000, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 2, endDisplayTime: 10000, rects: [solidRect(y: 0), solidRect(y: 4)]),
        DecodedSubtitleFrame(presentationTime: 2, endDisplayTime: 10000, rects: []),
        DecodedSubtitleFrame(presentationTime: 5, endDisplayTime: 1000, rects: [solidRect(y: 4)])
    ]
    for subtitle in SubtitleTimeline.subtitles(from: frames) {
        let start = try #require(subtitle.startTimestamp)
        let end = try #require(subtitle.endTimestamp)
        #expect(end >= start)
    }
}

/// Every region of a frame is one caption, laid out where it is displayed: the decoder listed the
/// bottom line first in #42, and that order must not reach the output.
@Test func regionsOfOneFrameAreOneCaptionInScreenOrder() throws {
    let top = solidRect(x: 10, y: 100, width: 6, height: 3, color: [255, 0, 0, 255])
    let bottom = solidRect(x: 12, y: 110, width: 4, height: 2, color: [0, 0, 255, 255])
    let frame = DecodedSubtitleFrame(presentationTime: 0, endDisplayTime: 10000, rects: [bottom, top])

    let subtitles = SubtitleTimeline.subtitles(from: [frame])
    #expect(subtitles.count == 1)
    let subtitle = try #require(subtitles.first)
    #expect(subtitle.imageXOffset == 10)
    #expect(subtitle.imageYOffset == 100)
    #expect(subtitle.imageWidth == 6)
    #expect(subtitle.imageHeight == 12)

    let pixels = try #require(subtitle.imageData)
    let palette = try #require(subtitle.imagePalette)
    func color(x: Int, y: Int) -> [UInt8] {
        let index = Int(pixels[(y - 100) * 6 + x - 10])
        return Array(palette[index * 4 ..< index * 4 + 4])
    }
    #expect(color(x: 10, y: 100) == [255, 0, 0, 255])
    #expect(color(x: 12, y: 110) == [0, 0, 255, 255])
    #expect(color(x: 10, y: 105)[3] == 0) // The gap between the lines stays transparent.
    #expect(color(x: 10, y: 110)[3] == 0) // So does the space beside the shorter line.
}

/// Broadcasters resend an unchanged page so receivers tuning in mid-caption can show it. That must not
/// become a second copy of the caption.
@Test func repeatedPageExtendsTheCaption() {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 1, endDisplayTime: 3000, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 2, endDisplayTime: 3000, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 3.5, rects: [])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    #expect(subtitles.count == 1)
    #expect(subtitles.first?.startTimestamp == 1)
    #expect(subtitles.first?.endTimestamp == 3.5)
}

/// The same page shown again after it timed out is a new caption, not a continuation.
@Test func pageShownAgainAfterItsTimeoutIsANewCaption() {
    let frames = [
        DecodedSubtitleFrame(presentationTime: 1, endDisplayTime: 1000, rects: [solidRect(y: 0)]),
        DecodedSubtitleFrame(presentationTime: 4, endDisplayTime: 1000, rects: [solidRect(y: 0)])
    ]
    let subtitles = SubtitleTimeline.subtitles(from: frames)
    #expect(subtitles.map(\.startTimestamp) == [1, 4])
    #expect(subtitles.map(\.endTimestamp) == [2, 5])
}

/// DVB regions may each bring up to 256 colors, and the merged image holds one byte per pixel.
@Test func regionsWithMoreThan256ColorsBetweenThemStillMakeAnImage() throws {
    func gradient(y: Int, shift: UInt8) -> DecodedSubtitleFrame.Rect {
        let palette = (0 ..< 256).flatMap { level -> [UInt8] in [UInt8(level), shift, 0, 255] }
        return DecodedSubtitleFrame.Rect(x: 0, y: y, width: 256, height: 1,
                                         indices: Data((0 ..< 256).map { UInt8($0) }), palette: palette)
    }
    let subtitle = SubtitleTimeline.composite([gradient(y: 0, shift: 0), gradient(y: 1, shift: 9)])
    let colors = try #require(subtitle.numberOfColors)
    #expect(colors <= 256)
    #expect(subtitle.imagePalette?.count == colors * 4)
    #expect(subtitle.imageData?.allSatisfy { Int($0) < colors } == true)
    #expect(subtitle.makeImageSource()?.createImage(false) != nil)
}

/// The order the regions are listed in decides nothing about the text: each caption is recognized
/// with its lines top to bottom, as in #42 where the decoder listed the bottom line first.
@Test func captionLinesAreRecognizedTopToBottom() async throws {
    let first = try renderedSubtitle("Love what they have done", index: 1, transparent: true)
    let second = try renderedSubtitle("with the place", index: 2, transparent: true)
    func rect(_ subtitle: Subtitle, y: Int) throws -> DecodedSubtitleFrame.Rect {
        try DecodedSubtitleFrame.Rect(x: 40, y: y,
                                      width: #require(subtitle.imageWidth), height: #require(subtitle.imageHeight),
                                      indices: #require(subtitle.imageData), palette: #require(subtitle.imagePalette))
    }
    let firstHeight = try #require(first.imageHeight)
    // Listed bottom line first, as the decoder listed them in #42.
    let frame = try DecodedSubtitleFrame(presentationTime: 2, endDisplayTime: 10000, rects: [
        rect(second, y: 400 + firstHeight + 20),
        rect(first, y: 400)
    ])

    let subtitles = SubtitleTimeline.subtitles(from: [frame])
    let processor = try SubtitleProcessor(for: subtitles, from: 0, withOptions: false, false, "en",
                                          nil, false, false, false, false, makeOutputDirectory(), 1)
    let recognized = try await processor.process().srt.map { $0.text ?? "" }
    #expect(recognized == ["Love what they have done\nwith the place"])
}
