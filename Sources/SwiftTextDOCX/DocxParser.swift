import Foundation
import ZIPFoundation
#if canImport(FoundationXML)
// On Linux, XMLParser/XMLParserDelegate live in FoundationXML, not Foundation.
import FoundationXML
#endif

final class DocxParser {
	func readDocument(from url: URL) throws -> DocxDocument {
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw DocxFileError.fileNotFound(url)
		}
		let archive: Archive
		do {
			archive = try Archive(url: url, accessMode: .read)
		} catch {
			throw DocxFileError.unreadableArchive(url, error)
		}
		guard let documentEntry = archive["word/document.xml"] else {
			throw DocxFileError.missingDocumentXML
		}
		let documentData = try data(for: documentEntry, in: archive)
		let stylesData = try dataIfAvailable(named: "word/styles.xml", in: archive)
		let numberingData = try dataIfAvailable(named: "word/numbering.xml", in: archive)
		return try parseDocumentXML(
			from: documentData,
			stylesData: stylesData,
			numberingData: numberingData
		)
	}

	private func parseDocumentXML(from data: Data, stylesData: Data?, numberingData: Data?) throws -> DocxDocument {
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

		let extractor = DocumentExtractor()
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

	private func data(for entry: Entry, in archive: Archive) throws -> Data {
		var data = Data()
		_ = try archive.extract(entry) { data.append($0) }
		return data
	}

	private func dataIfAvailable(named name: String, in archive: Archive) throws -> Data? {
		guard let entry = archive[name] else {
			return nil
		}
		return try data(for: entry, in: archive)
	}
}

private final class DocumentExtractor: NSObject, XMLParserDelegate {
	private enum FormatTarget {
		case paragraph
		case run
	}

	private(set) var document = DocxDocument()
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

	private var currentState: DocxDocument.FormatState {
		formatStack.last ?? paragraphFormat
	}

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		switch elementName {
		case "w:p", "p", "wp:p":
			beginParagraph()
		case "w:pPr", "pPr":
			insideParagraphProperties = true
			formatTargetStack.append(.paragraph)
		case "w:r", "r":
			insideRun = true
			formatStack.append(currentState)
		case "w:pStyle", "pStyle":
			applyParagraphStyle(attributes: attributeDict)
		case "w:t", "t":
			insideTextTag = true
			currentRunText = ""
		case "w:tab", "tab":
			guard insideRun else { break }
			flushRunText()
			appendText("\t")
		case "w:br", "br", "w:cr", "cr", "w:line", "line":
			guard insideRun else { break }
			flushRunText()
			appendText("\n")
		case "w:numPr", "numPr":
			insideParagraphNumbering = true
			pendingNumberingLevel = nil
			pendingNumberingId = nil
		case "w:ilvl", "ilvl":
			assignNumberingLevel(from: attributeDict)
		case "w:numId", "numId":
			assignNumberingId(from: attributeDict)
		case "w:b", "b":
			setBold(attributes: attributeDict)
		case "w:i", "i":
			setItalic(attributes: attributeDict)
		case "w:rPr", "rPr":
			if insideRun {
				formatTargetStack.append(.run)
			} else if insideParagraphProperties {
				formatTargetStack.append(.paragraph)
			}
		default:
			if elementName.hasSuffix(":p") {
				beginParagraph()
			} else if elementName.hasSuffix(":pPr") {
				insideParagraphProperties = true
				formatTargetStack.append(.paragraph)
			} else if elementName.hasSuffix(":r") {
				insideRun = true
				formatStack.append(currentState)
			} else if elementName.hasSuffix(":pStyle") {
				applyParagraphStyle(attributes: attributeDict)
			} else if elementName.hasSuffix(":t") {
				insideTextTag = true
				currentRunText = ""
			} else if elementName.hasSuffix(":tab") {
				guard insideRun else { break }
				flushRunText()
				appendText("\t")
			} else if elementName.hasSuffix(":br") || elementName.hasSuffix(":cr") || elementName.hasSuffix(":line") {
				guard insideRun else { break }
				flushRunText()
				appendText("\n")
			} else if elementName.hasSuffix(":numPr") {
				insideParagraphNumbering = true
				pendingNumberingLevel = nil
				pendingNumberingId = nil
			} else if elementName.hasSuffix(":ilvl") {
				assignNumberingLevel(from: attributeDict)
			} else if elementName.hasSuffix(":numId") {
				assignNumberingId(from: attributeDict)
			} else if elementName.hasSuffix(":b") {
				setBold(attributes: attributeDict, namespaced: true)
			} else if elementName.hasSuffix(":i") {
				setItalic(attributes: attributeDict, namespaced: true)
			} else if elementName.hasSuffix(":rPr") {
				if insideRun {
					formatTargetStack.append(.run)
				} else if insideParagraphProperties {
					formatTargetStack.append(.paragraph)
				}
			}
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		guard insideTextTag else {
			return
		}
		currentRunText += string
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		switch elementName {
		case "w:t", "t":
			insideTextTag = false
			flushRunText()
		case "w:p", "p", "wp:p":
			finalizeCurrentParagraph()
		case "w:r", "r":
			insideRun = false
			popFormatState()
		case "w:pPr", "pPr":
			insideParagraphProperties = false
			popFormatTarget()
		case "w:numPr", "numPr":
			insideParagraphNumbering = false
			applyPendingNumbering()
		case "w:rPr", "rPr":
			popFormatTarget()
		default:
			if elementName.hasSuffix(":t") {
				insideTextTag = false
				flushRunText()
			} else if elementName.hasSuffix(":p") {
				finalizeCurrentParagraph()
			} else if elementName.hasSuffix(":r") {
				insideRun = false
				popFormatState()
			} else if elementName.hasSuffix(":pPr") {
				insideParagraphProperties = false
				popFormatTarget()
			} else if elementName.hasSuffix(":numPr") {
				insideParagraphNumbering = false
				applyPendingNumbering()
			} else if elementName.hasSuffix(":rPr") {
				popFormatTarget()
			}
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
		pendingNumberingId = nil
		pendingNumberingLevel = nil
	}

	private func finalizeCurrentParagraph() {
		flushRunText()
		guard let paragraph = currentParagraph else {
			return
		}
		if !paragraph.isEmpty {
			document.paragraphs.append(paragraph)
		}
		currentParagraph = nil
		formatStack.removeAll(keepingCapacity: true)
		formatTargetStack.removeAll(keepingCapacity: true)
		insideParagraphProperties = false
		insideRun = false
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
				let builder = currentLevelBuilder
			{
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
