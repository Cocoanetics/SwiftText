import SwiftTextIWA
import Foundation

/// Object identifiers of the built-in styles in the bundled blank template
/// (`DocumentStylesheet.iwa`, stylesheet 1732613). Captured by reverse-engineering
/// the template; stable for that captured template.
enum PagesStyleID {
	// Paragraph styles (TSWP.ParagraphStyleArchive, type 2022)
	static let body: UInt64 = 1731511
	static let title: UInt64 = 1731491
	static let heading1: UInt64 = 1731502
	static let heading2: UInt64 = 1731503
	static let heading3: UInt64 = 1731504
	static let heading4: UInt64 = 1731505
	static let caption: UInt64 = 1731517

	/// "Caption" — another normal, referenceable style the Markdown writer doesn't
	/// otherwise use, repurposed as the code-block ("preformatted") style: a copy of
	/// Body in a monospace face, tight line spacing, and a light background fill. Same
	/// rationale as [blockQuote] — a real style's para_properties apply.
	static let codeBlock: UInt64 = 1731517

	// Character styles (TSWP.CharacterStyleArchive, type 2021)
	static let noneChar: UInt64 = 1731539
	static let linkChar: UInt64 = 1731540
	static let boldChar: UInt64 = 1731541          // named "Emphasis": char_properties bold
	static let strikethroughChar: UInt64 = 1731542
	static let italicChar: UInt64 = 1731544

	/// "Subtitle" — a normal, referenceable style unused by the Markdown writer, so
	/// it's repurposed as the block-quote style: its payload is overwritten with a
	/// copy of Body plus a left indent (a real style's para_properties apply, unlike
	/// a synthesized one's, and a normal style is safe to reference — unlike the
	/// special "Default" style, which crashes Pages).
	static let blockQuote: UInt64 = 1731497

	// List styles (TSWP.ListStyleArchive, type 2023)
	static let listNone: UInt64 = 1731481
	static let bulletList: UInt64 = 1731482
	static let numberedList: UInt64 = 1731486

	/// The root stylesheet — the parent of every style; used when synthesizing new ones.
	static let stylesheet: UInt64 = 1732613

	/// First identifier handed out to objects we synthesize. Well above the
	/// template's range (~1.73M) so new ids never collide with captured ones.
	static let synthesizedBase: UInt64 = 6_000_000
}

/// Stable `style_identifier` strings for the styles the Markdown writer repurposes,
/// shared so the writer (which stamps them) and the parser (which reads them back to
/// recover block quotes / code fences on round-trip) can't drift apart.
enum PagesStyleIdentifier {
	static let blockQuote = "swifttext-block-quote"
	static let codeBlock = "swifttext-code-block"
}

/// An inline character styling combination.
struct InlineStyle: Hashable {
	var bold = false
	var italic = false
	var strikethrough = false
	var code = false
	var link = false

	var isPlain: Bool { !bold && !italic && !strikethrough && !code && !link }
}

/// One paragraph of body content destined for the document's text storage.
struct BodyParagraph {
	/// The paragraph's text (inline content already flattened; no trailing break).
	var text: String
	/// The paragraph style object id (Body, a Heading, etc.).
	var paragraphStyle: UInt64
	/// The list style object id, or `nil` when the paragraph isn't a list item.
	var listStyle: UInt64?
	/// Nesting depth for list items (0-based); ignored when not a list.
	var listLevel: Int = 0
	/// Logical ordered-list container identity, used to keep one Markdown list on
	/// one Pages list instance even when nested lists interrupt its item stream.
	var listInstance: Int?
	/// Whether the paragraph is block-quoted (rendered indented + italic).
	var blockQuote: Bool = false
	/// For an attachment paragraph (a single `U+FFFC`), the drawable-attachment
	/// object id (type 2003) the `#9` run table maps that character to — e.g. a
	/// native table. `nil` for ordinary text paragraphs.
	var attachment: UInt64?
	/// The native table this attachment paragraph anchors, if any. The writer builds
	/// its object set and injects it; the paragraph text is a single `U+FFFC`.
	var table: PagesTable?
	/// An inline image this attachment paragraph anchors, if any. The writer embeds the
	/// resolved bytes and points the `#9` anchor at the image's drawable attachment;
	/// the paragraph text is a single `U+FFFC`.
	var image: ImageRef?

	/// A Markdown image reference to embed: the (relative) source path and alt text.
	struct ImageRef {
		var source: String
		var alt: String
	}
	/// Native footnote references anchored in this paragraph: a paragraph-relative UTF-16
	/// offset plus the note text. The writer builds the footnote objects and the body's
	/// `#16` reference run table.
	var footnoteRefs: [FootnoteRef] = []

