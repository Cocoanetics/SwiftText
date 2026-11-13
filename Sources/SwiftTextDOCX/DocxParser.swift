import Foundation
import Archive
#if canImport(FoundationXML)
// On Linux, XMLParser/XMLParserDelegate live in FoundationXML, not Foundation.
import FoundationXML
#endif

final class DocxParser {
	func readDocument(from url: URL) throws -> DocxDocument {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw DocxFileError.fileNotFound(url)
		}
		// libarchive reads sequentially, so collect every part we might need in a
		// single pass rather than seeking to each one by name.
		let wanted: Set<String> = [
			"word/document.xml", "word/styles.xml", "word/numbering.xml", "word/footnotes.xml"
		]
		var parts = [String: Data]()
		do {
			let reader = try ArchiveReader(path: url.path)
			try reader.forEachEntry { entry, reader in
				guard wanted.contains(entry.pathname) else { return }
				parts[entry.pathname] = try reader.readData()
			}
		} catch {
			throw DocxFileError.unreadableArchive(url, error)
		}
		guard let documentData = parts["word/document.xml"] else {
			throw DocxFileError.missingDocumentXML
		}
		let stylesData = parts["word/styles.xml"]
		let numberingData = parts["word/numbering.xml"]
		let footnotesData = parts["word/footnotes.xml"]
		return try parseDocumentXML(
			from: documentData,
			stylesData: stylesData,
			numberingData: numberingData,
			footnotesData: footnotesData
		)
	}

	private func parseDocumentXML(from data: Data, stylesData: Data?, numberingData: Data?, footnotesData: Data?) throws -> DocxDocument {
		let styleCatalog: DocxDocument.StyleCatalog
		if let stylesData {
			styleCatalog = try parseStylesXML(from: stylesData)
		} else {
			styleCatalog = DocxDocument.StyleCatalog()
		}
		let numberingCatalog: DocxDocument.NumberingCatalog
		if let numberingData {
			numberingCatalog = try parseNumberingXML(from: numberingData)
		} else {
			numberingCatalog = DocxDocument.NumberingCatalog()
		}
		let footnotesByID: [String: String]
		if let footnotesData {
			footnotesByID = parseFootnotesXML(from: footnotesData)
		} else {
			footnotesByID = [:]
		}

		let extractor = DocumentExtractor(footnotesByID: footnotesByID, styles: styleCatalog)
		let parser = XMLParser(data: data)
		parser.delegate = extractor
		guard parser.parse() else {
			throw DocxFileError.documentXMLParsingFailed(parser.parserError)
		}
		var document = extractor.document
		document.styles = styleCatalog
		document.numbering = numberingCatalog
		return document
	}

	/// Parses `word/footnotes.xml` into `[footnote id: text]`, skipping the
	/// separator/continuation pseudo-footnotes.
	private func parseFootnotesXML(from data: Data) -> [String: String] {
		let extractor = FootnotesExtractor()
		let parser = XMLParser(data: data)
		parser.delegate = extractor
		guard parser.parse() else { return [:] }
		return extractor.footnotesByID
	}

	private func parseStylesXML(from data: Data) throws -> DocxDocument.StyleCatalog {
		let extractor = StylesExtractor()
		let parser = XMLParser(data: data)
		parser.delegate = extractor
		guard parser.parse() else {
			throw DocxFileError.stylesParsingFailed(parser.parserError)
		}
		return extractor.catalog
	}

	private func parseNumberingXML(from data: Data) throws -> DocxDocument.NumberingCatalog {
		let extractor = NumberingExtractor()
		let parser = XMLParser(data: data)
		parser.delegate = extractor
		guard parser.parse() else {
			throw DocxFileError.numberingParsingFailed(parser.parserError)
		}
		return extractor.catalog
	}
}

private final class DocumentExtractor: NSObject, XMLParserDelegate {
	private enum FormatTarget {
		case paragraph
		case run
	}

