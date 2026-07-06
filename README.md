# SwiftText

A collection of text utilities that has its origin in getting text out of various sources for the use of LLM agents.

## Overview

SwiftText provides Swift libraries and command-line tools for extracting text from various document formats. The extracted text is optimized for use with Large Language Models (LLMs) and AI agents.

## Modules

### SwiftTextHTML

Extracts text or Markdown from HTML using:
- **HTMLParser** (libxml2-backed)

Features:
- Plain text extraction
- Markdown conversion (links, lists, tables, code)

### SwiftTextOCR

Extracts text from images using:
- **Vision OCR** - Text recognition for bitmap content

Features:
- Preserves logical line structure and reading order
- Maintains vertical spacing between paragraphs
- High-resolution OCR (300 DPI) for accurate text recognition
- Optional Markdown output using Vision document segmentation (iOS 26+, macOS 26+)

### SwiftTextPDF

Extracts text from PDFs using a combination of:
- **PDFKit text selection** - For PDFs with embedded text layers
- **Vision OCR** - Automatic fallback for scanned documents or PDFs without selectable text

Features:
- Handles multi-page documents with page break markers
- Preserves logical line structure and reading order
- Maintains vertical spacing between paragraphs

### SwiftTextDOCX

Extracts text and basic structure from DOCX archives using:
- **ZIPFoundation** to read the Word archive
- **XMLParser** to parse document, styles, and numbering

Features:
- Plain text paragraph extraction
- Markdown output with headings, emphasis (bold/italic/strikethrough), lists, and
  footnotes

### SwiftTextEPUB

Builds a valid **EPUB 3** publication from a Markdown manuscript, cover image,
and metadata — the native equivalent of `pandoc -o book.epub` (output validates
under `epubcheck`). Splits chapters at a configurable heading level, generates
the OPF package, EPUB 3 nav + legacy NCX, a title page, and an aspect-fit cover
page, and packages them with `mimetype` stored first as the OCF spec requires.
See [Docs/EPUB.md](Docs/EPUB.md).

### SwiftTextPages

Extracts text and structure from Apple Pages (iWork) documents. The modern
`.pages` format stores content as iWork Archive (`.iwa`) objects, and this
module decodes them entirely on its own — **no Pages.app, no `textutil`, and no
Apple frameworks are required**, so it runs on every platform:

- **ZIPFoundation** to read the `.pages` archive (the only external dependency,
  already shared with SwiftTextDOCX)
- **Snappy** block decompression — implemented in-module
- **Protocol Buffers** wire decoding — implemented in-module

Features:
- Plain text paragraph extraction
- Markdown output with headings inferred from the document's typography (modern)
  or from paragraph-style names (legacy)
- Inline **bold**/*italic*/~~strikethrough~~ emphasis and bullet/numbered lists
  (with nesting)
- Footnotes as `[^N]` references with definitions collected at the end
- Reads modern `.iwa` documents in all three on-disk layouts: a flat Zip, a
  package directory with a loose `Index/`, and a package directory with a nested
  `Index.zip`
- Reads legacy iWork '09 documents (a single uncompressed `index.xml`)
- Extraction of the document's embedded **content** images from the `Data/`
  folder — downscaled previews (`…-small…`) and theme decorations (preset image
  fills, list-bullet glyphs) are filtered out by default, and files are written
  under cleaned names (pass `includingThumbnailsAndAssets: true` to get everything)
- **Inline image references** in Markdown: each inline image becomes a
  `![](name)` link at its position in the text, and the name matches the file
  `extractImages`/`--save-images` writes — so saving images alongside the
  Markdown yields working links. (Floating, non-inline images aren't linked but
  are still extracted.)

