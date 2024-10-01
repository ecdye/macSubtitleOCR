# macSubtitleOCR
[![License](https://img.shields.io/github/license/ecdye/macSubtitleOCR)](https://github.com/ecdye/macSubtitleOCR/blob/main/LICENSE.md)
[![CodeQL](https://github.com/ecdye/macSubtitleOCR/actions/workflows/codeql.yml/badge.svg)](https://github.com/ecdye/macSubtitleOCR/actions/workflows/codeql.yml)
[![Build](https://github.com/ecdye/macSubtitleOCR/actions/workflows/build.yml/badge.svg)](https://github.com/ecdye/macSubtitleOCR/actions/workflows/build.yml)
[![Lint](https://github.com/ecdye/macSubtitleOCR/actions/workflows/lint.yml/badge.svg)](https://github.com/ecdye/macSubtitleOCR/actions/workflows/lint.yml)

## Overview

macSubtitleOCR is a tool that converts bitmap subtitles to SubRip subtitles using OCR.
Currently the only supported bitmap format is PGS.
These bitmap subtitles can be read in from `.mkv` or `.sup` files.
We use the built in macOS OCR engine to perform the text recognition, which works really well.
For more information on accuracy, see [Accuracy](#accuracy) below.


### Options

- Ability to export `.png` images of the subtitles to allow manual refinement of the OCR output
- Ability to use language recognition (i.e. seeing if a sequence of characters actually makes a valid word) in the macOS OCR engine to improve OCR accuracy
- Ability to export raw JSON output from OCR engine for inspection

### Building

> [!IMPORTANT]
> This project requires Swift 6 to work properly!

To get started with macSubtitleOCR, clone the repository and then build the project with Swift.

``` shell
git clone https://github.com/ecdye/macSubtitleOCR
cd macSubtitleOCR
swift build
```

The completed build should be available in the `.build/debug` directory.

### Testing

Tests compare the output to a know good output.
We target a match of at least 95% as different machines will produce slightly different output.

``` shell
swift test
```

### Accuracy

In simple tests against the Tesseract OCR engine the accuracy of the macOS OCR engine has been significantly better.
This improvement is especially noticeable with words like 'I', especially when italicized.
The binary image compare method used in projects like [SubtitleEdit](https://github.com/SubtitleEdit/subtitleedit) may be slightly more accurate, but it depends on the use case.

## TODO / Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidance on how to contribute to the project.
To help with a specific project on the TODO list please view issues tagged as [enhancements](https://github.com/ecdye/macSubtitleOCR/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement).

## Reference

<https://blog.thescorpius.com/index.php/2017/07/15/presentation-graphic-stream-sup-files-bluray-subtitle-format/>
<https://www.matroska.org/technical/elements.html>
