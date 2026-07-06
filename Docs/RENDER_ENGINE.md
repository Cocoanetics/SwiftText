# Cross-platform HTML/CSS → PDF render engine

`SwiftTextRender` is a from-scratch, cross-platform rendering engine that turns
HTML + CSS into a PDF **without WebKit** — a Swift port of the core
[WeasyPrint](https://weasyprint.org) pipeline. It runs anywhere Swift +
Foundation run (macOS, iOS, Linux, Windows), so it covers the platforms where
the WebKit/`NSPrintOperation` path (`SwiftTextHTML.WebKitBrowser`) is
unavailable, and can be used everywhere as a dependency-light alternative.

## Why a port (and what is *not* ported)

WeasyPrint leans on native C libraries for everything hard: **Pango + HarfBuzz +
fontconfig** for text/fonts, and **pydyf** for PDF bytes. To stay
self-contained and cross-platform, the parts that had no in-house equivalent
were re-implemented in pure Swift; the parts SwiftText already had were reused:

| Concern            | WeasyPrint (Python)        | Here                                            |
|--------------------|----------------------------|-------------------------------------------------|
| HTML parsing       | tinyhtml5                  | **reused** `SwiftTextHTML` → XMLKit `HTMLParser` (libxml2) |
| PDF byte output    | pydyf                      | `SwiftTextPDFWriter` (pure-Swift port of pydyf) |
| Fonts / metrics    | Pango/HarfBuzz/fontconfig  | `SwiftTextOpenType` (pure-Swift sfnt reader)    |
| CSS parsing/cascade| tinycss2 / cssselect2      | `SwiftTextCSS` (tokenizer, parser, selectors, cascade) |
| Layout / draw      | `weasyprint/layout`,`/draw`| `SwiftTextRender` (box tree, layout, paint)     |

## Modules

All four are Foundation-only and always available (no package trait required):

- **`SwiftTextPDFWriter`** — low-level PDF object model + writer (dictionaries,
  arrays, streams, content-stream operators, classic xref).
- **`SwiftTextOpenType`** — TrueType/OpenType reader: `head`/`hhea`/`maxp`/
  `hmtx`/`cmap`/`OS₂`/`post`, glyph advances, Unicode→glyph mapping, and the raw
  bytes for embedding. Handles `.ttc` collections.
- **`SwiftTextCSS`** — CSS Syntax Level 3 tokenizer + parser, CSS Color 3,
  selector matching with specificity, and the cascade producing a typed
  `ComputedStyle` (UA stylesheet + author sheets + inline styles).
- **`SwiftTextRender`** — the engine: DOM adapter, box tree, block & inline
  layout, pagination, and painting to PDF.

## Pipeline

```
HTML string
  → SwiftTextHTML.DomBuilder (libxml2 via XMLKit)   → DOM
  → StyledElement.build (+ StyleResolver cascade)    → styled tree
  → BoxTreeBuilder.build                             → box tree
  → LayoutEngine.layout                              → geometry + line boxes
  → paginate                                         → page slices
  → Painter.paint (per page)                         → PDF content streams
  → FontResourceBuilder.finalize + PDF.write         → PDF bytes
```

## Usage

```swift
import SwiftTextRender

let html = "<h1>Hello</h1><p>Rendered with no WebKit.</p>"
let pdf = try await HTMLRenderer.renderPDF(html: html)        // Data
try pdf.write(to: URL(fileURLWithPath: "out.pdf"))
```

Page geometry (defaults to US Letter, paginated):

```swift
var options = RenderOptions()
options.pageWidthPx = 794        // A4 width  @96dpi (210mm)
options.pageHeightPx = 1123      // A4 height @96dpi (297mm); nil = one auto-height page
options.pageMarginPx = 48
let pdf = try await HTMLRenderer.renderPDF(html: html, css: ["body { font-family: serif }"], options: options)
```

Embedding arbitrary fonts (any family/script, not just the base-14 set):

```swift
let fonts = FontBook()
try fonts.register(data: try Data(contentsOf: fontURL), family: "Inter")
let pdf = try await HTMLRenderer.renderPDF(
    html: "<p style=\"font-family: Inter\">Any glyph the font has.</p>",
    fonts: fonts)
```

Registered fonts are embedded as `CIDFontType2` (Type0 / Identity-H) with a
`FontFile2` program, a width array for the glyphs used, and a `ToUnicode` CMap
so the text stays selectable and searchable. With no fonts registered, the
engine uses the PDF base-14 faces (Helvetica, Courier) with their standard
metrics — no embedding needed.

## Supported today

- Box model: margins (with adjacent-sibling collapsing), borders, padding,
  width/height; anonymous-block generation.
- Block stacking and inline layout with greedy line breaking, whitespace
  collapsing, and `white-space: pre`/`nowrap`.
- `text-align` left/right/center/**justify**; `<br>` and `<pre>` line breaks.
- Backgrounds, solid borders, color (`color`, named/#hex/rgb()/hsl()).
- Fonts: base-14 + embedded OpenType; bold/italic/family selection.
- `text-decoration` underline / line-through.
- Lists (`<ul>`/`<ol>` markers), clickable links (`<a href>` → PDF annotations).
- Pagination to a fixed page size; embedded `<style>` and caller CSS.
- `@page { size; margin }`, plus CSS Paged Media margin boxes: `@top-left/
  -center/-right` and `@bottom-left/-center/-right` for running headers/
  footers, with `content` as a literal string or `counter(page)`/
  `counter(pages)` (optionally styled, e.g. `counter(page, upper-roman)`), and
  the `:first`/`:left`/`:right` page selectors (e.g. to suppress a header on
  the title page via `@page :first { @top-center { content: normal } }`).

## Not yet (roadmap)

Images (`<img>`), tables, fl/grid, floats, positioned boxes, parent/child margin
collapsing, transforms, gradients, SVG, bidi/complex-script shaping, hyphenation,
bookmarks/outline. See the layout source for the simplifications called out in
comments.