	struct FootnoteRef {
		var offset: Int
		var text: String
	}
	/// Inline style spans, as UTF-16 ranges within `text`.
	var runs: [StyledRun] = []
	/// Hyperlink spans, as UTF-16 ranges within `text` plus the destination URL.
	var links: [LinkSpan] = []

	struct StyledRun {
		var start: Int       // UTF-16 offset within the paragraph
		var length: Int      // UTF-16 length
		var style: InlineStyle
	}

	struct LinkSpan {
		var start: Int       // UTF-16 offset within the paragraph
		var length: Int      // UTF-16 length
		var url: String
	}
}

/// Allocates body-scoped objects referenced from run tables: synthesized
/// character styles, hyperlink smart fields, and anonymous list styles.
final class BodyObjectRegistry {
	private var nextID = PagesStyleID.synthesizedBase
	private var cache: [InlineStyle: UInt64] = [:]
	private(set) var synthesizedObjects: [IWAObject] = []

	/// The character-style id for a styling combination (the "None" style for plain).
	func identifier(for style: InlineStyle) -> UInt64 {
		if style.isPlain { return PagesStyleID.noneChar }
		if let cached = cache[style] { return cached }

		// Reuse a built-in style for a single property.
		let builtIn: UInt64?
		switch (style.bold, style.italic, style.strikethrough, style.code, style.link) {
		case (true, false, false, false, false): builtIn = PagesStyleID.boldChar
		case (false, true, false, false, false): builtIn = PagesStyleID.italicChar
		case (false, false, true, false, false): builtIn = PagesStyleID.strikethroughChar
		case (false, false, false, false, true): builtIn = PagesStyleID.linkChar
		default: builtIn = nil
		}
		if let builtIn {
			cache[style] = builtIn
			return builtIn
		}

		// Synthesize a combined style.
		let id = nextID
		nextID += 1
		synthesizedObjects.append(IWAObject(identifier: id, type: 2021, payload: Self.characterStylePayload(for: style)))
		cache[style] = id
		return id
	}

	/// Synthesizes a hyperlink object (`TSWP` smart field, type 2032) carrying the
	/// URL, and returns its identifier. One per link span.
	func hyperlinkObject(url: String) -> UInt64 {
		let id = nextID
		nextID += 1
		synthesizedObjects.append(IWAObject(identifier: id, type: 2032, payload: Self.hyperlinkPayload(url: url)))
		return id
	}

	/// A fresh numbered-list style inheriting the captured template's numbered
	/// style. Pages treats the style object identity as the list instance, so
	/// separate Markdown lists need separate anonymous styles to restart at 1.
	func numberedListStyleInstance() -> UInt64 {
		let id = nextID
		nextID += 1
		synthesizedObjects.append(IWAObject(
			identifier: id,
			type: 2023,
			payload: Self.inheritedListStylePayload(parent: PagesStyleID.numberedList)
		))
		return id
	}

	private static func hyperlinkPayload(url: String) -> [UInt8] {
		// #1 = { #1: a unique smart-field UUID }, #2 = the destination URL.
		var fieldIdentifier = ProtobufWriter()
		fieldIdentifier.stringField(1, UUID().uuidString)
		var archive = ProtobufWriter()
		archive.messageField(1, fieldIdentifier.bytes)
		archive.stringField(2, url)
		return archive.bytes
	}

	private static func inheritedListStylePayload(parent parentID: UInt64) -> [UInt8] {
		var parentReference = ProtobufWriter()
		parentReference.varintField(1, parentID)

		var styleSuper = ProtobufWriter()
		styleSuper.messageField(3, parentReference.bytes)     // TSS.StyleArchive.parent

		var archive = ProtobufWriter()
		archive.messageField(1, styleSuper.bytes)             // TSWP.ListStyleArchive.super
		return archive.bytes
	}

	/// The highest synthesized identifier (for bumping the package's id high-water mark).
	var maxIdentifier: UInt64 { nextID - 1 }
	var didSynthesize: Bool { !synthesizedObjects.isEmpty }

