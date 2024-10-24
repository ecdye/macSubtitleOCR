# macSubtitleOCR

[![License](https://img.shields.io/github/license/ecdye/macSubtitleOCR)](https://github.com/ecdye/macSubtitleOCR/blob/main/LICENSE.md)
[![CodeQL](https://github.com/ecdye/macSubtitleOCR/actions/workflows/codeql.yml/badge.svg)](https://github.com/ecdye/macSubtitleOCR/actions/workflows/codeql.yml)
[![Build](https://github.com/ecdye/macSubtitleOCR/actions/workflows/build.yml/badge.svg)](https://github.com/ecdye/macSubtitleOCR/actions/workflows/build.yml)
[![Lint](https://github.com/ecdye/macSubtitleOCR/actions/workflows/lint.yml/badge.svg)](https://github.com/ecdye/macSubtitleOCR/actions/workflows/lint.yml)

## Overview

**macSubtitleOCR** is a tool written entirely in Swift that converts bitmap subtitles into the SubRip subtitle format (SRT) using Optical Character Recognition (OCR).
We currently support both PGS and VobSub bitmap subtitles.
The macOS Vision framework is used to perform OCR and typically offers highly accurate text recognition.

For more details on performance, refer to the [Accuracy](#accuracy) section below.

### Features

- Optional FFmpeg decoder for any issues with internal decoder
- Export raw JSON output from the OCR engine for further analysis.
- Export `.png` images of subtitles for manual correction of OCR output.

#### Supported Formats

- PGS (`.mkv`, `.sup`)
- VobSub (`.mkv`, `.sub`, `.idx`)

### Building the Project

> [!IMPORTANT]
> macSubtitleOCR requires Swift 6, FFmpeg, and an M series processor.

To build macSubtitleOCR, follow these steps:

``` shell
brew install ffmpeg
git clone https://github.com/ecdye/macSubtitleOCR
cd macSubtitleOCR
swift build --configuration release
```

The compiled build will be available in the `.build/release` directory.

### Running Tests

The testing process compares OCR output against known correct results.
We aim for at least 95% accuracy, because there are slight differences in OCR output between machines.

``` shell
swift test
```

### Accuracy

In our tests comparing macSubtitleOCR with the Tesseract OCR engine, the macOS Vision framework consistently gave better results, particularly with tricky cases like properly recognizing the letter 'I'.

While some tools, like [SubtitleEdit](https://github.com/SubtitleEdit/subtitleedit), may use binary image compare for better accuracy, Vision usually performs excellently and offers more flexibility with built-in language support.

## Contribution and TODO

For information on how to contribute to the project, please refer to [CONTRIBUTING.md](CONTRIBUTING.md).

If you're interested in working on specific features or improvements, check out issues tagged as [enhancements](https://github.com/ecdye/macSubtitleOCR/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement).

## References

- [Presentation Graphic Stream (PGS) Files](https://blog.thescorpius.com/index.php/2017/07/15/presentation-graphic-stream-sup-files-bluray-subtitle-format/)
- [DVD Subtitle Stream (VobSub) Files](http://www.mpucoder.com/DVD/index.html)
- [Matroska Technical Specifications](https://www.matroska.org/technical/elements.html)
