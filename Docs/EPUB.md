# Markdown → EPUB export

`SwiftTextEPUB` turns a Markdown manuscript (plus a cover image and metadata)
into a valid **EPUB 3** publication — the native equivalent of reaching for
`pandoc -o book.epub`. Output validates cleanly under
[`epubcheck`](https://www.w3.org/publishing/epubcheck/) (EPUB 3.3 rules).

It follows the same shape as `SwiftTextDOCX`/`SwiftTextPages`: walk the
swift-markdown AST, build the format's files, and zip them into the container.

## CLI

```bash
swifttext render manuscript.md -o book.epub \
  --title "The Shattered Skies" \
  --author "Elise Kummer" \
  --language en \
  --chapter-level h2 \
  --cover cover.jpg \
  --css house-style.css
```

- **`--chapter-level h1…h6`** — a new chapter file begins at every heading of
  this level (default `h1`). Content before the first such heading becomes a
  front-matter section (kept out of the table of contents). A chapter's TOC
  label is its run of leading consecutive headings joined with `": "`, so a
  `## 1` immediately followed by `### The Birthday…` reads as
  *“1: The Birthday…”* in the navigation while both headings still show in the
  chapter body.
- **`--cover <image>`** — JPEG/PNG/GIF/WebP/SVG. Embedded as the OPF
  `cover-image`, wrapped in an aspect-fit SVG so it fills the screen. Apple
  Books wants a cover at least 1400px wide.
- **`--title` / `--author` (repeatable) / `--language`** — Dublin Core
  metadata. The title defaults to the document's first heading, then the input
  filename.
- **`--css <file>`** — a shared stylesheet flag that also applies to `html` and
  `pdf` output. For EPUB it is appended after the bundled reading stylesheet
  (so author rules win) and referenced from every content document — e.g. to
  swap the default scene-break rule for custom artwork.

## Library

```swift
import SwiftTextEPUB

let metadata = EpubMetadata(
    title: "The Shattered Skies",
    authors: ["Elise Kummer"],
    language: "en",
    coverImage: try? Data(contentsOf: coverURL),
    coverImageFilename: "cover.jpg")

try MarkdownToEpub.convert(
    markdown, to: outputURL, metadata: metadata,
    options: EpubOptions(chapterLevel: 2, userCSS: nil))
```

`EpubMetadata`'s `identifier` (a `urn:uuid:` by default) and `modified`
timestamp default to a fresh UUID and the current time; pass explicit values
for a reproducible, byte-identical build.

## What it emits

A standard OCF ZIP container:

```
mimetype                     (first entry, stored — as the spec requires)
META-INF/container.xml
OEBPS/content.opf            (OPF 3.0: Dublin Core metadata, manifest, spine)
OEBPS/nav.xhtml              (EPUB 3 nav: toc + landmarks)
OEBPS/toc.ncx                (EPUB 2 NCX, for older reading systems)
OEBPS/styles/stylesheet.css  (bundled reading style + any --css appended)
OEBPS/images/cover.<ext>     (when a cover is given)
OEBPS/text/cover.xhtml       (aspect-fit SVG cover page)
OEBPS/text/titlepage.xhtml   (generated from the metadata)
OEBPS/text/chNNN.xhtml       (one XHTML content document per chapter)
```

Chapter bodies are rendered through the Markdown renderer's XHTML mode
(`SwiftMarkdownHTMLRenderer` with `.xhtml`), so void elements are self-closed
and the documents parse as well-formed XML rather than lenient HTML5.

## Not yet

Nested (multi-level) tables of contents, per-chapter footnote sections,
embedding of inline body images referenced by relative path, and custom
`@font-face` embedding. The first pass targets long-form prose (novels,
manuscripts), which is what the container, chaptering, cover, and metadata
above cover.