	/// Builds a `CharacterStyleArchive` payload mirroring the template's built-in
	/// character styles: a `TSS.StyleArchive` super (name + parent stylesheet
	/// reference), the `#10` marker every built-in carries, and char_properties.
	private static func characterStylePayload(for style: InlineStyle) -> [UInt8] {
		var parentReference = ProtobufWriter()
		parentReference.varintField(1, PagesStyleID.stylesheet)
		var styleSuper = ProtobufWriter()
		styleSuper.stringField(1, styleName(for: style))    // TSS.StyleArchive.name
		styleSuper.messageField(5, parentReference.bytes)   // TSS.StyleArchive.stylesheet

		var charProperties = ProtobufWriter()
		if style.bold { charProperties.varintField(1, 1) }
		if style.italic { charProperties.varintField(2, 1) }
		if style.link { charProperties.varintField(11, 1) }              // underline
		if style.strikethrough { charProperties.varintField(12, 1) }
		if style.code {
			charProperties.stringField(5, "Menlo-Regular")              // monospace font
			// Inline `code` reads as a distinct color in a fixed-width font (no
			// background highlight). Color renders from tsdFill (#46); #7 kept for
			// round-trip — see settingTextColor.
			let c = PagesBodySerializer.codeTextColor
			let colorBytes = PagesBodySerializer.colorBytes(red: c.r, green: c.g, blue: c.b)
			charProperties.bytesField(7, colorBytes)
			var fill = ProtobufWriter(); fill.bytesField(1, colorBytes)
			charProperties.bytesField(46, fill.bytes)
		}

		var archive = ProtobufWriter()
		archive.messageField(1, styleSuper.bytes)            // TSWP.CharacterStyleArchive.super
		archive.varintField(10, 1)                           // present on every built-in char style
		archive.messageField(11, charProperties.bytes)       // char_properties
		return archive.bytes
	}

	private static func styleName(for style: InlineStyle) -> String {
		var parts = [String]()
		if style.bold { parts.append("Bold") }
		if style.italic { parts.append("Italic") }
		if style.strikethrough { parts.append("Strikethrough") }
		if style.code { parts.append("Code") }
		if style.link { parts.append("Link") }
		return "SwiftText " + (parts.isEmpty ? "Style" : parts.joined(separator: " "))
	}
}

/// Serializes body paragraphs into a `TSWP.StorageArchive` payload by editing the
/// template body storage: it rebuilds the text (field 3) and the paragraph-style
/// (5), para-data (6), list-style (7), and character-style (8) run tables, while
/// preserving every other field of the template storage verbatim.
enum PagesBodySerializer {
	/// The paragraph separator iWork uses inside a storage's text.
	static let paragraphSeparator = "\u{2029}"

