# Known Issues — swift-markdown limitations

SwiftText builds on [swift-markdown](https://github.com/swiftlang/swift-markdown)
(currently **0.8.0**) for all Markdown work:

- **HTML → Markdown** — `DOMMarkupConverter` builds a `Document` and renders it
  with `MarkupFormatter`.
- **Markdown → HTML** — `SwiftMarkdownHTMLRenderer` (+ `MarkdownFootnoteRenderer`).
- **Markdown → DOCX** — `MarkdownDocxBuilder`.

A handful of upstream limitations affect output or forced workarounds. This file
tracks them with their upstream issues **and any open PRs** so they can be
revisited as swift-markdown evolves. States below are accurate as of
swift-markdown 0.8.0 (tagged 2026-05-07).

> Several of these have fixes already in flight as unmerged PRs (e.g. footnotes,
> the parse stack-overflow, mixed-list indentation). "Fix in flight" means a PR
> exists but is **not** in any release — don't assume a version bump picks it up.

## Affecting HTML → Markdown (`DOMMarkupConverter`)

### 1. Mixed-type nested lists are not indented
`MarkupFormatter.linePrefix` counts unordered and ordered ancestors with
*separate* per-type counters, so a list nested inside a list of a **different**
type (e.g. an `<ol>` inside a `<ul>`) renders flush-left. The AST nesting is
correct; only the rendered indentation is dropped. Same-type nesting (`ul>ul`,
`ol>ol`) indents correctly.
- **Fix in flight: PR [#216](https://github.com/swiftlang/swift-markdown/pull/216) — OPEN, unmerged.**
  Collapses the two per-type counters into one; ~4-line change to `linePrefix`.
  (See also PR [#204](https://github.com/swiftlang/swift-markdown/pull/204) — OPEN, "add indentationStyle to
  MarkupFormatter.Options" — broader formatter-indentation control.)
- **In SwiftText:** accepted; characterized by
  `HTMLListConversionTests.mixedTypeNestedListIsNotIndentedByFormatter`. Still an
  improvement on the previous renderer, which glued nested-list text onto the
  parent item with no break. Flip that test when #216 ships.

### 2. Ordered-list start index can't be reproduced
`MarkupFormatter.Options.OrderedListNumerals` is either `.allSame(n)` or
`.incrementing(start:)`; it can't defer to a per-list authored start, so
`<ol start="5">` can't render as `5.`/`6.`/… We emit `1.`/`2.`/…
- **Upstream: issue [#76](https://github.com/swiftlang/swift-markdown/issues/76) — OPEN.**
  There is a matching `// FIXME … (#76, rdar://99970544)` in the formatter source.
- **In SwiftText:** minor — the converter doesn't read `<ol start>` today anyway.

### 3. A linked image can't be built through the typed `Link` initializer
`Link` and `Image` typed initializers require `RecurringInlineMarkup` children,
which `Image` itself does **not** conform to. So a *valid* linked image
(`<a><img></a>` → `[![alt](src)](href)`) can't be expressed through `Link(...)`.
- **Upstream:** no dedicated issue — a deliberate type restriction (prevents
  nesting links in links) that also blocks the valid image-in-link case.
- **In SwiftText:** handled — `makeLink` uses `Markup.withUncheckedChildren` to
  attach arbitrary inline content.

## Affecting Markdown → HTML / DOCX (parse-based paths)

### 4. Footnotes (`[^id]`) are not parsed
swift-markdown does not currently enable cmark-gfm's footnote extension, so
`[^id]` references and `[^id]: …` definitions are plain text to the parser, and
there is no footnote node type in the AST.
- **Upstream issue: [#115](https://github.com/swiftlang/swift-markdown/issues/115) — CLOSED** (asked for support; no plan at the time).
- **Fix in flight (parsing + tree nodes):**
  - **PR [#228](https://github.com/swiftlang/swift-markdown/pull/228) — OPEN, mergeable** ("Add footnotes."): adds `FootnoteReference` (inline) and
    `FootnoteDefinition` (block) nodes plus parser support; self-contained (no
    swift-cmark dependency).
  - PR [#129](https://github.com/swiftlang/swift-markdown/pull/129) — OPEN (older, depends on a swift-cmark PR). Same node types.
  - PR [#23](https://github.com/swiftlang/swift-markdown/pull/23) — OPEN (general "allow custom cmark options and extensions"), a possible enabler.
- **⚠️ Neither footnote PR touches `MarkupFormatter`.** So even if #228 merges,
  `Document.format()` will **not emit** `[^id]` — round-tripping footnotes *out*
  to Markdown text would still need either formatter support upstream or a custom
  text-emitting layer here.
- **In SwiftText:**
  - **Markdown → HTML** — worked around by `MarkdownFootnoteRenderer` (line-scans
    definitions, rewrites references, appends a definitions block).
  - **HTML → Markdown** — restored by `DOMFootnoteIndex` + `DOMMarkupConverter`:
    references become `[^id]` and definitions are appended as `[^id]: …`. Detection
    is layered — a generator-attribute fast-path (GitHub/Pandoc/this project) plus
    an attribute-free structural fallback (numeric `#href` whose target links back,
    is the *n*-th list item, or echoes the marker). **Limitation:** multi-paragraph
    footnote bodies are flattened (the 4-space continuation indent isn't
    representable through the AST/formatter).
  - **DOCX** — still does *not* handle footnotes; `[^id]` survives as literal text
    in `MarkdownDocxBuilder`.
- **Implication:** if #228 lands, the *parse* paths (MD→HTML/DOCX) could adopt
  native footnote nodes and drop the line-scan hack; the *HTML→MD* path keeps its
  detection layer regardless, because #228 doesn't add formatter emission.

### 5. Smart punctuation is forced on when parsing
`Document(parsing:)` runs cmark with `CMARK_OPT_SMART`, turning quotes/dashes/
ellipses into typographic forms. We reverse this so output matches the literal
source.
- **Upstream:** not a bug, but `ParseOptions.disableSmartOpts` exists and would be
  cleaner than reversing after the fact.
- **In SwiftText:** handled by `reverseSmartPunctuation` in
  `SwiftMarkdownHTMLRenderer` and `reverseSmartPunct` in `MarkdownDocxBuilder`.
  Candidate cleanup: parse with `.disableSmartOpts` instead of post-reversing.

### 6. `Document(parsing:)` can stack-overflow (SIGSEGV) on pathological input
Deeply nested emphasis-delimiter runs can crash the parser. Affects any path that
parses untrusted Markdown (Markdown→HTML, Markdown→DOCX). The HTML→Markdown path
does **not** parse, so it is unaffected.
- **Upstream issue: [#275](https://github.com/swiftlang/swift-markdown/issues/275) — OPEN** (filed 2026-06-08).
- **Fix in flight: PR [#276](https://github.com/swiftlang/swift-markdown/pull/276) — OPEN, mergeable** ("Fixes #275";
  replaces recursive cmark conversion with an iterative `cmark_iter` traversal).
- **In SwiftText:** latent crash risk on malicious input; no mitigation today.
  Resolved upstream once #276 ships.

## Not currently triggered / already fixed upstream

### 7. Extra newlines when wrapping inline code (line-limit only)
`MarkupFormatter` inserts spurious newlines around inline code when a
`preferredLineLimit` is set.
- **Upstream: issue [#197](https://github.com/swiftlang/swift-markdown/issues/197) — OPEN**;
  candidate fix PR [#215](https://github.com/swiftlang/swift-markdown/pull/215) — OPEN.
- **In SwiftText: not triggered** — `DOMMarkupConverter` leaves `preferredLineLimit`
  unset (no line wrapping), and the other paths don't set it either.

### 8. Table formatting index-out-of-bounds crash — FIXED in 0.8.0
Formatting a table whose rows had varying column counts could crash.
- **Upstream:** issue [#238](https://github.com/swiftlang/swift-markdown/issues/238),
  fixed by PRs [#250](https://github.com/swiftlang/swift-markdown/pull/250) /
  [#252](https://github.com/swiftlang/swift-markdown/pull/252) (merged 2025-11/12;
  included in the 0.8.0 tag).
- **In SwiftText:** resolved by the 0.8.0 bump. `DOMMarkupConverter` also pads
  cells to a uniform column count regardless.

### 9. Empty unaligned table column renders no delimiter dashes
A column that is entirely empty and has no alignment can format with an empty
delimiter cell (`||` with nothing between the pipes), which some parsers reject.
- **Fix in flight: PR [#271](https://github.com/swiftlang/swift-markdown/pull/271) — OPEN** ("Print at least one dash for empty
  unaligned table columns"; touches `MarkupFormatter`).
- **In SwiftText:** latent — `DOMMarkupConverter` pads short rows with empty
  `Table.Cell`s, so a trailing all-empty column is reachable from ragged HTML
  tables. Low impact (ragged data tables are usually classified as layout), but
  worth tracking.