> Note: both the modern (iWork '13+) `.iwa` format and the legacy iWork '09
> `index.xml` format are supported. The rare gzipped legacy variant
> (`index.xml.gz`) is reported with a clear error rather than mis-parsed.

### SwiftTextAttributedString

Renders Markdown into a Foundation **`AttributedString`** that works on **every
platform** — macOS, iOS, Linux and Windows. Built on swift-markdown (the same
AST as the HTML/DOCX/Pages paths), it covers the full GFM superset the package
supports.

Foundation's `PresentationIntent` / `InlinePresentationIntent` live in Apple's
SDK Foundation and are *absent* from cross-platform swift-foundation, so the
renderer carries all block/inline structure in portable custom attributes that
compile and run everywhere, and **additionally** sets the native intents on
Apple platforms so the result interoperates with SwiftUI / TextKit:

| Information | Portable attribute (all platforms) | Native (Apple, additional) |
| --- | --- | --- |
| Block hierarchy | `SwiftTextMarkdownAttributes.Block` (`MarkdownBlock`) | `presentationIntent` |
| Inline traits | `SwiftTextMarkdownAttributes.InlineStyle` (`MarkdownInlineStyle`) | `inlinePresentationIntent` |
| Links | `.link` (Foundation, cross-platform) | — |

`MarkdownBlock` mirrors `PresentationIntent` exactly (a chain of components,
innermost first, each with a kind + a document-unique identity assigned by a
shared pre-order counter). Blocks are delimited by distinct identities, not
literal newlines — just as Foundation does.

Supported features:

- Headings (ATX + setext), emphasis, strong, strikethrough, inline code
- Links, autolinks, and images (alt text + source via `ImageSource`)
- Ordered / unordered / nested / task lists (with correct ordinals + start index)
- Fenced + indented code blocks (with language hint), tables with per-column
  alignment, blockquotes, thematic breaks, soft/hard breaks, inline + block HTML
- `[^id]` footnotes and GitHub `[!NOTE]` / DocC `Note:` alerts — which
  Foundation's intents can't express — via the custom scope
  (`FootnoteReference`, `FootnoteDefinition`, `Alert`)
- Smart-punctuation reversal by default (pass `.preserveSmartPunctuation` to keep
  cmark's curly quotes/dashes)

Requires macOS 12 / iOS 15 / tvOS 15 / watchOS 8 (where `AttributedString` is
available), or any Linux/Windows toolchain bundling swift-foundation.

```swift
import SwiftTextAttributedString

let attributed = MarkdownAttributedStringRenderer.convert("""
# Title

A paragraph with **bold**, a [link](https://example.com) and a footnote.[^1]

[^1]: The footnote body.
""")
// Or: AttributedString(swiftTextMarkdown: "…")

// Portable — works on every platform:
for run in attributed.runs {
    if run[SwiftTextMarkdownAttributes.InlineStyle.self]?.contains(.stronglyEmphasized) == true {
        print("bold:", String(attributed.characters[run.range]))
    }
    if let block = run[SwiftTextMarkdownAttributes.Block.self] {
        print("block:", block.components.map(\.kind))
    }
}

#if canImport(Darwin)
// On Apple, the native intents are set too (e.g. for SwiftUI Text):
let firstIsHeader = attributed.runs.first?.presentationIntent != nil
#endif
```

## Installation

Add SwiftText to your Swift package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/your-repo/SwiftText.git", branch: "main")
]
```

Then pick either specific products or the umbrella module.

Individual products (import only what you need):

```swift
	.target(
	name: "YourTarget",
	dependencies: [
		.product(name: "SwiftTextHTML", package: "SwiftText"),
		.product(name: "SwiftTextOCR", package: "SwiftText"),
		.product(name: "SwiftTextPDF", package: "SwiftText"),
		.product(name: "SwiftTextDOCX", package: "SwiftText"),
		.product(name: "SwiftTextPages", package: "SwiftText")
	]
)
```

Umbrella module (single import), with traits:

```swift
.package(
	url: "https://github.com/your-repo/SwiftText.git",
	branch: "main",
	traits: [.defaults, "HTML", "PDF", "DOCX", "PAGES"]
),
.target(
	name: "YourTarget",
	dependencies: [
		.product(name: "SwiftText", package: "SwiftText")
	]
)
```

SwiftText defaults to `OCR` plus `CLI` (the dependencies of the bundled `swifttext` tool; `CLI` also enables `DOCX`, `PAGES`, and `HTML`). Enable traits as needed:

```swift
traits: [.defaults, "HTML", "PDF", "DOCX", "PAGES"]
```

Listing traits explicitly (without `.defaults`) keeps dependency resolution lean: SwiftPM only fetches the packages the enabled traits actually need. For example, `traits: ["HTML"]` resolves just swift-markdown — neither swift-argument-parser nor ZIPFoundation is fetched or pinned.

## Usage

### Library Usage

#### HTML (SwiftTextHTML)

```swift
import SwiftTextHTML

let url = URL(string: "https://example.com")!
let (data, _) = try await URLSession.shared.data(from: url)
let document = try await HTMLDocument(data: data, baseURL: url)
let markdown = document.markdown()
```

#### PDF (SwiftTextPDF)

```swift
import PDFKit
import SwiftTextPDF

// Load a PDF document
let pdfURL = URL(fileURLWithPath: "/path/to/document.pdf")
guard let document = PDFDocument(url: pdfURL) else {
	fatalError("Could not load PDF")
}

// Extract all text as a single string
let text = document.extractText()
print(text)

// For more control, access TextLine objects directly
let textLines = document.textLines()
for textLine in textLines {
	print("Position: \(textLine.yPosition), Text: \(textLine.combinedText)")
}
```

#### PDF Markdown (SwiftTextOCR + SwiftTextPDF, iOS/macOS 26+)

```swift
import PDFKit
import SwiftTextOCR
import SwiftTextPDF

let pdfURL = URL(fileURLWithPath: "/path/to/document.pdf")
guard let document = PDFDocument(url: pdfURL) else {
	fatalError("Could not load PDF")
}

if #available(iOS 26.0, tvOS 26.0, macOS 26.0, *) {
	let allLines = document.textLines()
	var allBlocks: [DocumentBlock] = []

	for pageIndex in 0..<document.pageCount {
		guard let page = document.page(at: pageIndex) else { continue }
		let semantics = try await page.documentSemantics(dpi: 300)
		let layoutSize = page.bounds(for: .mediaBox).size
		let grouped = TextLineSemanticComposer.composeBlocks(
			from: page.textLines(),
			semantics: semantics,
			layoutSize: layoutSize
		)
		allBlocks.append(contentsOf: grouped)
	}

	let markdown = DocumentBlockMarkdownRenderer.markdown(
		from: allBlocks,
		textLines: allLines.map {
			let bounds = $0.fragments.reduce($0.fragments.first?.bounds ?? .zero) { $0.union($1.bounds) }
			return DocumentBlock.TextLine(text: $0.combinedText, bounds: bounds)
		}
	)
	print(markdown)
}
```

#### Images (SwiftTextOCR)

```swift
import SwiftTextOCR

