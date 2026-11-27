# Test Files

The `sintel.*` files are taken from the Blender Open Movie Sintel.

They are licensed under the [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/) license.
Copyright © Blender Foundation | www.sintel.org

## ocr-samples.json

Twelve subtitle frames, each stored as its palette and its per-pixel palette indices, paired with the
text it should recognize as. `recognizesAntiAliasedFrames` feeds them through `SubtitleProcessor` and
compares the text alone, which is what makes it sensitive to changes in how images are prepared for
OCR. Six frames use a VobSub palette and six a PGS one, because the two are very different: VobSub has
four colors with a coarse alpha per color, PGS a full 256 color palette with 8 bit alpha.

Each frame is a row of unrelated words in random order, assembled from individual word bitmaps that
were segmented out of many different subtitles and recombined. Nothing in a frame is a phrase anyone
wrote: the vocabulary is ordinary lowercase words, plus a few common upper case ones, filtered so that
no name, speaker label or line of dialogue survives into the fixture.

Two frames cover glyphs that OCR is known to get wrong. One wraps its words in square brackets, which
recognition turns into a letter when strokes thicken, and two place a standalone I among lowercase
words, which is otherwise read as a slash. Both read correctly today. Note that VobSub glyphs touch
their neighbours, leaving no gap to cut on, so its parentheses cannot be separated from the caption
they belong to and only the PGS brackets appear here.

Real glyphs are used rather than freshly rendered ones because rendered text does not reproduce the
failures this guards against. Text drawn with Core Text has generous enough counters that flattening the anti-aliasing
leaves it readable, and a fixture built that way failed on at most two frames of eight instead of six
of six. The same is true of the Sintel files, where flattening changes one frame in twenty six.

## decoder-baseline.json

`decoderComparison` runs the internal and the FFmpeg decoder over `sintel.sup`, `sintel.sub` and
`sintel.mks`, OCRs every track as the CLI would, and scores each track's SRT against `sintel.srt`:
the number of cues, how many reference cues were matched to one, how many of those read exactly
(whitespace aside), and the start and end time error of matched cues, max and mean. A reference cue is
matched to the output cue it overlaps most, or failing that the one starting nearest it within a
second. The decode or parse time and the OCR time are reported separately but never asserted, since
CI runners vary too much. The tables are printed and, in GitHub Actions, added to the job summary. The
test only exists in the FFmpeg build (`USE_FFMPEG=1`):

```sh
USE_FFMPEG=1 xcrun swift build --build-tests
xcrun swift test --skip-build --filter decoderComparison
```

It fails when the internal decoder does worse than FFmpeg on any track (fewer matched or exact cues,
or a larger max or mean timing error), or falls below this file, which records the internal decoder's
scores keyed by input and track number. Against the baseline the cue count must be the same, matched
cues no fewer, timing errors no more than 1 ms larger, and exact cues at most one fewer: Vision reads
the same image slightly differently from one macOS release to the next, so a runner can lose a cue's
exact reading without anything in the decoder having changed. The reference holds authored times, which
the decoded ones miss by up to a frame, so timing errors never reach zero. `sintel.sub` gives each
subpicture the largest stop delay, meaning it stays until replaced, which both decoders currently turn
into a cue lasting until the next one and a last cue that runs for over twelve minutes. Its large end
time errors are recorded as they are until #135 fixes that and regenerates this file.

After a change that improves the scores, or one whose change is understood, regenerate the file and
commit it with the change:

```sh
MACSUBTITLEOCR_UPDATE_BASELINE=1 xcrun swift test --skip-build --filter decoderComparison
```

### Local samples

Files that cannot be committed can be measured as well by pointing `MACSUBTITLEOCR_SAMPLES_DIR` at a
directory. It is searched recursively for `.sup`, `.idx` (with the `.sub` beside it), `.mkv` and
`.mks` inputs; other files are ignored, and a copy of an input already found, by size and first
mebibyte, is measured once. Beside an input `<name>.<ext>`:

- `<name>.srt`, if present, is the reference both decoders are scored against, for every track.
- `<name>.options`, if present, holds further command line options separated by whitespace, such as
  `-l ar` for a track in Arabic.

Local samples are not in the baseline. Each is decoded and OCR'd by both decoders and reported: per
track the cue counts, how the internal decoder's cues pair with FFmpeg's, how many of the pairs read the
same, their text similarity and their timing differences, plus the wall time and whether either decoder
threw, timed out or found no bitmap subtitle tracks. The test fails when FFmpeg reads an input the
internal decoder cannot, decodes more tracks, or produces more cues for a track than the internal
decoder by more than one or 1%, whichever is more (a cue OCR reads nothing from is dropped from the SRT,
and the two decoders' images of it need not be equally readable). With a reference it also fails on the
same comparisons as the bundled inputs. Each decoder gets `MACSUBTITLEOCR_SAMPLE_TIMEOUT` seconds per
input, 900 by default; one that runs over is reported and abandoned. A decoder that traps takes the
test process down with it, and the log names the input it was measuring.

```sh
MACSUBTITLEOCR_SAMPLES_DIR=~/subtitle-samples xcrun swift test --skip-build --filter decoderComparison
```
