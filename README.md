<div align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="120" alt="FastRead icon">
  <h1>FastRead</h1>
  <p><strong>A PDF reader for iPad that reads aloud, highlights word by word, and takes handwritten notes.</strong></p>
</div>

Tap a paragraph and it starts reading, highlighting each word in sync with the voice. If the audio doesn't exist yet it's synthesized on the spot; if it does, it loads from cache. Write on the page with Apple Pencil while you read.

Everything runs **on device, offline**. No server, no API key, nothing leaves the iPad.

Built for reading scientific papers — two-column layouts, journal headers, hyphenation across columns — which is where most of the hard problems turned out to be.

---

## Features

| | |
|---|---|
| **Read aloud** | Tap any paragraph. Synthesis runs at ~24× real time on an M1 iPad, so it starts almost immediately |
| **Word-level highlighting** | The highlight follows the voice, word by word, on the PDF itself |
| **Resume anywhere** | Tap mid-paragraph to start from there — the audio is already cached, so it just seeks |
| **Prefetch** | The next passages are generated while you listen; you never wait between paragraphs |
| **Language detection** | Per document, with a per-passage override when the evidence is strong |
| **Voice picker** | Lists installed voices with their quality, and tells you how to download better ones |
| **Handwritten notes** | Apple Pencil, pressure-sensitive, vector from capture to screen |
| **Procreate-style gestures** | Two fingers to undo, three to redo, while you write |

## What made this hard

Most of the work went into problems that only show up in real documents. Each one is covered by a test.

**PDFKit collapses blank lines.** A `\n\n` in the source arrives as a single `\n`. Splitting paragraphs on blank lines makes the entire document one passage. Paragraph boundaries come from geometry — vertical gaps, type size, column changes — not from punctuation alone.

**PDFKit has two index systems and doesn't say so.** `page.string` counts line breaks; `characterBounds(at:)` and `characterIndex(at:)` don't. The drift grows through the page. Every lookup is verified against the expected text instead of trusting the arithmetic.

**`characterIndex(at:)` returns `NSNotFound`, not `-1`,** for any tap that misses a glyph — margins, line gaps, the space between columns. Since people aim at paragraphs and not at letters, almost every tap misses. Falling back to "first passage on the page" made every tap start reading the journal header.

**`AVSpeechSynthesisMarker.byteSampleOffset` is measured in bytes, despite the name.** Dividing by the sample rate alone inflates every timestamp by `bytesPerFrame` — a 5.42 s clip reported its last word at 18.3 s.

**The terminal buffer callback fires twice.** Without an idempotency guard every passage lands in the cache twice.

**Some PDFs don't encode math as math.** Typeset with certain Type1 fonts, the text PDFKit returns has `¼` where the `=` should be, `þ` for `+`, and `ð…Þ` for the parentheses. Counted across the corpus, those characters appear only inside formulas — never in English prose — so they are treated as operators. Without that, an equation stayed in the passage and the voice recited it.

**PencilKit rasterizes at page resolution.** Ink drawn over a PDF blurs when you zoom — a [known limitation](https://developer.apple.com/forums/thread/792941) with no published fix. The notes layer draws its own vector ink instead, so strokes stay sharp at any zoom by construction.

## Numbers

Measured on this project, not estimated:

| | |
|---|---|
| Speech synthesis | ~39× real time (M2), ~24× (M1 iPad Air 5) |
| Cost of prefetching the next passage | ~4% of the current passage's duration |
| Audio at 24 kbps AAC | 17 MB/hour — versus 311 MB/hour raw PCM |
| An 8-hour book in cache | ~136 MB, versus ~2.5 GB uncompressed |
| Language detection | ~6 ms per passage |
| Passage highlight accuracy | 97% exact on real papers (4734/4874 passages) |

## Architecture

```
Sources/FastReadCore/      testable core, no UI
  LanguageDetector         document and per-passage language
  PageLayoutAnalyzer       visual blocks from page geometry
  TextSegmenter            PDF text → passages + index map back to the page
  DocumentSegmenter        whole document → located passages
  PageTextLocator          text indices ↔ page geometry, self-correcting
  SpeechSynthesisEngine    synthesis + word markers → AAC
  AlignmentBuilder         markers → per-word timings
  SegmentCache             .m4a + .json on disk, LRU prune
  SegmentPipeline          cache, request coalescing, cancellable prefetch
  MathFilter               display equations out of the spoken text
  Ink / InkPath            stroke model and outline geometry
  AnnotationStore          notes on disk, keyed by file content

App/Sources/               iPad app (SwiftUI + PDFKit + CoreAnimation)
Tests/FastReadCoreTests/   273 tests
App/UITests/               18 UI tests
```

The core is a Swift package so the tests run in seconds without a simulator. The app depends on it.

**Ink is vector end to end.** Touches are captured with coalesced and predicted samples, carrying pressure, altitude, azimuth and roll. The geometry builds a closed *outline* of the stroke — variable width doesn't fit a fixed-width path — and it's filled by a `CAShapeLayer`, which is vector and hardware-accelerated.

## Running

```bash
swift test                 # 273 tests, ~6s
xcodegen generate          # generates FastRead.xcodeproj from project.yml
open FastRead.xcodeproj
```

The `.xcodeproj` isn't versioned — it's derived from `project.yml`.

To run the core tests against your own PDFs:

```bash
FASTREAD_SAMPLE_PDFS=/path/to/papers swift test
```

Those tests skip when the variable isn't set. They assert invariants that only real documents expose: no passage swallows the article's opening, no passage ends on a split word, no paragraph gets cut in the middle, no spoken passage contains a formula, tapping the body doesn't resolve to the header.

## Voice quality

iPadOS ships only `compact` voices, which sound robotic. The enhanced and premium ones are a free download and sound far better:

**Settings → Accessibility → Read & Speak → Voices**

The app picks the highest-quality installed voice on its own. It enumerates `speechVoices()` rather than calling `AVSpeechSynthesisVoice(language:)`, which sidesteps a [regression in iOS 26](https://developer.apple.com/forums/thread/804648) (FB20271264) where that API ignores the user's chosen voice.

## Requirements

- iPadOS 17+
- Xcode 26, Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

Built and tested on an iPad Air 5.

## Known limitations

- **Scanned PDFs don't work** — there's no selectable text to read. The app says so when it detects one.
- **Display equations are skipped, not read.** A formula is removed from the passage and the prose around it is joined back together, so the voice reads through the paragraph instead of reciting notation. Deciding what is a formula is a heuristic: it takes two or more consecutive mathematical tokens *and* a strong signal — an operator, a Greek letter, or a character from the Unicode math block — so a lone `R` or `m` in prose survives.
- **A formula in the middle of a sentence leaves a gap.** Removing it is the right call for a display equation on its own line, but `Here Δω = ω − ω₀ and ω₀ is the nominal frequency` becomes `Here and ω₀ is the nominal frequency`. Reciting the notation would be worse, so the gap stands.
- **Words split across pages** stay split; joining them would put text from two pages in one passage, and the highlight can only paint one.
- **Two- and three-finger gestures work on device but can't be tested automatically** — `twoFingerTap` can't compute coordinates over a `PDFView`. The toolbar buttons cover the same actions and are tested.

## License

MIT