let textLines = cgImage.textLines(imageSize: CGSize(width: cgImage.width, height: cgImage.height))
let text = textLines.string()
```

#### DOCX

```swift
import SwiftTextDOCX

let url = URL(fileURLWithPath: "/path/to/document.docx")
let docx = try DocxFile(url: url)

let plainText = docx.plainText()
let markdown = docx.markdown()
```

#### Pages

```swift
import SwiftTextPages

let url = URL(fileURLWithPath: "/path/to/document.pages")
let pages = try PagesFile(url: url)

let plainText = pages.plainText()
let markdown = pages.markdown()

// Optionally extract embedded images from the document's Data/ folder
let imageURLs = try pages.extractImages(to: URL(fileURLWithPath: "./images"))
```

### Command Line Tool

The `swifttext` CLI is **cross-platform** — it builds and runs on macOS, Linux, and
Windows. The document readers (`docx`, `pages`, `numbers`, `keynote`), HTML text/
Markdown extraction (`html`), and the Markdown/HTML renderers (`pdf`, `render`) are
available everywhere. Two subcommands are macOS-only because they depend on Apple
frameworks: `ocr` and `overlay` (Vision), plus the WebKit rendering engine.

Build and run the CLI:

```bash
swift build
swift run swifttext render notes.md -o notes.pdf   # works on macOS, Linux, Windows
```

On Linux/Windows the CLI needs libxml2 for the HTML/render paths (Linux:
`libxml2-dev` + `pkg-config`; Windows: `libxml2` via vcpkg).

Options:
- **ocr** *(macOS only)* `--markdown`/`-m` (Vision segmentation), `--save-images <dir>`, `--output-path <file>`/`-o`
- **html** `--markdown`/`-m`, `--save-images <dir>`, `--output-path <file>`/`-o`, `--webkit` *(macOS)*, `--via-pdf` *(macOS)*
- **docx** `--markdown`/`-m` (headings and lists), `--output-path <file>`/`-o`, `--save-images`
- **pages** `--markdown`/`-m` (inferred headings), `--output-path <file>`/`-o`, `--save-images`
- **numbers** `--markdown`/`-m`, `--html`, `--json`, `--output-path <file>`/`-o`
- **keynote** `--markdown`/`-m`, `--json`, `--output-path <file>`/`-o`
- **pdf** `--engine webkit|swift`, `--paper a4|letter`, `--landscape`, `--stdin`, `--output <file>`/`-o`
- **render** `--format html|pdf|docx|pages|epub`, `--engine webkit|swift`, `--paper`, `--landscape`, `--page-break-before <h1…h6>`, `--package`, `--output <file>`/`-o`; EPUB & shared: `--css <file>` (html/pdf/epub), `--cover <image>`, `--title`, `--author` (repeatable), `--language`, `--chapter-level <h1…h6>`
- **overlay** *(macOS only)* `--output-path <file>`/`-o`, `--dpi <value>`, `--raw`

The `pdf` and `render` commands render via **WebKit** by default on macOS and via
the pure-Swift **SwiftTextRender** engine everywhere else (`--engine swift` selects
it on macOS too; `--engine webkit` is rejected off macOS).

Examples:

```bash
# Extract formatted text from a PDF
swifttext ocr ~/Documents/report.pdf

