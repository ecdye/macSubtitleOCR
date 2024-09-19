# macSubtitleOCR
[![License](https://img.shields.io/github/license/ecdye/macSubtitleOCR)](https://github.com/ecdye/macSubtitleOCR/blob/main/LICENSE.md)
[![CodeQL](https://github.com/ecdye/macSubtitleOCR/actions/workflows/codeql.yml/badge.svg)](https://github.com/ecdye/macSubtitleOCR/actions/workflows/codeql.yml)


## Overview

macSubtitleOCR is used to covert a file containing a PGS Subtitle stream to SubRip subtitles using OCR.
Currently the supported input file types are `.mkv` and `.sup`.
It uses the built in OCR engine in macOS to perform the text recognition, which works really well.
For more information on accuracy, see [Accuracy](#accuracy) below.


### Options

- Ability to export images in the `.sup` file to compare and manually refine OCR output
- Ability to export raw JSON output from OCR engine for inspection
- Ability to use language recognition in the macOS OCR engine to improve OCR accuracy


### Building

> [!IMPORTANT]
> This project requires at least Xcode 16 to work properly due to breaking changes, made by Apple, to the Xcode project format.

To get started with macSubtitleOCR, clone the repository and then build the project with Swift.

``` shell
git clone https://github.com/ecdye/macSubtitleOCR
cd macSubtitleOCR
swift build
```

The completed build should be available in the `.build/debug` directory.

### Accuracy

In simple tests against the Tesseract OCR engine the accuracy of the macOS OCR engine has been significantly better.
This improvement is especially noticable with words like 'I', especially when italicized.
The binary image compare method used in projects like [SubtitleEdit](https://github.com/SubtitleEdit/subtitleedit) may be slightly more accurate, but it depends on the use case.

## TODO (not necessarily in order)

- Implement complete testing and formal linting / style guidelines
- Implement an option to not output the `.sup` file when parsing from `.mkv` files (ie. perform the operation completely in memory)
- Add additional test cases
- Implement the ability to read `.sub` VobSub files and VobSub streams from `.mkv` files

## Reference

<https://blog.thescorpius.com/index.php/2017/07/15/presentation-graphic-stream-sup-files-bluray-subtitle-format/>
<https://www.matroska.org/technical/elements.html>
