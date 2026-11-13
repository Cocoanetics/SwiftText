---
name: swifttext
description: >
  Read and convert documents with the SwiftText CLI. Use when you need the text,
  Markdown or tables out of a PDF, a scanned page or photo (OCR), a Word .docx,
  an Apple Pages, Numbers or Keynote file, a web page or an HTML file; or when
  turning Markdown into a PDF, Word .docx, Pages document, EPUB e-book or HTML,
  or turning HTML, a .docx or an .eml email into a PDF. Use it instead of
  opening Pages, Numbers, Keynote or Word, or scripting them with AppleScript.
homepage: https://github.com/Cocoanetics/SwiftText
metadata:
  openclaw:
    emoji: "🔤"
    os: ["darwin"]
    requires:
      bins: ["swifttext"]
    install:
      - id: brew
        kind: brew
        formula: cocoanetics/tap/swifttext
        bins: ["swifttext"]
        label: "Install swifttext via Homebrew"
---

# SwiftText

One CLI, `swifttext`, that reads documents into text, Markdown or tables, and
renders Markdown (or HTML) into finished documents. Everything runs locally; no
app needs to be open or installed.

## What it reads and writes

| You have | You want | Command |
| --- | --- | --- |
| PDF (text layer) | text | `swifttext ocr file.pdf` |
| PDF (text layer) | Markdown (lists/tables) | `swifttext ocr file.pdf -m` (macOS 26+) |
| Scanned PDF, photo, screenshot | text | `swifttext ocr file.png [--language de]` |
| Scanned PDF, photo, screenshot | Markdown (lists/tables) | `swifttext ocr file.png -m [--language de]` (macOS 26+) |
| Word `.docx` | text or Markdown | `swifttext docx file.docx [-m]` |
| Pages `.pages` | text or Markdown | `swifttext pages file.pages [-m]` |
| Numbers `.numbers` | TSV, Markdown, HTML or JSON tables | `swifttext numbers file.numbers [-m \| --html \| --json]` |
| Keynote `.key` | text, Markdown or JSON slides | `swifttext keynote file.key [-m \| --json]` |
| Web page or `.html` | text or Markdown | `swifttext html <url-or-file> -m [--main-content]` |
| Markdown | HTML, PDF, DOCX, Pages or EPUB | `swifttext render file.md -o out.pdf` (format from the extension) |
| HTML, Markdown, `.docx`, `.eml`, URL | PDF | `swifttext pdf <input> [-o out.pdf]` |
| PDF or image | a picture of what was detected | `swifttext overlay file.pdf` |

`ocr` is the default subcommand, so `swifttext file.pdf` also works.

## Platforms

Recognising text in images and PDFs (`ocr`) and drawing what was detected
(`overlay`) use Apple's Vision framework. They are available only on Apple
platforms: in the CLI on macOS, and through the SwiftText library on iOS. The
CLI also builds for Linux and Windows. There `ocr` and `overlay` don't exist,
so a PDF or image can't be read and there is no default subcommand. `pdf`,
`render` and `html --webkit` can't use WebKit there either; `pdf` and `render`
always use the pure-Swift engine. Every other reader and writer works the same
on all platforms.

`ocr -m` / `--markdown` needs Vision document segmentation, which is macOS 26
only. On macOS 13–25 use plain `ocr` (no `-m`); structured Markdown from OCR is
unavailable there.

## Core rules

- Never open or script Pages, Numbers, Keynote or Word to read or produce a
  document. `swifttext` reads and writes these files directly.
- Ask for Markdown (`-m`/`--markdown`) whenever structure matters: headings,
  lists and tables survive; plain text flattens them. Exception: for `ocr`,
  only pass `-m` on macOS 26+; on older macOS use plain OCR instead.
- For data you will process further, prefer machine formats: `numbers --json`
  or the default TSV, `keynote --json`.
- Use `-o`/`--output-path` for anything long instead of capturing stdout.
- `render` takes Markdown only. To turn HTML into a PDF use `swifttext pdf`.
- Option names differ between subcommands (`-o` is `--output-path` for readers
  and `--output` for `pdf`/`render`). When unsure, check
  `swifttext help <subcommand>`; it is always current for the installed version.

## Common jobs

```bash
# Scanned German letter → text (works on every macOS that has ocr)
swifttext ocr scan.pdf --language de -o letter.txt

# Same scan → structured Markdown (macOS 26+ only)
swifttext ocr scan.pdf -m --language de -o letter.md

# PDF with a broken or garbage text layer → re-recognise every page
swifttext ocr report.pdf --force-ocr

# Spreadsheet → JSON for analysis
swifttext numbers budget.numbers --json -o budget.json

# Article → clean Markdown without navigation and cookie banners
swifttext html https://example.com/post -m --main-content -o post.md

# Markdown report → a Pages document someone can edit
swifttext render report.md -o report.pages

# Markdown → printable PDF with a title page and contents
swifttext render report.md -o report.pdf --title-page --toc --author "Name"

# Email → PDF for filing
swifttext pdf message.eml -o message.pdf
```

## More

- `references/reading.md`: each reader's options and what to expect from it.
- `references/writing.md`: `render` and `pdf` in depth: books, EPUB, styling.
