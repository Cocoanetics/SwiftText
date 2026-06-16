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
	/// Whether the paragraph is block-quoted (rendered indented + italic).
	var blockQuote: Bool = false
	/// For an attachment paragraph (a single `U+FFFC`), the drawable-attachment
	/// object id (type 2003) the `#9` run table maps that character to — e.g. a
	/// native table. `nil` for ordinary text paragraphs.
	var attachment: UInt64?
	/// The native table this attachment paragraph anchors, if any. The writer builds
	/// its object set and injects it; the paragraph text is a single `U+FFFC`.
	var table: PagesTable?
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

/// Resolves `InlineStyle` combinations to character-style object ids, synthesizing
/// new `TSWP.CharacterStyleArchive` objects for combinations the template lacks
/// (anything beyond a single built-in bold/italic/strikethrough).
final class CharacterStyleRegistry {
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

	private static func hyperlinkPayload(url: String) -> [UInt8] {
		// #1 = { #1: a unique smart-field UUID }, #2 = the destination URL.
		var fieldIdentifier = ProtobufWriter()
		fieldIdentifier.stringField(1, UUID().uuidString)
		var archive = ProtobufWriter()
		archive.messageField(1, fieldIdentifier.bytes)
		archive.stringField(2, url)
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
		styleSuper.messageField(5, parentReference.bytes)   // TSS.StyleArchive.parent

		var charProperties = ProtobufWriter()
		if style.code { charProperties.stringField(5, "Menlo-Regular") }  // monospace font
		if style.bold { charProperties.varintField(1, 1) }
		if style.italic { charProperties.varintField(2, 1) }
		if style.link { charProperties.varintField(11, 1) }              // underline
		if style.strikethrough { charProperties.varintField(12, 1) }

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

	static func body(from paragraphs: [BodyParagraph], templatePayload: [UInt8], registry: CharacterStyleRegistry) -> [UInt8] {
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
		for (index, paragraph) in paragraphs.enumerated() {
			let start = paragraphStarts[index]
			let styleID = paragraph.blockQuote ? PagesStyleID.blockQuote : paragraph.paragraphStyle
			paragraphStyleEntries.append((start, styleID))
			paragraphDataEntries.append((start, paragraph.listLevel))
			listStyleEntries.append((start, paragraph.listStyle ?? PagesStyleID.listNone))
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

		// 4. Rebuild the storage payload: keep all template fields, override text + tables.
		var provided: [Int: [UInt8]] = [
			3: Array(fullText.utf8),
			5: runTable(paragraphStyleEntries),
			6: paragraphDataTable(paragraphDataEntries),
			7: runTable(listStyleEntries),
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
					if property.number == 2 { inner.varintField(2, 1); setItalic = true }
					else { inner.append(property) }
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

	/// The para-data table: repeated entries `{ #1: charIndex, #2: 0, #3: listLevel }`,
	/// matching the shape the reader reads (field 3 = list indent level).
	private static func paragraphDataTable(_ entries: [(index: Int, level: Int)]) -> [UInt8] {
		var table = ProtobufWriter()
		for entry in entries {
			var entryWriter = ProtobufWriter()
			entryWriter.varintField(1, UInt64(entry.index))
			entryWriter.varintField(2, 0)
			entryWriter.varintField(3, UInt64(entry.level))
			table.messageField(1, entryWriter.bytes)
		}
		return table.bytes
	}
}