	private(set) var document = DocxDocument()
	private let footnotesByID: [String: String]
	/// The paragraph styles, to keep the empty paragraphs that mean something: rules
	/// (`---`) and blank lines of code blocks.
	private let styles: DocxDocument.StyleCatalog
	private var footnoteNumberByID: [String: Int] = [:]
	private var footnoteCounter = 0
	private var currentParagraph: DocxDocument.Paragraph?
	private var currentRunText = ""
	private var insideTextTag = false
	private var insideRun = false
	private var insideParagraphProperties = false
	private var insideParagraphNumbering = false
	private var formatStack = [DocxDocument.FormatState]()
	private var paragraphFormat = DocxDocument.FormatState()
	private var formatTargetStack = [FormatTarget]()
	private var pendingNumberingLevel: Int?
	private var pendingNumberingId: Int?
	/// Set at a table cell's start, so its first paragraph is marked as starting one.
	private var cellStartPending = false
	/// Set when an empty paragraph outside a quote was skipped, so the next paragraph is
	/// marked as following a break (the spacer between two quotes).
	private var breakPending = false
	/// Nested `w:tbl` depth. Code-block wrappers and real tables both use `w:tbl`.
	private var tableDepth = 0
	/// Rows of the table currently being built (`nil` when not inside a top-level table
	/// that we are collecting as a GFM table candidate).
	private var buildingRows: [[[DocxDocument.Paragraph]]]?
	/// Cells of the current row while `buildingRows != nil`.
	private var buildingRow: [[DocxDocument.Paragraph]]?
	/// Paragraphs of the current cell while `buildingRow != nil`.
	private var buildingCell: [DocxDocument.Paragraph]?
	/// Per-column alignments captured from the first row's cell `w:jc` values.
	private var buildingAlignments: [DocxDocument.Paragraph.Table.ColumnAlignment] = []
	/// Alignment pending for the cell currently open.
	private var pendingCellAlignment: DocxDocument.Paragraph.Table.ColumnAlignment?
	/// `w:gridSpan` for the cell currently open (1 when unmerged).
	private var pendingCellGridSpan = 1
	/// Whether the first data row has already fixed `buildingAlignments`.
	private var capturedHeaderAlignments = false

	init(footnotesByID: [String: String], styles: DocxDocument.StyleCatalog) {
		self.footnotesByID = footnotesByID
		self.styles = styles
	}

	private var currentState: DocxDocument.FormatState {
		formatStack.last ?? paragraphFormat
	}

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		let namespaced = elementName.contains(":")
		switch localName(from: elementName) {
		case "tbl":
			beginTable()
		case "tr":
			beginTableRow()
		case "p":
			beginParagraph()
		case "tc":
			beginTableCell()
		case "pPr":
			insideParagraphProperties = true
			formatTargetStack.append(.paragraph)
		case "r":
			insideRun = true
			formatStack.append(currentState)
		case "pStyle":
			applyParagraphStyle(attributes: attributeDict)
		case "ind":
			applyIndent(attributes: attributeDict)
		case "jc":
			applyJustification(attributes: attributeDict)
		case "gridSpan":
			applyGridSpan(attributes: attributeDict)
		case "t":
			insideTextTag = true
			currentRunText = ""
		case "tab":
			guard insideRun else { break }
			flushRunText()
			appendText("\t")
		case "br", "cr", "line":
			guard insideRun else { break }
			flushRunText()
			appendText("\n")
		case "numPr":
			insideParagraphNumbering = true
			pendingNumberingLevel = nil
			pendingNumberingId = nil
		case "ilvl":
			assignNumberingLevel(from: attributeDict)
		case "numId":
			assignNumberingId(from: attributeDict)
		case "b":
			setBold(attributes: attributeDict, namespaced: namespaced)
		case "i":
			setItalic(attributes: attributeDict, namespaced: namespaced)
		case "strike", "dstrike":
			setStrike(attributes: attributeDict, namespaced: namespaced)
		case "footnoteReference":
			appendFootnoteReference(attributes: attributeDict)
		case "rPr":
			if insideRun {
				formatTargetStack.append(.run)
			} else if insideParagraphProperties {
				formatTargetStack.append(.paragraph)
			}
		default:
			break
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		guard insideTextTag else {
			return
		}
		currentRunText += string
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		switch localName(from: elementName) {
		case "t":
			insideTextTag = false
			flushRunText()
		case "p":
			finalizeCurrentParagraph()
		case "tc":
			endTableCell()
		case "tr":
			endTableRow()
		case "tbl":
			endTable()
		case "r":
			insideRun = false
			popFormatState()
		case "pPr":
			insideParagraphProperties = false
			popFormatTarget()
		case "numPr":
			insideParagraphNumbering = false
			applyPendingNumbering()
		case "rPr":
			popFormatTarget()
		default:
			break
		}
	}

	func parserDidEndDocument(_ parser: XMLParser) {
		finalizeCurrentParagraph()
	}