	static func body(from paragraphs: [BodyParagraph], templatePayload: [UInt8], registry: BodyObjectRegistry, footnoteMarkIDs: [UInt64] = [], footnoteCharStyleID: UInt64? = nil) -> [UInt8] {
		// 1. Assemble the full text and each paragraph's UTF-16 start offset.
		var fullText = ""
		var paragraphStarts = [Int]()
		var cursor = 0
		for (index, paragraph) in paragraphs.enumerated() {
			if index > 0 {
				fullText += paragraphSeparator
				cursor += 1
			}
			paragraphStarts.append(cursor)
			fullText += paragraph.text
			cursor += paragraph.text.utf16.count
		}

		// 2. Paragraph-style (#5), para-data (#6), list-style (#7) run tables — one entry per paragraph.
		var paragraphStyleEntries = [(index: Int, styleID: UInt64?)]()
		var paragraphDataEntries = [(index: Int, level: Int)]()
		var listStyleEntries = [(index: Int, styleID: UInt64?)]()
		var numberedListStylesByInstance = [Int: UInt64]()
		var activeOrderedListStyle: UInt64?
		for (index, paragraph) in paragraphs.enumerated() {
			let start = paragraphStarts[index]
			let styleID = paragraph.blockQuote ? PagesStyleID.blockQuote : paragraph.paragraphStyle
			paragraphStyleEntries.append((start, styleID))
			paragraphDataEntries.append((start, paragraph.listLevel))
			let listStyle = paragraph.listStyle ?? PagesStyleID.listNone
			if listStyle == PagesStyleID.numberedList {
				if let listInstance = paragraph.listInstance {
					let instanceStyle = numberedListStylesByInstance[listInstance] ?? registry.numberedListStyleInstance()
					numberedListStylesByInstance[listInstance] = instanceStyle
					listStyleEntries.append((start, instanceStyle))
				} else {
					if activeOrderedListStyle == nil {
						activeOrderedListStyle = registry.numberedListStyleInstance()
					}
					listStyleEntries.append((start, activeOrderedListStyle))
				}
			} else {
				activeOrderedListStyle = nil
				listStyleEntries.append((start, listStyle))
			}
		}

		// 3. Character-style run table (#8). Pages writes this as a partition that
		// starts at index 0 and uses *bare* entries (no style reference) to return
		// to unstyled text — referencing an explicit "none" style makes Pages ignore
		// the table. Collect the styled spans in document order, then emit changes.
		var styledRuns = [(start: Int, end: Int, styleID: UInt64)]()
		for (index, paragraph) in paragraphs.enumerated() {
			let start = paragraphStarts[index]
			for run in paragraph.runs.sorted(by: { $0.start < $1.start }) where run.length > 0 && !run.style.isPlain {
				styledRuns.append((start + run.start, start + run.start + run.length, registry.identifier(for: run.style)))
			}
			// Each footnote reference is a `U+000E` character; style it with the footnote
			// mark character style so Pages renders the superscript number.
			if let footnoteCharStyleID {
				for ref in paragraph.footnoteRefs {
					styledRuns.append((start + ref.offset, start + ref.offset + 1, footnoteCharStyleID))
				}
			}
		}
		var characterEntries = [(index: Int, styleID: UInt64?)]()
		if !styledRuns.isEmpty {
			styledRuns.sort { $0.start < $1.start }
			characterEntries.append((0, nil))           // explicit "unstyled" from the start
			for run in styledRuns {
				characterEntries.append((run.start, run.styleID))
				characterEntries.append((run.end, nil))  // bare entry: back to unstyled
			}
			// An entry at index == text length is past the last character; Pages discards
			// the whole run table if one is present (so a document ending in a styled run
			// would lose all formatting). A run simply extends to the end instead.
			characterEntries = normalizedRunEntries(characterEntries).filter { $0.index < fullText.utf16.count }
		}

		// 3b. Smart-field run table (#11): map each link's range to a synthesized
		// hyperlink object (type 2032). Same partition shape as the char table.
		var linkSpans = [(start: Int, end: Int, url: String)]()
		for (index, paragraph) in paragraphs.enumerated() {
			let start = paragraphStarts[index]
			for link in paragraph.links where link.length > 0 {
				linkSpans.append((start + link.start, start + link.start + link.length, link.url))
			}
		}
		var hyperlinkEntries = [(index: Int, styleID: UInt64?)]()
		if !linkSpans.isEmpty {
			linkSpans.sort { $0.start < $1.start }
			hyperlinkEntries.append((0, nil))
			for span in linkSpans {
				let objectID = registry.hyperlinkObject(url: span.url)
				hyperlinkEntries.append((span.start, objectID))
				hyperlinkEntries.append((span.end, nil))
			}
			hyperlinkEntries = normalizedRunEntries(hyperlinkEntries)
		}

		// 3c. Attachment run table (#9): map each attachment paragraph's `U+FFFC`
		// character to its drawable-attachment object id (e.g. a native table). One
		// entry per attachment at its character index (no partition reset needed).
		var attachmentEntries = [(index: Int, styleID: UInt64?)]()
		for (index, paragraph) in paragraphs.enumerated() {
			if let attachment = paragraph.attachment {
				attachmentEntries.append((paragraphStarts[index], attachment))
			}
		}

		// 3d. Footnote reference run table (#16): each footnote reference maps a body
		// character index to its mark object, consumed in document order from the
		// builder's `footnoteMarkIDs`.
		var footnoteEntries = [(index: Int, styleID: UInt64?)]()
		var footnoteCursor = 0
		for (index, paragraph) in paragraphs.enumerated() {
			let start = paragraphStarts[index]
			for ref in paragraph.footnoteRefs.sorted(by: { $0.offset < $1.offset }) where footnoteCursor < footnoteMarkIDs.count {
				footnoteEntries.append((start + ref.offset, footnoteMarkIDs[footnoteCursor]))
				footnoteCursor += 1
			}
		}

		// 4. Rebuild the storage payload: keep all template fields, override text + tables.
		var provided: [Int: [UInt8]] = [
			3: Array(fullText.utf8),
			5: runTable(paragraphStyleEntries),
			6: paragraphDataTable(paragraphDataEntries),
			7: runTable(listStyleEntries)
		]
		if !characterEntries.isEmpty {
			provided[8] = runTable(characterEntries)
		}
		if !attachmentEntries.isEmpty {
			provided[9] = runTable(attachmentEntries)
		}
		if !hyperlinkEntries.isEmpty {
			provided[11] = runTable(hyperlinkEntries)
		}
		if !footnoteEntries.isEmpty {
			provided[16] = runTable(footnoteEntries)
		}

		let template = ProtobufMessage(templatePayload)
		var fieldNumbers = Set(provided.keys)
		for field in template.fields { fieldNumbers.insert(field.number) }

		var writer = ProtobufWriter()
		for number in fieldNumbers.sorted() {
			if let bytes = provided[number] {
				writer.bytesField(number, bytes)
			} else {
				for field in template.fields where field.number == number {
					writer.append(field)
				}
			}
		}
		return writer.bytes
	}

	/// `TSWP.ParagraphStylePropertiesArchive` (the style's field 12) field numbers.
	private enum ParaProperty {
		static let firstLineIndent = 7
		static let leftIndent = 11
		static let rightIndent = 19
		static let spaceAfter = 20
		static let spaceBefore = 21
	}