# Using a relative path
swifttext ocr ../folder/file.pdf

# Save OCR output to a file
swifttext ocr --output-path ./output.txt ~/Documents/report.pdf

# Save images while producing Markdown from a PDF
swifttext ocr --markdown --save-images ./images ~/Documents/report.pdf

# Extract plain text from a Word document
swifttext docx ~/Documents/contract.docx

# Extract Markdown from a Word document
swifttext docx --markdown ~/Documents/contract.docx

# Extract Markdown from HTML (optionally load via WebKit)
swifttext html --markdown https://example.com
swifttext html --markdown --webkit https://example.com

# Save Word output to a file
swifttext docx --output-path ./contract.txt ~/Documents/contract.docx

# Extract embedded images to the output directory or current directory
swifttext docx --save-images ~/Documents/contract.docx

# Extract plain text from a Pages document
swifttext pages ~/Documents/notes.pages

# Extract Markdown (with inferred headings) from a Pages document
swifttext pages --markdown ~/Documents/notes.pages

# Markdown with inline image links, saving the referenced images alongside it
swifttext pages --markdown --save-images --output-path ./notes.md ~/Documents/notes.pages

# Extract tables from a Numbers spreadsheet / slide text from a Keynote deck
swifttext numbers --markdown ~/Documents/budget.numbers
swifttext keynote --markdown ~/Documents/deck.key

# Render Markdown to PDF with the cross-platform engine (works off macOS)
swifttext render notes.md -o notes.pdf --engine swift

# Build an EPUB 3 from a Markdown manuscript, with a cover and metadata
swifttext render book.md -o book.epub \
  --title "The Shattered Skies" --author "Elise Kummer" \
  --chapter-level h2 --cover cover.jpg

# Apply a custom stylesheet across HTML, PDF, and EPUB output
swifttext render book.md -o book.epub --css book.css

# Render an overlay PDF for inspection (macOS only)
swifttext overlay --dpi 300 ~/Documents/report.pdf
```

## Requirements

- Swift 5.9+
- Library platforms: macOS, iOS, tvOS, watchOS, Linux, Windows (per module; see each module's notes)
- `swifttext` CLI: macOS, Linux, and Windows

**Note:** 
- PDF text extraction (via PDFKit) works on any platform that supports PDFKit
- OCR fallback requires iOS 13.0+, tvOS 13.0+, or macOS 10.15+ (automatically enabled when available via availability checks)
- OCR Markdown segmentation requires iOS 26.0+, tvOS 26.0+, or macOS 26.0+
- The `ocr`/`overlay` CLI subcommands and the WebKit PDF engine are macOS-only; off macOS the `pdf`/`render` commands use the pure-Swift SwiftTextRender engine (needs libxml2 — `libxml2-dev` on Linux, vcpkg on Windows)

## License

MIT License