	private func beginParagraph() {
		finalizeCurrentParagraph()
		paragraphFormat = DocxDocument.FormatState()
		formatStack.removeAll(keepingCapacity: true)
		currentParagraph = DocxDocument.Paragraph()
		currentParagraph?.startsTableCell = cellStartPending
		cellStartPending = false
		pendingNumberingId = nil
		pendingNumberingLevel = nil
	}

	private func finalizeCurrentParagraph() {
		flushRunText()
		guard let paragraph = currentParagraph else {
			return
		}
		let style = styles.style(for: paragraph.styleIdentifier)
		if !paragraph.isEmpty || style?.isRule == true || style?.isCodeBlock == true {
			var paragraph = paragraph
			paragraph.followsBreak = breakPending
			breakPending = false
			if buildingCell != nil {
				buildingCell?.append(paragraph)
			} else {
				document.paragraphs.append(paragraph)
			}
		} else if buildingCell != nil {
			// Empty paragraphs inside a table cell are spacers; keep the cell slot.
			breakPending = false
		} else if style?.isBlockQuote != true {
			breakPending = true
		}
		currentParagraph = nil
		formatStack.removeAll(keepingCapacity: true)
		formatTargetStack.removeAll(keepingCapacity: true)
		insideParagraphProperties = false
		insideRun = false
	}

	private func beginTable() {
		finalizeCurrentParagraph()
		tableDepth += 1
		// Only the outermost table is collected; nested tables flatten into the cell.
		guard tableDepth == 1 else { return }
		buildingRows = []
		buildingRow = nil
		buildingCell = nil
		buildingAlignments = []
		capturedHeaderAlignments = false
		pendingCellAlignment = nil
		pendingCellGridSpan = 1
	}

	private func beginTableRow() {
		guard tableDepth == 1, buildingRows != nil else { return }
		finalizeCurrentParagraph()
		buildingRow = []
		buildingCell = nil
		pendingCellAlignment = nil
		pendingCellGridSpan = 1
	}

	private func beginTableCell() {
		cellStartPending = true
		guard tableDepth == 1, buildingRow != nil else { return }
		finalizeCurrentParagraph()
		buildingCell = []
		pendingCellAlignment = nil
		pendingCellGridSpan = 1
	}

	private func endTableCell() {
		guard tableDepth == 1, buildingRow != nil else {
			cellStartPending = false
			return
		}
		finalizeCurrentParagraph()
		let span = max(1, pendingCellGridSpan)
		let content = buildingCell ?? []
		let alignment = pendingCellAlignment ?? .left
		// Expand horizontally merged cells into one content column plus empty
		// placeholders so later unmerged rows keep their column positions.
		buildingRow?.append(content)
		if !capturedHeaderAlignments {
			buildingAlignments.append(alignment)
		}
		for _ in 1..<span {
			buildingRow?.append([])
			if !capturedHeaderAlignments {
				buildingAlignments.append(alignment)
			}
		}
		buildingCell = nil
		pendingCellAlignment = nil
		pendingCellGridSpan = 1
		cellStartPending = false
	}

	private func endTableRow() {
		guard tableDepth == 1, var rows = buildingRows, let row = buildingRow else { return }
		finalizeCurrentParagraph()
		rows.append(row)
		buildingRows = rows
		if !capturedHeaderAlignments {
			capturedHeaderAlignments = true
		}
		buildingRow = nil
		buildingCell = nil
	}

	private func endTable() {
		finalizeCurrentParagraph()
		defer { tableDepth = max(0, tableDepth - 1) }
		guard tableDepth == 1, let rows = buildingRows else { return }
		buildingRows = nil
		buildingRow = nil
		buildingCell = nil

		// The writer wraps fenced code blocks in a single-cell padded table. Keep those
		// paragraphs on the flat list so `renderedParagraphs` still emits a fence.
		if isCodeBlockWrapper(rows) {
			var first = true
			for paragraph in rows.flatMap({ $0.flatMap { $0 } }) {
				var paragraph = paragraph
				paragraph.startsTableCell = first
				first = false
				document.paragraphs.append(paragraph)
			}
			return
		}

		guard !rows.isEmpty else { return }
		let cells: [[String]] = rows.enumerated().map { rowIndex, row in
			row.map { cellParagraphs in
				cellParagraphs
					.map { $0.markedUpText(suppressingUniformBold: rowIndex == 0) }
					.filter { !$0.isEmpty }
					.joined(separator: " ")
			}
		}
		guard cells.contains(where: { $0.contains(where: { !$0.isEmpty }) }) else { return }
		var anchor = DocxDocument.Paragraph()
		anchor.tables = [
			DocxDocument.Paragraph.Table(cells: cells, columnAlignments: buildingAlignments)
		]
		document.paragraphs.append(anchor)
	}