	/// Returns a paragraph-style payload with its paragraph spacing set (in points)
	/// inside the para_properties (field 12). Other fields are preserved.
	static func settingSpacing(in stylePayload: [UInt8], spaceBefore: Float, spaceAfter: Float) -> [UInt8] {
		editingParaProperties(in: stylePayload) { writer, present in
			present.insert(ParaProperty.spaceAfter)
			present.insert(ParaProperty.spaceBefore)
			writer[ParaProperty.spaceAfter] = ProtobufWriter.fixed32(spaceAfter.bitPattern)
			writer[ParaProperty.spaceBefore] = ProtobufWriter.fixed32(spaceBefore.bitPattern)
		}
	}

	/// Returns a paragraph-style payload with a left indent (points) in its
	/// para_properties (field 12) — sets both first-line and left indent. Other
	/// fields preserved.
	static func settingLeftIndent(in stylePayload: [UInt8], points: Float) -> [UInt8] {
		editingParaProperties(in: stylePayload) { overrides, touched in
			touched.insert(ParaProperty.leftIndent)
			touched.insert(ParaProperty.firstLineIndent)
			overrides[ParaProperty.leftIndent] = ProtobufWriter.fixed32(points.bitPattern)
			overrides[ParaProperty.firstLineIndent] = ProtobufWriter.fixed32(points.bitPattern)
		}
	}

	/// Returns a paragraph-style payload with independent left and first-line indents
	/// (points) in its para_properties (field 12). With a left rule present (see
	/// ``settingLeftRule(in:red:green:blue:width:)``) Pages draws the bar at the
	/// first-line indent and flows all text from the larger left indent — i.e. the
	/// HTML block-quote look of bar → gap → text. Other fields are preserved.
	static func settingIndents(in stylePayload: [UInt8], left: Float, firstLine: Float, right: Float? = nil) -> [UInt8] {
		editingParaProperties(in: stylePayload) { overrides, touched in
			touched.insert(ParaProperty.leftIndent)
			touched.insert(ParaProperty.firstLineIndent)
			overrides[ParaProperty.leftIndent] = ProtobufWriter.fixed32(left.bitPattern)
			overrides[ParaProperty.firstLineIndent] = ProtobufWriter.fixed32(firstLine.bitPattern)
			if let right {
				touched.insert(ParaProperty.rightIndent)
				overrides[ParaProperty.rightIndent] = ProtobufWriter.fixed32(right.bitPattern)
			}
		}
	}

	/// Returns a paragraph-style payload with a **left vertical rule** — the HTML-style
	/// block-quote bar: a solid `stroke` on the left edge only. See
	/// ``settingParagraphBorder(in:fill:stroke:borderPositions:borders:rounded:)`` for the
	/// encoding; the colour reuses ``colorBytes(red:green:blue:alpha:)``.
	static func settingLeftRule(in stylePayload: [UInt8], red: Float, green: Float, blue: Float, width: Float) -> [UInt8] {
		settingParagraphBorder(
			in: stylePayload,
			fill: nil,
			stroke: solidStroke(color: colorBytes(red: red, green: green, blue: blue), width: width),
			borderPositions: 4,            // left edge
			borders: 8,                    // legacy left bit
			rounded: false
		)
	}

	/// Returns a paragraph-style payload framed like an HTML `<pre>` block: a filled,
	/// rounded box bordered on all four edges. Encodes a para_properties background
	/// `fill` (#6, an RGBA `TSP.Color`), a solid all-edges `stroke` (#32), and rounded
	/// corners (#46) — reverse-engineered from a Pages-authored code block. Pair with
	/// ``settingIndents(in:left:firstLine:right:)`` for the interior padding.
	static func settingBoxFrame(in stylePayload: [UInt8], fill: (r: Float, g: Float, b: Float, a: Float), stroke: (r: Float, g: Float, b: Float), strokeWidth: Float) -> [UInt8] {
		settingParagraphBorder(
			in: stylePayload,
			fill: colorBytes(red: fill.r, green: fill.g, blue: fill.b, alpha: fill.a),
			stroke: solidStroke(color: colorBytes(red: stroke.r, green: stroke.g, blue: stroke.b), width: strokeWidth),
			borderPositions: 15,           // all four edges (1|2|4|8)
			borders: 4,                    // legacy box bit
			rounded: true
		)
	}

	/// A solid `TSD.StrokeArchive` (`color` + `width`) with the all-zero dash `pattern`
	/// (type 1 = solid) Pages emits. Shared by the block-quote bar and the box frame.
	private static func solidStroke(color: [UInt8], width: Float) -> [UInt8] {
		var pattern = ProtobufWriter()
		pattern.varintField(1, 1)                            // type = solid
		pattern.fixed32Field(2, Float(0).bitPattern)         // phase
		pattern.varintField(3, 0)                            // count
		for _ in 0..<6 { pattern.fixed32Field(4, Float(0).bitPattern) }  // dash array (all-zero = solid)

		var stroke = ProtobufWriter()
		stroke.bytesField(1, color)                          // color
		stroke.fixed32Field(2, width.bitPattern)             // width (points)
		stroke.varintField(3, 0)                             // cap = butt
		stroke.varintField(4, 0)                             // join = miter
		stroke.fixed32Field(5, Float(4).bitPattern)          // miter limit
		stroke.bytesField(6, pattern.bytes)                  // pattern
		return stroke.bytes
	}

