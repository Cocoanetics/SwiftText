# Writing documents

Two commands produce documents:

- `swifttext render` turns **Markdown** into HTML, PDF, DOCX, Pages or EPUB.
- `swifttext pdf` turns **HTML, Markdown, a .docx, an .eml email or a URL** into a PDF.

`swifttext help render` and `swifttext help pdf` list every option of the
installed version.

## `render`: Markdown → HTML, PDF, DOCX, Pages, EPUB

```bash
swifttext render input.md -o output.<html|pdf|docx|pages|epub>
cat input.md | swifttext render --stdin -o output.pdf
```

The format comes from the `-o` extension, or from `--format`. Without `-o` the
output is the input's name with `.html`. HTML input isn't accepted; use `pdf`.

### Documents and reports

- `--title`, `--author` (repeatable) set the metadata; the title defaults to the
  first top-level heading.
- `--title-page` (HTML, PDF) starts with a title page from `--title`,
  `--subtitle` and `--author`. `--toc` adds a contents page, or puts it at a
  `<!-- toc -->` line.
- `--paper a4|letter` and `--landscape` set the page.
- `--page-break-before h2` starts every `##` section on a new page (PDF, HTML, Pages).
- `--smart` turns straight quotes, `--`, `---` and `...` into typographic
  punctuation; `--language de` picks German quotes („…“).
- `--footnotes section|end|page` places footnotes per block, at the end, or at
  the foot of each PDF page.
- `--link-citations` makes `[n]` references clickable to the list item that
  starts with `[n]`.
- `--css style.css` appends custom CSS (HTML, PDF, EPUB). DOCX and Pages take
  only its alert-box colours.

### Books

- `--running-heads` puts the title and current chapter in the PDF header;
  `--mirrored-heads` gives classic left/right book furniture.
- `--chapter-level h1` (default) decides which heading starts a chapter;
  `--chapter-start right` starts each chapter on a right-hand page.
- `--number-from-chapter` leaves the title page, imprint and contents unnumbered
  and starts page 1 at the first chapter.
- EPUB: `--cover cover.jpg` (at least 1400 px wide for Apple Books),
  `--chapter-level` splits chapters into files, `--toc-depth` nests headings
  under each chapter in the table of contents.

### Pages output

`-o report.pages` writes a single-file Pages document that opens and edits in
Pages. `--package` writes a directory bundle instead. Reading it back
with `swifttext pages report.pages -m` gives the Markdown again.

### PDF engines

`--engine webkit` (macOS only, and the default there) supports full CSS.
`--engine swift` needs no WebKit and is the only engine on Linux and Windows;
with it, `--font file.ttf` replaces the default fonts.

## `pdf`: HTML, Markdown, DOCX, email or URL → PDF

```bash
swifttext pdf page.html -o page.pdf
swifttext pdf https://example.com -o example.pdf
swifttext pdf message.eml               # writes message.pdf
cat page.html | swifttext pdf --stdin -o page.pdf
```

`--paper`, `--landscape` and `--engine` work as for `render`. For Markdown with
title pages, contents or book layout, use `render` instead.
