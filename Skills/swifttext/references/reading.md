# Reading documents

Every reader writes to stdout unless you pass `-o <path>` (`--output-path`).
`swifttext help <subcommand>` lists the exact options of the installed version.

## PDFs and images: `ocr`

```bash
swifttext ocr <file.pdf|file.png|file.jpg> [options]
```

`ocr` and `overlay` use Apple's Vision framework, so the CLI has them on macOS
only (the SwiftText library offers the same recognition on iOS). On Linux and
Windows neither subcommand exists.

- Without options you get plain text. `-m`/`--markdown` uses Vision document
  segmentation and emits Markdown with lists, tables and image placeholders —
  macOS 26 only. On macOS 13–25 omit `-m` and use plain OCR; structured
  Markdown from OCR fails on those systems.
- `-l`/`--lines`: one recognised line per output line, unformatted.
- A PDF's embedded text layer is used when it has one; pages without text are
  rasterised and recognised. `--force-ocr` ignores the text layer for every page
  (use it when the layer is missing words, in the wrong order or garbage).
- `--dpi` sets the rasterisation resolution for recognised pages (default 300).
  Raise it for small print; lower it for speed on large clean scans.
- `--language de` (repeatable, or `de,en`) is a recognition hint. Give it for
  anything that isn't English, especially for umlauts and accents.
- `--save-images <dir>` writes detected photos and charts as PNG files —
  macOS 26 only (same Vision document segmentation as `-m`). On macOS 13–25
  omit it; plain OCR still works without saving images.

To see why a page came out in the wrong order or a table was missed, render what
Vision detected (`overlay` is macOS 26 only; on older macOS it fails the same
way as `ocr -m`):

```bash
swifttext overlay page.pdf          # writes page-overlay.pdf (macOS 26+)
swifttext overlay page.pdf --raw    # raw Vision blocks instead of reconstructed ones
```

## Word: `docx`

```bash
swifttext docx file.docx [-m] [--save-images]
```

`-m` keeps headings and lists. `--save-images` extracts embedded images next to
the output (or into the current directory).

## Apple iWork: `pages`, `numbers`, `keynote`

These read the files directly; Pages, Numbers and Keynote don't need to be
installed.

```bash
swifttext pages document.pages [-m] [--save-images]
swifttext numbers sheet.numbers [-m | --html | --json]
swifttext keynote deck.key [-m | --json]
```

- `pages -m` infers headings from the document's styles.
- `numbers` writes every table of every sheet. The default is TSV; `-m` gives
  GitHub-flavoured Markdown tables, `--html` HTML tables, and `--json` sheets of
  tables, best for further processing.
- `keynote -m` writes one heading per slide with the body as bullets; `--json`
  gives title, body and presenter notes per slide.

## Web pages and HTML: `html`

```bash
swifttext html <url-or-file> [-m] [--main-content]
```

- `-m` gives Markdown; `--save-images <dir>` downloads the images it references.
- `--main-content` keeps the article and drops navigation, cookie banners,
  sidebars and footers. Use it for articles and blog posts.
- `--webkit` (macOS only) loads the page in WebKit first, for pages that build
  their content with JavaScript. `--webkit --via-pdf` parses WebKit's PDF export instead.
- `--charset windows-1252` (or `iso-8859-1`, …) fixes garbled characters on old
  pages with wrong encoding declarations. Not available with `--webkit`.