	/// Core paragraph-border writer: rewrites para_properties (field 12) with an optional
	/// background `fill` (#6, clearing `fill_null` #5), a `stroke` (#32), the edge bitmask
	/// `borderPositions` (#45) + legacy `borders` (#15), and optional `roundedCorners` (#46).
	/// `stroke_null` (#31) is dropped so the stroke renders. All other properties preserved.
	private static func settingParagraphBorder(in stylePayload: [UInt8], fill: [UInt8]?, stroke: [UInt8], borderPositions: UInt64, borders: UInt64, rounded: Bool) -> [UInt8] {
		var drop: Set<Int> = [15, 31, 32, 45, 46]
		if fill != nil { drop.insert(5); drop.insert(6) }    // replace fill + clear fill_null

		func appendBorder(to inner: inout ProtobufWriter) {
			if let fill { inner.bytesField(6, fill) }
			inner.varintField(15, borders)
			inner.bytesField(32, stroke)
			inner.varintField(45, borderPositions)
			if rounded { inner.varintField(46, 1) }
		}

		let style = ProtobufMessage(stylePayload)
		var writer = ProtobufWriter()
		var wrote = false
		for field in style.fields {
			guard field.number == 12, case .lengthDelimited(let paraProperties) = field.value else { writer.append(field); continue }
			var inner = ProtobufWriter()
			for property in ProtobufMessage(paraProperties).fields where !drop.contains(property.number) {
				inner.append(property)
			}
			appendBorder(to: &inner)
			writer.bytesField(12, inner.bytes)
			wrote = true
		}
		if !wrote {                                          // no para_properties yet — add one
			var inner = ProtobufWriter()
			appendBorder(to: &inner)
			writer.bytesField(12, inner.bytes)
		}
		return writer.bytes
	}

	/// Returns a paragraph-style payload with relative line spacing (a multiple of the
	/// line height, e.g. 1.2) set in its para_properties (field 12). Sets the
	/// `line_spacing` message (field 13, mode = relative, amount = `multiple`) and
	/// clears the `line_spacing_null` flag (field 12); all other fields preserved.
	static func settingLineSpacing(in stylePayload: [UInt8], multiple: Float) -> [UInt8] {
		var spacing = ProtobufWriter()
		spacing.varintField(1, 0)                                   // kRelativeLineSpacing
		spacing.fixed32Field(2, multiple.bitPattern)                // amount
		let style = ProtobufMessage(stylePayload)
		var writer = ProtobufWriter()
		var wrote = false
		for field in style.fields {
			guard field.number == 12, case .lengthDelimited(let paraProperties) = field.value else { writer.append(field); continue }
			var inner = ProtobufWriter()
			for property in ProtobufMessage(paraProperties).fields where property.number != 12 && property.number != 13 {
				inner.append(property)                              // keep all but the null flag / old line_spacing
			}
			inner.bytesField(13, spacing.bytes)
			writer.bytesField(12, inner.bytes)
			wrote = true
		}
		if !wrote {                                                 // no para_properties yet — add one
			var inner = ProtobufWriter(); inner.bytesField(13, spacing.bytes)
			writer.bytesField(12, inner.bytes)
		}
		return writer.bytes
	}

	/// Rewrites a style's char_properties (field 11), letting `transform` rebuild the
	/// inner fields. Creates char_properties if the style has none.
	private static func editCharProperties(in stylePayload: [UInt8], _ transform: ([ProtobufField]) -> [UInt8]) -> [UInt8] {
		let style = ProtobufMessage(stylePayload)
		var writer = ProtobufWriter()
		var found = false
		for field in style.fields {
			if field.number == 11, case .lengthDelimited(let charProperties) = field.value {
				writer.bytesField(11, transform(ProtobufMessage(charProperties).fields))
				found = true
			} else {
				writer.append(field)
			}
		}
		if !found { writer.bytesField(11, transform([])) }
		return writer.bytes
	}

	/// Returns a style payload with bold set in its char_properties (field 1).
	static func settingBold(in stylePayload: [UInt8]) -> [UInt8] {
		editCharProperties(in: stylePayload) { fields in
			var inner = ProtobufWriter()
			for field in fields where field.number != 1 { inner.append(field) }
			inner.varintField(1, 1)
			return inner.bytes
		}
	}