	/// True when every paragraph in a single-cell table uses the Code Block style —
	/// the writer's fenced-code wrapper, not a data table.
	private func isCodeBlockWrapper(_ rows: [[[DocxDocument.Paragraph]]]) -> Bool {
		guard rows.count == 1, rows[0].count == 1 else { return false }
		let paragraphs = rows[0][0]
		guard !paragraphs.isEmpty else { return false }
		return paragraphs.allSatisfy { styles.style(for: $0.styleIdentifier)?.isCodeBlock == true }
	}

	/// Cell (or paragraph) horizontal alignment from `w:jc`. Ignored outside a cell we
	/// are collecting, and ignored for table-level justification in `w:tblPr`.
	private func applyJustification(attributes: [String: String]) {
		guard buildingCell != nil, insideParagraphProperties else { return }
		guard let value = attributeValue(from: attributes, for: ["w:val", "val"])?.lowercased() else {
			return
		}
		switch value {
		case "center":
			pendingCellAlignment = .center
		case "right", "end":
			pendingCellAlignment = .right
		default:
			pendingCellAlignment = .left
		}
	}

	/// Horizontal merge width from `w:gridSpan` inside `w:tcPr`.
	private func applyGridSpan(attributes: [String: String]) {
		guard buildingCell != nil else { return }
		guard let value = attributeValue(from: attributes, for: ["w:val", "val"]),
			  let span = Int(value), span > 0 else { return }
		pendingCellGridSpan = span
	}

	private func appendText(_ text: String) {
		guard var paragraph = currentParagraph else {
			return
		}
		paragraph.append(text: text, formatting: currentState)
		currentParagraph = paragraph
	}

	private func updateCurrentParagraph(_ update: (inout DocxDocument.Paragraph) -> Void) {
		guard var paragraph = currentParagraph else {
			return
		}
		update(&paragraph)
		currentParagraph = paragraph
	}

	private func flushRunText() {
		guard !currentRunText.isEmpty else {
			return
		}
		appendText(currentRunText)
		currentRunText = ""
	}

	private func setBold(attributes: [String: String], namespaced: Bool = false) {
		guard let target = formatTargetStack.last else {
			return
		}
		updateCurrentState(target: target) { state in
			let val = attributeValue(from: attributes, for: namespaced ? ["w:val", "val"] : ["val", "w:val"])
			state.bold = val?.lowercased() != "false" && val?.lowercased() != "0"
		}
	}

	private func setItalic(attributes: [String: String], namespaced: Bool = false) {
		guard let target = formatTargetStack.last else {
			return
		}
		updateCurrentState(target: target) { state in
			let val = attributeValue(from: attributes, for: namespaced ? ["w:val", "val"] : ["val", "w:val"])
			if let val {
				state.italic = val.lowercased() != "false" && val.lowercased() != "0"
			} else {
				state.italic = true
			}
		}
	}

	private func appendFootnoteReference(attributes: [String: String]) {
		guard let id = attributeValue(from: attributes, for: ["w:id", "id"]) else { return }
		flushRunText()
		let number: Int
		if let existing = footnoteNumberByID[id] {
			number = existing
		} else {
			footnoteCounter += 1
			number = footnoteCounter
			footnoteNumberByID[id] = number
			document.footnotes.append(DocxDocument.Footnote(number: number, text: footnotesByID[id] ?? ""))
		}
		updateCurrentParagraph { $0.appendFootnote(number: number) }
	}

	private func setStrike(attributes: [String: String], namespaced: Bool = false) {
		guard let target = formatTargetStack.last else {
			return
		}
		updateCurrentState(target: target) { state in
			let val = attributeValue(from: attributes, for: namespaced ? ["w:val", "val"] : ["val", "w:val"])
			if let val {
				state.strike = val.lowercased() != "false" && val.lowercased() != "0"
			} else {
				state.strike = true
			}
		}
	}

	private func popFormatState() {
		if formatStack.count > 1 {
			formatStack.removeLast()
		} else {
			formatStack.removeAll(keepingCapacity: true)
		}
	}

