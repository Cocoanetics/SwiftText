# DOCX writing: alert boxes, rules, quotes and code blocks

`MarkdownToDocx` writes GitHub/Obsidian/DocC alerts (`> [!NOTE]`, `> [!WARNING] Watch out`,
any `[!KIND]`, `> Note:`) as **boxes of ordinary paragraphs**: a tinted fill with the kind's
coloured left border, laid out like the CSS box of the HTML/PDF output. Detection
(`MarkdownAlertBlock`), colours (`MarkdownAlertPalette`) and geometry (`MarkdownAlertLayout`,
in CSS `em`) are shared with every other writer, so the boxes look alike in all formats.
A stylesheet can recolour them: `MarkdownAlertColors(css:)` reads its `.markdown-alert` and
`.markdown-alert-KIND` rules (fill, left border, text colour), and `swifttext render --css` applies
them to DOCX and Pages as it does to HTML, PDF and EPUB.
`DocxFile.markdown()` (and `swifttext docx --markdown`) reads them back as `> [!KIND] Title`.

## Why paragraph borders, not text boxes or tables

| Option | Breaks across pages | Plain, editable, extractable text | Reads back |
|---|---|---|---|
| **Paragraph borders + shading** (used) | yes; Word closes and reopens the box at the break | yes | by style |
| DrawingML text box | no | no: a floating object that screen readers and extractors skip or double | poorly |
| Single-cell table | Word yes, Pages never (rows don't split) | as a table (the accessibility checker flags it) | by table style |

Microsoft's own help recommends paragraph borders over text boxes and one-cell tables for
setting text off.

## Styles

Each kind used in the document gets a pair of paragraph styles:

| Style id | Name | Carries |
|---|---|---|
| `SwiftTextCallout-<kind>` | Callout Note | the frame (`w:pBdr`), fill (`w:shd`), indents, text colour, `keepLines` |
| `SwiftTextCalloutTitle-<kind>` | Callout Note Title | `basedOn` the body style: bold, `keepNext` |

The title inherits the frame, so title and body draw as one box. The reader recognises the
styles by id, or by name when another app rewrote the ids (LibreOffice builds ids from the
names). A rule is an empty paragraph in **Horizontal Rule** (`SwiftTextRule`): a bottom border
under an exact 1pt line. It reads back as `---`.

## How Word draws bordered paragraphs

- Consecutive paragraphs with **identical borders and identical left/right indents** form one
  box (ECMA-376 §17.3.1.24). The space between them is inside the box and shaded. First-line
  and hanging indents don't count.
- A border's `w:space` is the **padding** between text and border, in whole points (at most
  31), and the shading fills it. Word pads only towards a side that has a border, so the top,
  bottom and right sides get ½pt borders in the fill colour.
- **Side borders sit outside the indents.** Indent = padding + border width puts the box's
  outer edge on the text column.
- The first paragraph's space before and the last one's space after are **outside** the
  box: they are its margins.
- Word **adds** one paragraph's space after to the next one's space before; CSS collapses
  adjacent margins to the larger.

## Spacing (`DocxBoxLayout`)

All values are the CSS `em` values times the body font size (`DocxWriter.bodyFontSize`, 11pt),
in twips:

- **Margin** 0.8em above and below, net of the neighbour's own spacing. A title after a Normal
  paragraph (6pt after) gets 0.8em − 6pt before. The last paragraph before a heading gets
  0.8em − the heading's space before, but at least 0. A box or rule next to another box or
  rule takes its full margin, and the other one takes none.
- The line after a box or rule gets CSS's **half-leading** (0.3em) as extra margin, because
  Word puts a line's extra leading below the text and CSS splits it above and below.
- **Padding** 0.75em above and below (the top and bottom borders' `w:space`), 1em at the sides.
- **Between paragraphs** 0.6em, and 0.2em between list items.
- `keepNext` on every paragraph but the last (CSS `break-inside: avoid`).

Two boxes in a row would join into one, even of different kinds when their palettes match.
An unbordered 1pt **spacer paragraph** therefore parts them; the reader skips it.

## Inside a box

- **Lists:** a list item's indent would split the box, so every paragraph of a box that holds
  a list shares one wider indent (left `w:space` 1em + the 18pt bullet hang) and the bullets
  hang in the padding. Nested items keep their `w:ilvl` (and glyph) but share that indent.
- **Headings** become bold lines, **quotes** italic ones, and **code blocks** one monospace
  paragraph with `w:br` line breaks (a code table would split the box). They read back as
  emphasis and plain lines. The Pages writer does the same.
- **Tables, images and rules** can't sit inside a paragraph box. They split it: the box
  closes before them and continues after them, without a title.

## Block quotes and code blocks

Quoted paragraphs use the **Block Quote** style (`SwiftTextBlockQuote`: a grey left bar at
one level's indent). Deeper levels add 360 twips of direct indent each, and the reader turns
the indent back into `> > `. It also takes Word's own **Quote** and **Intense Quote** styles
as quotes. Two quotes in a row would join under one bar, so the same unstyled spacer that
parts two boxes parts them, and the reader takes it as the boundary.

Code blocks stay single-cell tables of **Code Block** paragraphs. The reader turns each cell
back into one fenced block. It keeps the empty paragraphs (blank lines) and the
indentation, and uses a longer fence when the code holds backticks.

## Not verified in Word

Without Word, this layout follows the specification and Word's documented behaviour. It was
checked only for well-formed XML and by reading the files back. Points to confirm in Word:
the shading between the grouped paragraphs (expected continuous), and where Word puts the
leading of `auto` line spacing (it decides how much of the half-leading compensation is
right).