	/// Returns a style payload with `font_size` (char_properties field 3) set to `points`.
	static func settingFontSize(in stylePayload: [UInt8], points: Float) -> [UInt8] {
		editCharProperties(in: stylePayload) { fields in
			var inner = ProtobufWriter()
			for field in fields where field.number != 3 { inner.append(field) }
			inner.fixed32Field(3, points.bitPattern)
			return inner.bytes
		}
	}

	/// Returns a style payload whose text renders in the given RGB color.
	///
	/// The subtle part: Pages renders text color from the *modern fill* —
	/// `char_properties` field 46, a `TSD.FillArchive` whose field 1 is the color —
	/// **not** the legacy `font_color` (field 7). A style carrying only field 7 renders
	/// black (the fill, copied from the source style, wins). So we write the fill *and*
	/// keep field 7 for round-tripping and older readers. The `TSP.Color` layout
	/// (`model=1` RGB, `r/g/b`, `a=1` #6, `rgbspace=1` #12, trailing `#13=1`) is
	/// byte-for-byte what Pages writes in its own templates (verified against modern cv).
	/// `font_color_null` (#6 of char_properties) and `tsdFill_null` (#45) are dropped so
	/// both color slots are honored.
	/// The text color for code — inline and block — a dark red that reads clearly on
	/// white in a fixed-width font (the alternative to background shading).
	static let codeTextColor: (r: Float, g: Float, b: Float) = (0.64, 0.08, 0.08)

	/// A `TSP.Color` in the exact byte layout Pages writes for rendered color:
	/// `model=1` (RGB), `r/g/b`, `a=1` (#6), `rgbspace=1` (#12, sRGB), trailing `#13=1`.
	/// Verified byte-for-byte against Apple's own templates.
	static func colorBytes(red: Float, green: Float, blue: Float, alpha: Float = 1) -> [UInt8] {
		var color = ProtobufWriter()
		color.varintField(1, 1)                              // model = rgb
		color.fixed32Field(3, red.bitPattern)
		color.fixed32Field(4, green.bitPattern)
		color.fixed32Field(5, blue.bitPattern)
		color.fixed32Field(6, alpha.bitPattern)              // alpha (1 = opaque)
		color.varintField(12, 1)                             // rgbspace = sRGB
		color.fixed32Field(13, Float(1).bitPattern)          // opacity flag Pages always writes
		return color.bytes
	}

	static func settingTextColor(in stylePayload: [UInt8], red: Float, green: Float, blue: Float) -> [UInt8] {
		let colorBytes = Self.colorBytes(red: red, green: green, blue: blue)

		var fill = ProtobufWriter()
		fill.bytesField(1, colorBytes)                       // TSD.FillArchive.color
		let fillBytes = fill.bytes

		return editCharProperties(in: stylePayload) { fields in
			var inner = ProtobufWriter()
			for field in fields where ![6, 7, 45, 46].contains(field.number) { inner.append(field) }
			inner.bytesField(7, colorBytes)                  // font_color (legacy / round-trip)
			inner.bytesField(46, fillBytes)                  // tsdFill (what Pages actually renders)
			return inner.bytes
		}
	}

	/// Returns a style payload whose font family (char_properties field 5) is `name` —
	/// e.g. a monospace face for code blocks. Clears `font_name_null` (#4). Like
	/// font size, the family resolves from the paragraph style, so the whole paragraph
	/// renders in `name` without any per-run override.
	static func settingFontName(in stylePayload: [UInt8], name: String) -> [UInt8] {
		editCharProperties(in: stylePayload) { fields in
			var inner = ProtobufWriter()
			for field in fields where field.number != 4 && field.number != 5 { inner.append(field) }
			inner.stringField(5, name)
			return inner.bytes
		}
	}

	/// Returns a style payload with italic set in its char_properties (field 11).
	static func settingItalic(in stylePayload: [UInt8]) -> [UInt8] {
		let style = ProtobufMessage(stylePayload)
		var writer = ProtobufWriter()
		var wroteCharProperties = false
		for field in style.fields {
			if field.number == 11, case .lengthDelimited(let charProperties) = field.value {
				let message = ProtobufMessage(charProperties)
				var inner = ProtobufWriter()
				var setItalic = false
				for property in message.fields {
					if property.number == 2 { inner.varintField(2, 1); setItalic = true } else { inner.append(property) }
				}
				if !setItalic { inner.varintField(2, 1) }
				writer.bytesField(11, inner.bytes)
				wroteCharProperties = true
			} else {
				writer.append(field)
			}
		}
		if !wroteCharProperties {
			var charProperties = ProtobufWriter()
			charProperties.varintField(2, 1)
			writer.messageField(11, charProperties.bytes)
		}
		return writer.bytes
	}

