# Writing Pages (`.pages`) files — research & design notes

Reading `.pages` is merged; a from-scratch Snappy **compressor** already landed as
"groundwork for writing." This document is the research for the **write** path:
what a valid modern (iWork '13+) `.pages` document is made of, what we still need
to build, and the recommended strategy.

Findings here come from dissecting real documents in the corpus on `/Volumes/SSD`
(see the test-corpus memory note) with a throwaway IWA dumper, cross-checked
against the existing reader in this module.

---

## TL;DR

- **Recommend template-mutation, not synth-from-scratch.** In the smallest real
  modern document, **~492 of ~576 objects (~85%) are theme/stylesheet** — reproducing
  that graph by hand is a project in itself and gives no value to a text writer.
  The only mature open-source iWork *writer*, `numbers-parser`, does exactly this:
  it ships a real `empty.numbers` and mutates its object graph; `keynote-parser`
  similarly unpacks→edits→repacks. Two further reasons template-mutation wins:
  (a) the **Pages-specific `TP.*` type numbers are unpublished** — they live only
  in Pages.app's runtime registry (dumpable via `lldb`/`po [TSPRegistry sharedRegistry]`),
  so emitting a *new* `TP.DocumentArchive` cold means reverse-engineering them
  first; starting from a template means you never need them. (b) Pages is the same
  IWA machinery as Numbers with `TP.*` swapped for `TN.*`, so the proven approach ports.
- The compression/decoding primitives are mostly done. The genuinely new work is
  a **Protobuf encoder**, a **real IWA writer**, and — only if adding new `.iwa`
  files — rebuilding the **`PackageMetadata` component map**. Injecting text into
  the template's existing body storage needs *no* index changes at all.
- A bundled blank template is *data*, not a code dependency, so it stays within
  the project's self-sufficiency preference (no new SwiftPM products).

---

## Implemented: `MarkdownToPages` (Markdown → Pages writer)

Status as built (all validated opening + rendering in Pages 14.5; 214 tests green):

| Markdown feature | Pages rendering | Parity vs DOCX writer |
|---|---|---|
| Paragraphs | Body style, `space_after` 8pt | ✅ |
| Headings 1–6 | template Heading 1/2/3 styles (+ spacing) | ✅ |
| **Bold** / *italic* / ***both*** | built-in Emphasis/Italic char styles; synthesized bold+italic | ✅ |
| `inline code` / code blocks | synthesized monospace (Menlo) char style | ✅ |
| ~~strikethrough~~ | built-in Strikethrough char style | ✅ (DOCX drops it) |
| Lists (bullet/numbered, nested) | Bullet/Numbered list styles; nesting **level** encoded | ✅ functional (visual indent of nested levels is a list-style refinement) |
| Block quotes | indented + italic (a real style overwritten with a Body copy + indent) | ✅ |
| Horizontal rule | full-width box-drawing line | ◐ visual, not a native rule object |
| Images | italic placeholder text (alt or `[image]`) | ✅ (matches DOCX exactly) |
| Links | **clickable** hyperlink (TSWP type 2032 object + `#11` smart-field run table) + underline | ✅ |
| Tables | **native iWork (`TST`) grid** (header row styled, **per-column alignment** from `:--`/`:-:`/`--:`, **in-cell `**bold**`/`*italic*`/`~~strike~~`** that composes with alignment), any number per document; reads back as a Markdown table | ✅ |
| Inline HTML / HTML blocks | raw text / dropped | ✅ (matches DOCX) |

**How it works.** `MarkdownToPages.convert(_:to:)` parses with swift-markdown, walks
the AST (`MarkdownPagesBuilder`, mirroring `MarkdownDocxBuilder`) into
`BodyParagraph`s, then `PagesWriter` serializes them into the blank template's body
`StorageArchive` (text + paragraph/char/list run tables), synthesizes any needed
character/paragraph style objects, edits the stylesheet for paragraph spacing,
regenerates `Metadata/` UUIDs, and re-zips (STORED). No bundled file — the template
is committed Swift data (`Generated/BlankPagesTemplate.swift`, from
`Scripts/GeneratePagesTemplate.swift`).

**Native tables — IMPLEMENTED end-to-end, any number per document (2026-06-15).**
`MarkdownToPages` emits a native iWork (`TST`) grid for every Markdown table, and
`PagesParser` reads each back as a Markdown table (full round-trip). Production code:
`PagesTableBuilder` (regenerates the dimension objects per R×C; relocates each table's
object set by a fixed id offset for tables after the first),
`Generated/PagesTableTemplate.swift` (the captured 77-object table delta, via
`Scripts/GeneratePagesTableTemplate.swift`), `PagesWriter` (injection + `PackageMetadata`),
the body serializer's `#9` attachment run table, and `PagesParser.tableGrid(forAttachment:)`.

**Multi-table relocation.** Each additional table reuses the captured object set shifted
by `tableIndex * 4096` (kept < 2^21 so ids stay 3-byte varints → no payload-length
changes). `PagesTableBuilder` shifts the object id, the `MessageInfo.object_references`
(#5) / `FieldInfo` (#4), and every captured-id reference inside the payload (re-encoding a
sub-message only when it truly contains a reference, so strings/raw fields are preserved).
Its `Index/Tables/*` files get id-suffixed names. **`PackageMetadata` cross-references
(`#6`/`#7`) are gating** (verified: stripping them breaks even a single-table doc), so
`relocateComponentMetadata` clones each table-involving external reference at the matching
offset and registers each relocated `Tables/*` component. The recipe below documents the
format; it was proven first via throwaway scripts (`stageA.swift`, `stageB.swift`).

**Injection model (no id remapping for one table).** `Table.pages` = `Empty.pages` +
a table. Diffing object-id sets: the table is **77 delta objects, all ids 1732664–1734988,
strictly above Empty's max (1732661)** — so injecting them into the blank template needs
**zero re-id** for a single table (a 2nd table needs an id offset). The 77 deltas:
36 in `CalculationEngine` (incl. the model + calc scaffold), ~30 in `Index/Tables/*`,
1 in `Document.iwa` (the `2003` attachment), 1 in `DocumentStylesheet` (a cell para style
2022), 1 in `Metadata.iwa` (an `11015`), 8 in `ViewState`. **Stage A proven:** injecting
all 77 verbatim + swapping the body storage (`1732539`) + using `Table.pages`'s
`Metadata.iwa` wholesale → a 5×4 native grid renders in an otherwise-blank doc, no crash.

**Body anchor:** body `StorageArchive` `#3` text has a `U+FFFC` at the table position;
field **`#9` is the attachment run table** `{ #1 { #1 charIndex, #2 { #1 attachmentId } } }`.
Chain: `#9` → `2003` drawable-attachment (`#1` → `6000`) → `TableInfoArchive` 6000
(`#2` → `6001`) → `TableModelArchive` 6001 → tiles/datalists.

**THE dimension source = `base_column_row_uids` (`ColumnRowUIDMapArchive`,** sample id
**1733217, model field `#46`).** Count of **`#1` = number of columns**, count of
**`#4` = number of rows**. Each UID = `{ #1 uint64, #2 uint64 }`. `#2`/`#3` are column
orderings, `#5`/`#6` row orderings (identity `0..n-1` is fine). **Empirically (probe3):
editing only this object resizes the rendered grid; editing the model `#6`/`#7`, the tile,
the header buckets, or the table frame — individually OR together — does NOT.** Pages reads
cell *content* positionally from the tile but takes the grid *extent* from this UID map.
For >4 cols / >5 rows the captured UIDs run out → generate fresh unique uint64 pairs (cells
don't reference UIDs, so any unique values work).

**Full R×C resize recipe (6 objects; all proven, opens clean, Stage B):**
1. **`base_column_row_uids` (1733217)** — C col UIDs (`#1`) + R row UIDs (`#4`) + orderings
   `#2`/`#3`=`0..C-1`, `#5`/`#6`=`0..R-1`. ← the extent driver.
2. **`Tile` (6002, 1733209)** — top: `#1`maxColumn/`#2`maxRow/`#3`numCells = 0 (as Apple
   ships), **`#4` numrows = R**, **`#6` storage_version = 5 (constant!)**, `#7`
   last_saved_in_BNC = 1. One repeated **`#5` `TileRowInfo`** per row:
   `#1` row index, **`#2` cell_count = C**, `#3` cell_storage_buffer_pre_bnc (C × 12-byte
   col-meta `04 00 00 00`+8 zero), `#4` cell_offsets_pre_bnc (uint16 `0,12,…`+`0xFFFF`
   pad to **510 B**), **`#5` storage_version = 5 (constant!)**, `#6` cell_storage_buffer
   (the C cell records), `#7` cell_offsets (uint16 byte-offsets into `#6`, `0xFFFF` pad to
   510 B). **Gotcha:** `Tile.#6` and `TileRowInfo.#5` are *storage_version* fields (=5),
   NOT counts — setting them to R/C corrupts parsing.
   **String cell record:** header-row = 28 B `05 03 00 00 00 00 00 00 | 48 10 02 00 |
   <key u32 @ off 12> | 01 00 00 00 05 00 00 00 01 00 00 00`; body = 24 B with styleword
   `08 10 02 00` and tail `05 00 00 00 01 00 00 00`. All-text Markdown cells → use these.
3. **cell `DataList` (6005, 1733190 = `base_data_store.stringTable`)** — `#1` listid=1,
   `#2` count=maxKey+1, repeated `#3 { #1 key, #2 1, #3 string }`. Keys = `r*C+c+1`,
   row-major; the cell `u32@12` references the key.
4. **`TableModelArchive` (6001, 1733271)** — `#6` number_of_rows=R, `#7`
   number_of_columns=C. (Schema confirmed via numbers-parser `TSTArchives.proto`: `#18-21`
   are body/header/footer *styles* not per-column; `#60-80` are category/label styles.)
   `base_data_store` (`#4`, `TST.DataStore`): `#1` rowHeaders(HeaderStorage→row bucket),
   `#2` columnHeaders(→col bucket), `#3` tiles(`TileStorage`→tile, `#2`=tile_size 256),
   `#4` stringTable, `#9/#10` row/col `TableRBTree`, `#14` storage_version_pre_bnc=4
   (**don't touch — not a count**).
5. **header buckets (`HeaderStorageBucket` 6006)** — row bucket (1733229): **R** `Header`s
   `{ #1 idx, #2 f32 height(22.73), #3 0, #4 C }`; col bucket (1733266): **C** `Header`s
   `{ #1 idx, #2 f32 width(120.386), #3 0, #4 R }`.
6. **frame (`TableInfoArchive` 6000, 1733236)** — `#1` GeometryArchive `#2` size = `{ w =
   C×120.386, h = R×22.73 }` (else the grid is clipped/over-extended visually).

Most `Tables/` DataLists are **empty placeholders** (count=1, 0 entries) — clone verbatim.
For Markdown set `number_of_header_rows`=1, `number_of_header_columns`=0 (else col 0 renders
as a bold row-header). `PackageMetadata`: use the captured `Metadata.iwa` (component layout
matches after injection) or add a `ComponentInfo` per new `Tables/` file + bump `#1`.
- ~~Clickable hyperlinks~~ — **done**: each link emits a `TSWP` hyperlink object
  (type 2032: `#1`={smart-field UUID}, `#2`=URL) referenced from a `#11` smart-field
  run table over the link's character range (byte-pattern-identical to a Pages-authored link).
- ~~Block-quote left indent~~ — **done**: a *synthesized* style's `para_properties`
  don't apply, and referencing the special "Default" style (1731490) crashes Pages
  (`CFHash` on NULL in TSText). Solved by overwriting an unused *normal* style
  ("Subtitle", 1731497) with a copy of the known-safe Body style (unique identifier)
  plus a left indent — `first_line_indent`=7 is what visibly indents (left_indent=11
  alone did nothing), with italic char_properties. Indented + italic, opens cleanly.
- **Nested-list visual indent** — list levels are encoded and round-trip correctly,
  but nested items don't visually indent yet (list-style per-level indent).

---

## What we already have (write-relevant)

| Piece | Status | Where |
|---|---|---|
| Snappy **decompress** | ✅ | `Snappy.swift` |
| Snappy **compress** (LZ77, multi-window, tested incl. >64 KiB) | ✅ | `Snappy.swift` |
| Protobuf wire **decode** (schema-less) | ✅ | `Protobuf.swift` |
| IWA chunk + ArchiveInfo/MessageInfo **decode** | ✅ | `IWAArchive.swift` |
| Object store, ID resolution | ✅ | `IWAArchive.swift` |
| Zip read; package/dir/nested-zip layouts | ✅ | `PagesContainer.swift` |
| Test-only IWA *builder* (field encoders, all-literal Snappy, framing) | ⚠️ partial | `Tests/.../IWATestSupport.swift` |
| Protobuf **encode** | ❌ | — |
| Real IWA **writer** (uses `Snappy.compress`, multi-chunk) | ❌ | — |
| `PackageMetadata` rebuild | ❌ | — |
| Zip **write** + `Metadata/` generation | ❌ | (ZIPFoundation can write) |

`IWATestSupport.IWAWriter` already proves the framing math; it is the seed for a
real writer, but it emits a single all-literal Snappy block and lives in tests.

---

## Package anatomy (empirical)

A modern `.pages` is a Zip (or a package directory) with three top-level areas.

### `Metadata/`
- **`Properties.plist`** (binary plist) — keys observed:
  `documentUUID`, `fileFormatVersion` (e.g. `"12.2.8"`), `isMultiPage` (bool),
  `revision` (`"0::<uuid>"`), `shareUUID` (= documentUUID), `stableDocumentUUID`,
  `versionUUID`. All UUIDs are fresh per document.
- **`DocumentIdentifier`** — the `documentUUID` as a 36-byte ASCII string, nothing else.
- **`BuildVersionHistory.plist`** — array of strings; first entry records the
  origin template, e.g. `"Template: Blank (12.1)"`, then build stamps like
  `"M12.2-7035.0.159-2"`.

### `Index/*.iwa`
| File | Role |
|---|---|
| `Document.iwa` | Root `DocumentArchive` + sections + **body text storages** |
| `DocumentStylesheet.iwa` | The theme: styles, fills, list/bullet defs (the bulk) |
| `Metadata.iwa` | **`PackageMetadata`** — the object↔file component map (see below) |
| `DocumentMetadata.iwa` | Small doc-level metadata (digest, timestamp) |
| `ViewState.iwa`, `CalculationEngine-<id>.iwa`, `AnnotationAuthorStorage-<id>.iwa` | Auxiliary; some are near-empty |

### Other
- `preview.jpg`, `preview-micro.jpg`, `preview-web.jpg` — Finder/QuickLook
  thumbnails. Not required to open (carry the template's through; see Open questions).

---

## The IWA write stack (inverse of the reader)

To emit one `.iwa` file:

1. **Protobuf encode** each object payload: varint (tag = field<<3 | wire), then
   length-delimited / varint / fixed32 / fixed64 bodies. (We only ever need to
   encode; the test helper already has the field encoders.)
2. **Record framing** per object, concatenated into one stream:
   `varint(len(ArchiveInfo)) + ArchiveInfo + payload`, where
   `ArchiveInfo = {#1 identifier, #2 MessageInfo}` and
   `MessageInfo = {#1 type, #3 len(payload), #5 object_references, #6 data_references}`.
   `#5`/`#6` are **packed uint64** lists of the IDs this payload points at (objects
   and `Data/` media respectively). The *reader* ignores them (it resolves IDs
   globally), but a *writer* should populate `#5` so Apple's lazy loader can route
   references. (Repeated `#2` allows multiple payloads per identifier — one is fine.)
3. **Chunking** — match Apple's writer, which deviates from the Snappy spec:
   - Slice the **uncompressed** stream into **≤ 64 KiB (65536-byte) pieces**;
     `Snappy.compress` each piece into its own self-contained block.
   - Prefix each block with a 4-byte header: `0x00` + 3-byte little-endian length
     of *that compressed block* (header not counted). The 24-bit field also caps a
     block at ~16 MB, but the 64 KiB rule bites first.
   - **No Stream Identifier chunk and no CRC-32C** — Apple emits neither; we must
     not either. `Snappy.compress` today prefixes one varint length for the whole
     input, so the IWA writer must call it **per 64 KiB slice** (not once on the
     full stream) and emit one chunk header per slice.

This layer is pure, deterministic, and round-trip-testable against `IWAArchive`
with no Pages involvement.

---

## The component map — `PackageMetadata` (type 11006) — the hard part

`Index/Metadata.iwa` holds one `TSP.PackageMetadata`. Decoded shape:

```
#1  varint        next-object-ID high-water mark   <-- ID allocator state
#2  msg           revision { #2 revisionUUID, #3 0 }
#3  ComponentInfo (repeated, one per .iwa file):
      #1  varint   primary object id of the component
      #2  string   component name  ("Document", "ViewState", …)  = filename stem
      #3  string   explicit file locator, when the name has an id suffix
                   ("CalculationEngine-1686569")
      #6  msg      external object reference { #1 target-component-id, #2 target-object-id }  (repeated)
      #7  msg      same external-reference shape (repeated)
      #11 msg      per-object digest { #1 object-id, #2 128-bit hash }  (repeated)
      #12 varint   save token / generation
#4  DataInfo (repeated, one per Data/ media file):
      #1 data id · #2 20-byte file digest · #3 file name · #5 asset locator
#10 msg           { #1 -> object-reference tracker id }
```

**Why this matters for writing.** `#1` is the document's `last_object_identifier`.
`numbers-parser`'s pattern (worth copying): on load, seed an ID counter at the
highest existing ID **rounded up to the next million**, hand out fresh IDs from
there, and write the new max back into `#1` — so injected objects never collide
with the template's. New objects are appended into an existing component (e.g.
`Document.iwa`); you only touch the `ComponentInfo` list when adding a *whole new*
`.iwa` file. **Pure text injection into the template's existing body storage
requires no `PackageMetadata` change at all** — which is what makes the MVP cheap.

The `#6`/`#7` external-ref lists and `#11` digests only need maintenance when you
add/split components. Per the research sweep, `numbers-parser` does **not**
regenerate `#11` digests or previews on save — it round-trips the template's — and
Pages still opens the result, so digests are **not required to open** (they serve
collaboration/incremental-merge).

**Simplification worth testing:** if a (text-only) writer puts *all* objects in a
single component, there are **no** external references, so `#6`/`#7` collapse to
empty. The reader in this module already resolves IDs globally across files, which
is evidence Apple's does too — but whether Pages.app *accepts* a document that
omits the conventional `DocumentStylesheet.iwa` split is unverified (open question).

---

## Object graph & key type numbers (empirical)

Root object is **`id = 1`, `type = 10000` (`TP.DocumentArchive`)**; it references
the rest by ID:

```
DocumentArchive(1)  #2 -> stylesheet   #3 -> sectionList?   #4 -> body storage
                    #6 -> theme/section #7 -> settings       #20,#47 -> aux
                    #15 -> big settings msg (locale, calendar, template marker)
                    #30..#38 fixed32 = page geometry; #43 printer; #44 "iso-a4"
```

Cross-validation with prior art: per SheetJS, **Pages is the app whose
`DocumentArchive` requires field 15** (Keynote requires #2, Numbers #4/#5/#6) — and
field 15 is exactly the large settings sub-message observed above. So `#15` is the
"this is a Pages document" discriminator and must be present. The Pages-only
`TP.*` type integers (incl. `10000`) are not in any public schema; only the common
`TSP.*/TSWP.*/TSS.*` numbers below are documented (and they match what we read).

Body text = **`type 2001` (`TSWP.StorageArchive`)**: `#1` kind (0 = body),
`#2` style ref, **`#3` UTF-8 text** (paragraph breaks `U+2028`/`\n`), `#5`
paragraph-style run table, `#6` para-data, `#8` char-style run table — exactly
what `PagesParser` reads back.

| Type | Meaning | Type | Meaning |
|---|---|---|---|
| 10000 | DocumentArchive (root) | 401 | TSS StylesheetArchive |
| 10001 | section/theme archive | 2001 | TSWP StorageArchive (text) |
| 10010/10011/10012/10015/10016 | TP doc sub-objects | 2021–2026 | TSWP style/run tables |
| 10143 | (3×, body-related) | 6004 | char style (102×, theme) |
| 11006 | **PackageMetadata** | 11011 | DocumentMetadata |
| 11014 | color/number sidecar | 11015 | shared-object/data-id map |

Object counts in the smallest modern doc: `Document.iwa` 59, **`DocumentStylesheet.iwa`
492**, `Metadata.iwa` 6, others ≤7 — i.e. the theme dominates.

---

## Empty.pages dissection — the from-scratch baseline

A genuinely empty default document (File ▸ New ▸ Blank, saved with zero edits;
Pages 14.5, `fileFormatVersion` 26.1.0) — the blueprint for generating a document
in code with **nothing bundled**.

**Package** (outer zip is **STORED**): same 7 `Index/*.iwa`, 3 `Metadata/`, 3
`preview*.jpg` as any modern doc. **575 objects total** — and ~95% are the fixed
default theme:

| File | Objects | Role |
|---|---:|---|
| `DocumentStylesheet.iwa` | **491** | default theme — paragraph/char/list styles, fills (static) |
| `Document.iwa` | 58 | root + section + body + 18 empty header/footer storages |
| `ViewState.iwa` | 10 | editor view state (static) |
| `CalculationEngine-<id>.iwa` | 8 | formula engine scaffold (static) |
| `Metadata.iwa` | 6 | `PackageMetadata` component map |
| `DocumentMetadata.iwa` | 1 | doc digest + timestamp |
| `AnnotationAuthorStorage-<id>.iwa` | 1 | empty (0-byte payload) |

`Metadata/`:
- `Properties.plist` (bplist) — now also `hasExternalReferenceOrMissingData`,
  `hasUnmaterializedRemoteData` (both false); in a fresh doc
  `documentUUID == shareUUID == stableDocumentUUID`, and `revision = "0::"+versionUUID`.
- `DocumentIdentifier` = that documentUUID. `BuildVersionHistory.plist` =
  `["Template: Blank (dev/15.3)", "M15.2.1-7048.0.3-2"]`.

**Root `DocumentArchive` (id=1, type 10000):** `#2`→stylesheet `#3`→section-list
(type 10010, 0 B) `#4`→**body storage** `#6`→theme (type 10001, 3 KB) `#7`→settings
(type 10012); `#15` = the Pages-discriminator settings sub-message (locale
`en_AT@rg=atzzzz`, calendar, app version "5026.60").

**The empty body storage (id, type 2001, 97 B) has NO `#3` text field** — just
`#1` kind=0, `#2` style ref, and single-entry run tables (`#5` para-style→a style id,
`#6` para-data `{0,0,0}`, `#7` list-style, `#12`/`#17` more run tables, `#28`).
**Writing text = add `#3` = UTF-8 bytes** and extend the run tables (one entry per
style change; paragraph breaks are `U+2028`/`\n` in `#3`). The eighteen 65-byte
type-2001 objects are the empty header/footer storages (kept verbatim).

### Static vs. dynamic — the crux of "from scratch, no bundle"
Of 575 objects, only a handful change with content: the **body storage** (+ its run
tables and any new paragraph/char style objects it references), the **root's page
geometry**, and the **`Metadata/` UUIDs**. The other **~550 are byte-stable across
every Blank document** — the default theme, view state, calc-engine scaffold.

So a no-bundle writer must still *produce* those ~550 objects. Realistic options:
1. **Capture-as-data (recommended):** a dev-time tool (this dumper, extended) reads
   the empty doc once and emits a Swift source file holding each static object's
   `(id, type, payload-bytes)`. The writer re-emits those verbatim, builds the
   dynamic body, regenerates `Metadata/`, recompresses, and zips. No `.pages`
   resource ships — the theme lives as versioned Swift data (~90 KB). This is
   "generated in code," satisfying "don't bundle anything," and is robust.
2. **True-minimal synthesis:** hand-build only the objects Pages strictly requires
   and drop most of the 491-object theme. Smallest output, purest, but the true
   minimum is unknown — it's open-ended trial-and-error against Pages.app, and
   fragile across Pages versions. High risk/effort.

Option 1 is the pragmatic realization of the user's "from scratch" intent; option 2
is a research spike that could shrink it later.

---

## Strategy comparison

### A. Template-mutation  *(recommended)*
Bundle one tiny blank `.pages` as a target resource (as `numbers-parser` ships
`empty.numbers`). To write: load every `.iwa` into one ID→object table → edit the
body `StorageArchive`'s `#3` text + run tables (referencing the template's existing
styles by ID) → re-encode **only the changed `.iwa` files** → re-zip, **carrying
`Metadata/` and `preview*.jpg` through unchanged** (optionally rewrite
`DocumentIdentifier`/`Properties.plist` UUIDs for a fresh identity).
- **+** Inherits a known-valid theme/stylesheet/section graph and all metadata for free.
- **+** Matches how `numbers-parser`/`keynote-parser` actually write; no need to
  know any `TP.*` type number or rebuild `PackageMetadata` for text-only edits.
- **−** Ships a binary blob; output styling is the template's, not arbitrary.
- **Zip quirk:** iWork's zip is **STORED (no deflate), no Zip64**; the `.iwa`
  entries (and any nested `Index.zip`) must be stored, not compressed. ZIPFoundation
  supports `.none` compression — use it.
- Self-sufficiency: the blob is data, needs no new SwiftPM product.

### B. Synthesize from scratch
Hand-build a minimal `DocumentArchive` + one section + body storage + a minimal
stylesheet, ideally collapsed into a single component.
- **+** Purest; no bundled blob; full control.
- **−** Must discover Pages' true *minimum* required graph by trial against
  Pages.app; high risk it rejects an incomplete document. Largest effort.

---

## Recommended next steps (phased)

1. **Protobuf encoder** + promote `IWAWriter` to a real `IWAArchive` writer:
   `Snappy.compress` **per ≤64 KiB uncompressed slice**, one `0x00`+3-byte-LE chunk
   each, no stream-id/CRC; `MessageInfo` with `#5` object_references. Pure & unit-testable.
2. **Round-trip harness**: read a corpus `.iwa` → re-serialize via the new writer →
   assert the object graph survives `IWAArchive.objects` (object-for-object; exact
   bytes may differ since our Snappy match choices differ from Apple's). Then that
   Pages opens a re-zipped, otherwise-unchanged document. Validates the writer first.
3. **Template-mutation MVP**: bundle a blank `.pages`; edit the body storage `#3`
   text + run tables; re-serialize only `Document.iwa`; re-zip (STORED) carrying
   `Metadata/`+previews; confirm Pages opens and shows the new text.
4. **`PackageMetadata` rebuilder** — only needed once we add *new* `.iwa` files:
   ID allocator (seed at max→next million, write back `#1`), `ComponentInfo` for the
   new file, `#6` refs. Digests can be left as the template's (confirmed not gating).
5. Settle the self-sufficiency posture on the bundled template with Oliver.

---

## Open questions

Mostly resolved by the prior-art sweep:
- **`#11` digests required to open?** No — `numbers-parser` round-trips the
  template's and never regenerates them; they serve collaboration/merge. ✅
- **`preview*.jpg` required?** No — carry the template's through; a stale preview
  shows a wrong thumbnail but doesn't block opening. `DocumentMetadata.iwa` /
  `AnnotationAuthorStorage` / `CalculationEngine` are referenced from the graph, so
  with template-mutation you **keep** them as-is (don't author, don't delete). ✅
- **`fileFormatVersion` / `BuildVersionHistory` validated?** No — version mismatch
  is a *warning*, not a gate; BuildVersionHistory is cosmetic history. Carry through. ✅

Still genuinely open (only matters for Strategy B / from-scratch):
- Can all objects live in **one** component (no `DocumentStylesheet.iwa`)? References
  are by global ID (a storage detail), which suggests yes, but it's unverified
  against Pages.app and is moot if we mutate a template.

## Prior art
- **`masaccio/numbers-parser`** (Python) — the model to copy: *writes* `.numbers`
  by mutating a bundled `empty.numbers`. Read `containers.py` (`ObjectStore`,
  ID→file map, `new_message_id`), `model.py` (`add_component_metadata`), and
  `iwafile.py` (the exact 64 KiB/chunk framing). Also ships compiled `*_pb2.py`
  protos for the **common** archives (TSP/TSWP/TSD/TSS/TST/TSCE…) — directly reusable.
  https://github.com/masaccio/numbers-parser
- **`psobot/keynote-parser`** (Python) — unpack→edit→repack round-tripper; confirms
  no Stream Identifier / no CRC. https://github.com/psobot/keynote-parser
- **`obriensp/iWorkFileFormat`** — canonical format docs + extracted `.proto`
  schemas + per-type message-type maps.
  https://github.com/obriensp/iWorkFileFormat/blob/master/Docs/index.md
  · proto-dump: https://github.com/obriensp/proto-dump
- **`6over3/WorkKit`** (Swift, read-only, AGPL-3.0) — a Swift iWork parser with its
  own proto + Snappy modules; useful for cross-checking proto defs and a second
  Swift Snappy. https://github.com/6over3/WorkKit
- **SheetJS iWA notes** (field-15 = Pages discriminator; zip quirk):
  https://github.com/SheetJS/notes/blob/main/iwa/README.md
- Real `.pages` `BuildVersionHistory.plist` sample (array-of-strings, template marker):
  https://github.com/mattdonnelly/CS4052/blob/master/Assignment%201/Report.pages/Metadata/BuildVersionHistory.plist

> **Dumping `TP.*` type numbers (only if going from scratch):** attach `lldb` to
> Pages.app and `po [TSPRegistry sharedRegistry]`; `numbers-parser`'s
> `protos/generate_mapping.py` reformats that output. Not needed for template-mutation.

---

## Cell-level table settings (decoded via edit-and-diff, 2026-06-16)

Observed by editing a generated table in Pages, saving, and diffing the IWA.

**Table-level toggles (implemented):** title = `TableModelArchive.table_name_enabled` #22
+ `DrawableArchive.title_hidden` #12; caption = `DrawableArchive.caption_hidden` #13.
Style-driven (inherited from the theme `table-0-tableStyle` 6003 → `table_properties`
#11, `TST.TableStylePropertiesArchive`): `banded_rows` #1, `auto_resize` #22, gridline
visibility `v/h_strokes_visible` #33/#34 + separators #35–#37, `table_border_visible`
#38, stroke styles #46–#61. Header/footer counts = model #9/#10/#11. Row/col sizes =
`HeaderStorageBucket.Header.size` #2.

**Cell text alignment — IMPLEMENTED (2026-06-16); five interlocking pieces, all
validated by Pages.** Horizontal alignment is NOT in the cell style
(`CellStylePropertiesArchive` has only `vertical_alignment` #8, `text_wrap` #3, fill,
strokes, padding). Instead:
- Each tile cell record's word **W1** (bytes 16–19, right after the 4-byte string key) is
  a **key into `DataStore.styleTable`** (the `DataList` whose list-id is 4; sample id
  1733212), NOT a direct enum.
- styleTable entry = `{ #1 key, #2 refcount, #4 { #1 styleRef } }` → a `TSWP`
  paragraph style (type 2022). The style's `para_properties` (#12) `#1` field is the
  alignment override.
- Pages creates a distinct style per (alignment × header/body), because the **parent**
  base differs by bold: `1731526` "Table Style 1" (bold, header) vs `1731527`
  "Table Style 2" (regular, body); both parents have `#12 #1 = 4` (natural).
- `#12 #1` override values: **right = 1, center = 2**. Left columns use no override —
  their body cells are left *unstyled* (24-byte cell, SW `0x08`, no W1), so they fall
  back to the default left. (This is the left-vs-center resolution: left isn't a `#12`
  value, it's the absence of a style key.)
- **Two more references must be registered or Pages silently drops the styling / reports
  the doc "damaged":** (a) each synth style's `MessageInfo #5` object_references must
  list its parent; (b) the styleTable's `MessageInfo #5` must list all the synth style
  ids; (c) the styleTable component's `PackageMetadata ComponentInfo #6` must add
  `{component = DocumentStylesheet, object = styleId}` per synth style.
- Done in `PagesTableBuilder.styling(for:)` / `styleRecord` / `relocateComponentMetadata`,
  `PagesWriter.tablePackageMetadata`, and `PagesParser.tableGrid(forAttachment:)` (reads
  the style key → style `#12` to recover the alignment marker). Works for any number of
  tables (synth style ids are allocated per table id offset).

**In-cell bold/italic — IMPLEMENTED (2026-06-16); validated by Pages.** A cell with any
inline `**bold**`/`*italic*`/`~~strike~~`/`` `code` `` stops being a plain string and
becomes a rich-text cell:
- The cell's text leaves the `stringTable` `DataList` and moves into a **`TSWP`
  `StorageArchive` (type 2001)** — same shape as the body storage: `#3` text (no markup)
  + `#8` char-style run table → synthesized char styles (type 2021, parented to the
  None char style `1731539`, e.g. bold `#11 #1 = 1`, italic `#11 #2 = 1`).
- `DataStore` `#17` = `rich_text_table` → a `DataList` (list-id 8). Entry =
  `{ #1 key, #2 1, #9 { #1 ref } }` (note `#9`, vs `#4` styleTable / `#3` strings). The
  ref is **not** the storage directly but a **type-6218 wrapper** (`#1 { #1 storageRef }`,
  `#3` = a captured-verbatim "whole range" descriptor); the wrapper points at the 2001.
- The tile cell record flips from `05 03` to **`05 09`**, its flags word from `08/48` to
  **`10 10 02 00`** (the `0x10` "has rich id" bit), and the `u32` at byte 12 becomes the
  **rich_text_table key** instead of the string key.
- Cross-refs: the storage's `MessageInfo #5` lists `[paraStyle, listNone, charStyleIDs]`
  (**not** the stylesheet root); the wrapper's `#5` lists `[storageID]`; the
  rich_text_table component's `ComponentInfo #6` cross-references every char/para style
  the storages reach (all in `DocumentStylesheet` 1732613) or Pages reports "damaged".
- **Alignment composes with formatting:** a rich cell has no styleTable key to hang a
  paragraph style on, so it takes the column's alignment through its **own** storage
  paragraph style (`#5` run table → the synthesized alignment style for center/right).
  The reader recovers a rich cell's alignment from that same `#5 → #12 #1`.
- **Gotcha (cost a real "renders regular" bug):** a char-run "back to unstyled" entry at
  index == text length is one past the last character; Pages discards the *entire* run
  table when one is present, so a fully-styled cell (or a body ending in a styled run)
  loses all formatting. A run extends to the next entry / the text end, so entries at or
  beyond the text length are filtered out in both the cell and body builders.
- Reader: a `05 09` cell → rich_text_table key → 6218 wrapper → storage → `#8` run table
  → inline markup (reusing the body's emphasis machinery), plus `#5 → #12 #1` alignment.

## Typed wire models — the programmatic read/write foundation (2026-06-16)

Hand-decoding each setting by edit-and-diff is superseded by **generated typed models**.
`Scripts/GenerateIWAModels.swift` (in-house proto2→Swift generator) reads the vendored
iWork schemas (`Protos/`, from psobot/keynote-parser, MIT — see kreuzberg issue #486 for
the prior-art catalog) and emits `Sources/SwiftTextPages/Generated/IWA/`: **483** message
structs backed by SwiftText's own `ProtobufReader`/`ProtobufWriter` (no swift-protobuf
dep), plus `IWATypeRegistry` mapping **211** IWA type numbers → models.

Each model decodes from a `ProtobufMessage`, re-encodes via `ProtobufWriter`, honors
`[packed]`, and preserves un-modeled fields (`unknownFields`) for lossless round-trips.
**Validated: 3004/3004 modeled objects across six real `.pages` round-trip byte-identical
(canonical compare).** So every documented setting is now typed and named — e.g.
`TST_CellStylePropertiesArchive { cellFill, verticalAlignment, textWrap, padding,
{top,right,bottom,left}Stroke }`, `TSD_FillArchive { color, gradient, image }`,
`TSD_StrokeArchive { color, width, cap, join, … }`, `TSP_Color { model, r,g,b,a, … }`.

### Cell-styling layers (decoded via the models)

A cell's appearance comes from **three** layers, not one:
1. **Table-style preset** — `TableStyleArchive` (6003) / `DefaultCellStylesContainerArchive`
   (6302) hold the `CellStyleArchive` (6004) objects that paint header / body /
   alternating-row fills by *region*. In `CustomTable.pages` these are the ~60 fills
   (e.g. header `rgba(0,0.64,1,1)`); they are **not** per-cell overrides.
2. **Per-cell paragraph override** — `DataStore.styletable` (#5, a `TableDataList`) maps a
   cell's tile-record style key → a **`ParagraphStyleArchive` (2022)** (`#12 #1` = text
   alignment). Confirmed: matches the committed column-alignment implementation.
3. **Per-cell cell-style override** — a manually-filled single cell references a
   `CellStyleArchive` (6004) carrying `cellProperties` (fill/stroke/v-align/wrap).

To build a setting in code: construct the relevant generated archive and `.encoded()` it,
then wire it into the object graph via the appropriate layer above. Regenerate models with
`swift Scripts/GenerateIWAModels.swift Protos Sources/SwiftTextPages/Generated/IWA`.

### Per-cell appearance — IMPLEMENTED via the comprehensive model (2026-06-16)

`PagesTable` carries a programmatic styling layer: `cellAppearances` (fill / vertical
alignment / text wrap / per-edge borders), `columnWidths` / `rowHeights`, and
`headerRows` / `headerColumns` / `footerRows`. The builder synthesizes each distinct
appearance into a `TST.CellStyleArchive` (6004) via the generated wire models
(`cellStyleArchive(_:parent:)`): `super.parent` → a base cell style (1731720),
`cell_properties` = fill (`TSD.FillArchive` → `TSP.Color` model 1 RGBA) / strokes
(`TSD.StrokeArchive`) / `vertical_alignment` (#8) / `text_wrap` (#3). It lives in
`DocumentStylesheet`, joins the style table, and is cross-referenced like the alignment
styles.

**The decisive detail (cost a "fill doesn't render" bug): the cell's tile record flag.**
A per-cell *paragraph* style (alignment, 2022) is keyed via SW byte `0x48` (the `0x40`
bit). A per-cell **cell** style (appearance, 6004) is keyed via SW byte **`0x28`** (the
`0x20` bit) — same 28-byte layout, same offset-16 key slot, different flag. A 6004
referenced through the `0x40` paragraph key is silently ignored; it must be `0x20`.
(RE'd by filling a string cell in Pages and diffing: `05 03 … 28 10 02 00 <strKey>
<styleKey> …`.)

Header/footer counts patch `TableModelArchive` #9/#10/#11; widths/heights fill the
`HeaderStorageBucket` `#2` f32 sizes. **Pages-validated rendering: fill, vertical
alignment, column widths.** Per-cell borders are emitted as solid `TSD.StrokeArchive`s
and round-trip, but Pages renders cell borders from the table's stroke layer rather than
per-cell `cell_properties` strokes — still to wire.

---

## Cold synthesis framework — the typed object graph (2026-06-16)

Everything above either patches bytes of a captured archive or splices pre-built object
sets into it. The **cold synthesis framework** replaces that with a typed, editable model
of the whole document — read a package in, manipulate it as objects, write a valid package
back out, with the record framing and `PackageMetadata` *recomputed from the model* rather
than copied. It is the foundation a document builder stands on, and it is app-agnostic: the
shared `TS*` object layer is byte-identical across Pages, Numbers and Keynote, so the same
machinery round-trips all three (validated: Pages ~570 objects, a Numbers doc 335/335
records byte-identical, a Keynote deck 1309/1309 — zero dangling references in each).

### The layers

- **`IWAPackage`** (package I/O) — parses each `Index/*.iwa` into framing-preserving
  `IWARecord`s (an `ArchiveInfo` id `#1` plus a *repeated* `MessageInfo` `#2`, so one record
  can hold several object parts) and keeps everything else (`Metadata/`, previews) raw.
  `write(to:)` re-frames and STORED-zips. A `Part` is either *preserved* (re-emits Apple's
  `MessageInfo` verbatim, only recomputing the `#3` length) or *synthesized* (emits `#1`
  type, `#3` length, `#5` packed `object_references`).

- **`IWAReferenceScanner`** (the reference engine) — schema-less recovery of an object's
  cross-references. Every link is a `TSP.Reference`/`DataReference`, i.e. a sub-message
  whose `identifier` is at `#1` and whose only other fields are the two deprecated scalars
  (`#2`/`#3`). The scanner walks the payload's message tree and records any *reference-shaped*
  sub-message whose `#1` names a known object. Restricting to known ids (which live in a
  high, sparse range) is what makes it exact, not heuristic. **Validated against Apple's
  stored `object_references` across the blank template: it never misses a real reference**
  (it is a complete superset — Apple additionally omits some style/stylesheet back-pointers
  it resolves through the stylesheet, which is safe to include since the targets exist, and
  which Pages accepts).

- **`IWAObjectGraph`** (the editable model) — components + records, an id allocator
  (one past the high-water mark), reachability (`reachable(from:)`, the mark phase of a GC),
  `referencedIDs(of:)`, `addObject`/`replacePayload` taking typed-model bytes, and
  `syncPackageMetadata()` which raises `last_object_identifier` to cover every synthesized
  id. `read(_:)`/`package()` convert to and from `IWAPackage`; synthesized records get their
  `#5` recomputed on export, unchanged records keep Apple's framing (so an untouched
  document round-trips byte-for-byte).

- **`PagesSynthesizer`** (the Pages app layer) — sources the bundled blank document as a
  *theme + scaffold* (exactly as a Pages theme would supply the stylesheet), rebuilds the
  body text storage and any synthesized character-style (2021) / hyperlink (2032) objects
  through the graph, syncs metadata, applies a fresh document identity, and writes. A
  `NumbersSynthesizer`/`KeynoteSynthesizer` would wrap the same `IWAObjectGraph`, supplying
  the `TN`/`KN` root and theme — the engine doesn't change.

### Validated in Pages

A graph-synthesized document opens cleanly in Pages.app (no repair dialog), which proves
Pages accepts the computed superset `object_references`. Both the *replace* path (plain
body text) and the *add* path (a formatted body that synthesizes a combined bold-italic
character style and a hyperlink object, placed via `addObject` with computed `#5`) render
correctly — heading style, bold, italic, bold-italic and link all intact.

The distinction from `PagesWriter` (which surgically edits archive bytes): the synthesizer
holds the whole document as an inspectable typed graph, so references and metadata are
derived generically instead of hand-patched per feature — the property that lets the same
core extend to Numbers and Keynote.