	private func popFormatTarget() {
		if !formatTargetStack.isEmpty {
			formatTargetStack.removeLast()
		}
	}

	private func updateCurrentState(target: FormatTarget, _ update: (inout DocxDocument.FormatState) -> Void) {
		switch target {
		case .paragraph:
			update(&paragraphFormat)
		case .run:
			guard !formatStack.isEmpty else {
				return
			}
			update(&formatStack[formatStack.count - 1])
		}
	}

	private func applyParagraphStyle(attributes: [String: String]) {
		guard insideParagraphProperties else {
			return
		}
		guard let styleIdentifier = attributeValue(from: attributes, for: ["w:val", "val"]) else {
			return
		}
		updateCurrentParagraph { paragraph in
			paragraph.styleIdentifier = styleIdentifier
		}
	}

	/// A paragraph's direct left indent (twips): a quote's nesting depth.
	private func applyIndent(attributes: [String: String]) {
		guard insideParagraphProperties,
			  let value = attributeValue(from: attributes, for: ["w:left", "left", "w:start", "start"]),
			  let indent = Int(value) else { return }
		updateCurrentParagraph { $0.leftIndent = indent }
	}

	private func assignNumberingLevel(from attributes: [String: String]) {
		guard insideParagraphNumbering else {
			return
		}
		if let value = attributeValue(from: attributes, for: ["w:val", "val"]), let level = Int(value) {
			pendingNumberingLevel = level
		}
	}

	private func assignNumberingId(from attributes: [String: String]) {
		guard insideParagraphNumbering else {
			return
		}
		if let value = attributeValue(from: attributes, for: ["w:val", "val"]), let identifier = Int(value) {
			pendingNumberingId = identifier
		}
	}

	private func applyPendingNumbering() {
		guard let numId = pendingNumberingId else {
			pendingNumberingLevel = nil
			return
		}
		let level = pendingNumberingLevel ?? 0
		updateCurrentParagraph { paragraph in
			paragraph.numbering = DocxDocument.NumberingReference(numId: numId, level: level)
		}
		pendingNumberingId = nil
		pendingNumberingLevel = nil
	}
}

private final class StylesExtractor: NSObject, XMLParserDelegate {
	var catalog = DocxDocument.StyleCatalog()
	private var currentStyle: DocxDocument.ParagraphStyle?
	private var isParagraphStyle = false

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		let name = localName(from: elementName)
		switch name {
		case "style":
			let type = attributeValue(from: attributeDict, for: ["w:type", "type"])
			isParagraphStyle = type == "paragraph"
			guard isParagraphStyle, let styleId = attributeValue(from: attributeDict, for: ["w:styleId", "styleId"]) else {
				currentStyle = nil
				return
			}
			currentStyle = DocxDocument.ParagraphStyle(styleId: styleId, name: nil, outlineLevel: nil)
		case "name":
			guard isParagraphStyle, var style = currentStyle else { break }
			style.name = attributeValue(from: attributeDict, for: ["w:val", "val"]) ?? style.name
			currentStyle = style
		case "outlineLvl":
			guard isParagraphStyle, var style = currentStyle else { break }
			if let value = attributeValue(from: attributeDict, for: ["w:val", "val"]), let level = Int(value) {
				style.outlineLevel = level
			}
			currentStyle = style
		default:
			break
		}
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		if localName(from: elementName) == "style" {
			if let style = currentStyle, isParagraphStyle {
				catalog.add(style)
			}
			currentStyle = nil
			isParagraphStyle = false
		}
	}
}