	/// Returns a style payload with its `TSS.StyleArchive` super (field 1) name
	/// (sub-field 1) and identifier (sub-field 2) replaced — so a style cloned from
	/// another doesn't collide on the stylesheet's identifier map.
	static func settingStyleIdentity(in stylePayload: [UInt8], name: String, identifier: String) -> [UInt8] {
		let style = ProtobufMessage(stylePayload)
		var writer = ProtobufWriter()
		for field in style.fields {
			if field.number == 1, case .lengthDelimited(let superBytes) = field.value {
				let styleSuper = ProtobufMessage(superBytes)
				var inner = ProtobufWriter()
				var wroteName = false
				var wroteIdentifier = false
				for property in styleSuper.fields {
					switch property.number {
					case 1: inner.stringField(1, name); wroteName = true
					case 2: inner.stringField(2, identifier); wroteIdentifier = true
					default: inner.append(property)
					}
				}
				if !wroteName { inner.stringField(1, name) }
				if !wroteIdentifier { inner.stringField(2, identifier) }
				writer.bytesField(1, inner.bytes)
			} else {
				writer.append(field)
			}
		}
		return writer.bytes
	}

	/// Rewrites a paragraph style's para_properties (field 12) via `mutate`, which
	/// receives a map of field-number → raw fixed32 bytes to set and the set of
	/// field numbers it touches (so existing ones are replaced and new ones added).
	private static func editingParaProperties(in stylePayload: [UInt8], _ mutate: (inout [Int: [UInt8]], inout Set<Int>) -> Void) -> [UInt8] {
		var overrides = [Int: [UInt8]]()
		var touched = Set<Int>()
		mutate(&overrides, &touched)

		let style = ProtobufMessage(stylePayload)
		var writer = ProtobufWriter()
		for field in style.fields {
			if field.number == 12, case .lengthDelimited(let paraProperties) = field.value {
				let message = ProtobufMessage(paraProperties)
				var inner = ProtobufWriter()
				for property in message.fields {
					if let raw = overrides[property.number] {
						inner.appendFixed32(property.number, raw)
					} else {
						inner.append(property)
					}
				}
				for number in touched where !message.fields.contains(where: { $0.number == number }) {
					inner.appendFixed32(number, overrides[number]!)
				}
				writer.bytesField(12, inner.bytes)
			} else {
				writer.append(field)
			}
		}
		return writer.bytes
	}

	/// Collapses run-table entries: merges entries at the same index (last wins)
	/// and drops entries that don't change the active style.
	private static func normalizedRunEntries(_ entries: [(index: Int, styleID: UInt64?)]) -> [(index: Int, styleID: UInt64?)] {
		var byIndex = [(index: Int, styleID: UInt64?)]()
		for entry in entries {
			if let last = byIndex.last, last.index == entry.index {
				byIndex[byIndex.count - 1].styleID = entry.styleID
			} else {
				byIndex.append(entry)
			}
		}
		var result = [(index: Int, styleID: UInt64?)]()
		for entry in byIndex {
			if let last = result.last, last.styleID == entry.styleID { continue }
			result.append(entry)
		}
		return result
	}

	/// A run table: repeated entries (field 1), each a `{ #1: charIndex, #2: { #1: styleID } }`.
	/// The reference (#2) is omitted when `styleID` is nil.
	private static func runTable(_ entries: [(index: Int, styleID: UInt64?)]) -> [UInt8] {
		var table = ProtobufWriter()
		for entry in entries {
			var entryWriter = ProtobufWriter()
			entryWriter.varintField(1, UInt64(entry.index))
			if let styleID = entry.styleID {
				var reference = ProtobufWriter()
				reference.varintField(1, styleID)
				entryWriter.messageField(2, reference.bytes)
			}
			table.messageField(1, entryWriter.bytes)
		}
		return table.bytes
	}

	/// The para-data table: repeated entries `{ #1: charIndex, #2: listLevel, #3: 0 }`.
	/// The list *nesting depth* lives in field 2 ("first") — that's the field Pages reads
	/// to look up the per-level indent in the list style (confirmed by indenting a list
	/// item in Pages and diffing: the touched paragraph got `#2 = 1`, and Pages applied
	/// the Bullet style's `indents[1]`). Writing it in field 3, as we used to, left every
	/// item at depth 0 → all levels rendered flush. Field 3 ("second") stays 0.
	private static func paragraphDataTable(_ entries: [(index: Int, level: Int)]) -> [UInt8] {
		var table = ProtobufWriter()
		for entry in entries {
			var entryWriter = ProtobufWriter()
			entryWriter.varintField(1, UInt64(entry.index))
			entryWriter.varintField(2, UInt64(entry.level))
			entryWriter.varintField(3, 0)
			table.messageField(1, entryWriter.bytes)
		}
		return table.bytes
	}
}