private final class NumberingExtractor: NSObject, XMLParserDelegate {
	var catalog = DocxDocument.NumberingCatalog()
	private var currentAbstractId: Int?
	private var currentLevelBuilder: NumberingLevelBuilder?
	private var currentNumId: Int?
	private var styleLinkedAbstracts: [String: Int] = [:]
	private var pendingNumStyleLinks: [(Int, String)] = []

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		let name = localName(from: elementName)
		switch name {
		case "abstractNum":
			if let value = attributeValue(from: attributeDict, for: ["w:abstractNumId", "abstractNumId"]), let identifier = Int(value) {
				currentAbstractId = identifier
			} else {
				currentAbstractId = nil
			}
		case "styleLink":
			guard let abstractId = currentAbstractId else { break }
			if let styleName = attributeValue(from: attributeDict, for: ["w:val", "val"]) {
				styleLinkedAbstracts[styleName] = abstractId
			}
		case "numStyleLink":
			guard let abstractId = currentAbstractId else { break }
			if let styleName = attributeValue(from: attributeDict, for: ["w:val", "val"]) {
				pendingNumStyleLinks.append((abstractId, styleName))
			}
		case "lvl":
			guard let value = attributeValue(from: attributeDict, for: ["w:ilvl", "ilvl"]), let level = Int(value) else {
				currentLevelBuilder = nil
				return
			}
			currentLevelBuilder = NumberingLevelBuilder(level: level)
		case "start":
			guard var builder = currentLevelBuilder else { break }
			if let value = attributeValue(from: attributeDict, for: ["w:val", "val"]), let start = Int(value) {
				builder.start = start
				currentLevelBuilder = builder
			}
		case "numFmt":
			guard var builder = currentLevelBuilder else { break }
			if let value = attributeValue(from: attributeDict, for: ["w:val", "val"]) {
				builder.format = DocxDocument.NumberingFormat(rawValue: value)
				currentLevelBuilder = builder
			}
		case "lvlText":
			guard var builder = currentLevelBuilder else { break }
			builder.text = attributeValue(from: attributeDict, for: ["w:val", "val"])
			currentLevelBuilder = builder
		case "num":
			if let value = attributeValue(from: attributeDict, for: ["w:numId", "numId"]), let identifier = Int(value) {
				currentNumId = identifier
			} else {
				currentNumId = nil
			}
		case "abstractNumId":
			guard let value = attributeValue(from: attributeDict, for: ["w:val", "val"]), let abstractId = Int(value), let numId = currentNumId else {
				break
			}
			catalog.map(numId: numId, to: abstractId)
		default:
			break
		}
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		let name = localName(from: elementName)
		switch name {
		case "abstractNum":
			currentAbstractId = nil
		case "lvl":
			if
				let abstractId = currentAbstractId,
				let builder = currentLevelBuilder {
				catalog.addLevel(builder.build(), to: abstractId)
			}
			currentLevelBuilder = nil
		case "num":
			currentNumId = nil
		default:
			break
		}
	}

	func parserDidEndDocument(_ parser: XMLParser) {
		for (abstractId, styleName) in pendingNumStyleLinks {
			guard
				let targetAbstractId = styleLinkedAbstracts[styleName],
				let levels = catalog.levels(for: targetAbstractId)
			else {
				continue
			}
			catalog.setLevels(levels, for: abstractId)
		}
	}

	private struct NumberingLevelBuilder {
		let level: Int
		var start: Int = 1
		var format: DocxDocument.NumberingFormat = .decimal
		var text: String?

		func build() -> DocxDocument.NumberingCatalog.NumberingLevel {
			DocxDocument.NumberingCatalog.NumberingLevel(
				level: level,
				start: start,
				format: format,
				text: text
			)
		}
	}
}

private final class FootnotesExtractor: NSObject, XMLParserDelegate {
	private(set) var footnotesByID: [String: String] = [:]
	private var currentID: String?
	private var skip = false
	private var currentText = ""
	private var insideText = false

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		switch localName(from: elementName) {
		case "footnote":
			currentID = attributeValue(from: attributeDict, for: ["w:id", "id"])
			let type = attributeValue(from: attributeDict, for: ["w:type", "type"])
			// Separator/continuation pseudo-footnotes are not real content.
			skip = (type == "separator" || type == "continuationSeparator")
			currentText = ""
		case "t":
			insideText = true
		case "tab", "br", "cr":
			if !skip { currentText += " " }
		default:
			break
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		guard insideText, !skip else { return }
		currentText += string
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		switch localName(from: elementName) {
		case "t":
			insideText = false
		case "footnote":
			if let id = currentID, !skip {
				let text = currentText
					.replacingOccurrences(of: "\n", with: " ")
					.replacingOccurrences(of: "\t", with: " ")
					.trimmingCharacters(in: .whitespacesAndNewlines)
				if !text.isEmpty {
					footnotesByID[id] = text
				}
			}
			currentID = nil
			skip = false
			insideText = false
		default:
			break
		}
	}
}

private func attributeValue(from attributes: [String: String], for keys: [String]) -> String? {
	for key in keys {
		if let value = attributes[key] {
			return value
		}
	}
	return nil
}

private func localName(from elementName: String) -> String {
	guard let separatorIndex = elementName.firstIndex(of: ":") else {
		return elementName
	}
	let nextIndex = elementName.index(after: separatorIndex)
	return String(elementName[nextIndex...])
}
