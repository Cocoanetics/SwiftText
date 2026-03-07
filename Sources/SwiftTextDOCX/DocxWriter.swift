import Foundation
import ZIPFoundation

/// Generates DOCX (Office Open XML) files from structured block content.
///
/// Usage:
/// ```swift
/// let writer = DocxWriter()
/// writer.blocks = [
///     .heading(level: 1, runs: [.init(text: "Hello World")]),
///     .paragraph(runs: [.init(text: "Some "), .init(text: "bold", bold: true), .init(text: " text.")]),
/// ]
/// try writer.write(to: outputURL)
/// ```
public final class DocxWriter {

	// MARK: - Public Types

	/// A block-level element in the document.
	public enum Block {
		case heading(level: Int, runs: [Run])
		case paragraph(runs: [Run])
		case listItem(ordered: Bool, level: Int, runs: [Run])
		case codeBlock(language: String?, text: String)
		case blockquote(blocks: [Block])
		case horizontalRule
	}

	/// A styled span of inline text.
	public struct Run: Sendable {
		public var text: String
		public var bold: Bool
		public var italic: Bool
		public var code: Bool
		public var link: String?

		public init(text: String, bold: Bool = false, italic: Bool = false, code: Bool = false, link: String? = nil) {
			self.text = text
			self.bold = bold
			self.italic = italic
			self.code = code
			self.link = link
		}
	}

	// MARK: - Public Properties

	/// The blocks to render into the DOCX document.
	public var blocks: [Block] = []

	// MARK: - Private State

	/// Tracks hyperlink relationships for document.xml.rels.
	private var hyperlinks: [(id: String, url: String)] = []
	private var hyperlinkCounter = 0

	/// Tracks numbering instances for list continuity.
	private var nextNumId = 0
	private var lastListType: ListType? = nil
	/// Maps each concrete numId to its abstract numbering id (0=bullet, 1=decimal).
	private var numInstances: [(numId: Int, abstractNumId: Int)] = []

	private enum ListType: Equatable {
		case ordered
		case unordered
	}

	// MARK: - Initialization

	public init() {}

	// MARK: - Writing

	/// Writes the document to a DOCX file at the given URL.
	/// - Parameter url: Destination file URL (should end in `.docx`).
	public func write(to url: URL) throws {
		// Reset state
		hyperlinks = []
		hyperlinkCounter = 0
		nextNumId = 0
		lastListType = nil
		numInstances = []

		// Build document body XML
		let bodyXML = generateBodyXML()

		// Build all required parts
		let contentTypes = generateContentTypes()
		let rels = generateRootRels()
		let documentRels = generateDocumentRels()
		let documentXML = wrapDocument(bodyXML)
		let stylesXML = generateStyles()
		let numberingXML = generateNumbering()

		// Create ZIP archive (remove existing file first)
		let dir = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		if FileManager.default.fileExists(atPath: url.path) {
			try FileManager.default.removeItem(at: url)
		}

		guard let archive = Archive(url: url, accessMode: .create) else {
			throw DocxWriterError.archiveCreationFailed
		}

		try addEntry(archive, path: "[Content_Types].xml", content: contentTypes)
		try addEntry(archive, path: "_rels/.rels", content: rels)
		try addEntry(archive, path: "word/_rels/document.xml.rels", content: documentRels)
		try addEntry(archive, path: "word/document.xml", content: documentXML)
		try addEntry(archive, path: "word/styles.xml", content: stylesXML)
		try addEntry(archive, path: "word/numbering.xml", content: numberingXML)
	}

	// MARK: - Archive Helpers

	private func addEntry(_ archive: Archive, path: String, content: String) throws {
		let data = Data(content.utf8)
		try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
			data[Int(position)..<(Int(position) + size)]
		}
	}

	// MARK: - Body Generation

	private func generateBodyXML() -> String {
		var xml = ""
		for block in blocks {
			xml += renderBlock(block, quoteDepth: 0)
		}
		// Section properties (A4 portrait, 2cm margins)
		xml += """
		<w:sectPr>
		<w:pgSz w:w="11906" w:h="16838" w:orient="portrait"/>
		<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="709" w:footer="709" w:gutter="0"/>
		</w:sectPr>
		"""
		return xml
	}

	private func renderBlock(_ block: Block, quoteDepth: Int) -> String {
		switch block {
		case .heading(let level, let runs):
			lastListType = nil
			let clamped = max(1, min(level, 6))
			return paragraph(style: "Heading\(clamped)", runs: runs, quoteDepth: quoteDepth)

		case .paragraph(let runs):
			lastListType = nil
			return paragraph(style: nil, runs: runs, quoteDepth: quoteDepth)

		case .listItem(let ordered, let level, let runs):
			let listType: ListType = ordered ? .ordered : .unordered
			if lastListType != listType {
				nextNumId += 1
				let abstractNumId = ordered ? 1 : 0
				numInstances.append((numId: nextNumId, abstractNumId: abstractNumId))
				lastListType = listType
			}
			return listParagraph(runs: runs, numId: nextNumId, ilvl: level, quoteDepth: quoteDepth)

		case .codeBlock(_, let text):
			lastListType = nil
			return codeBlockParagraphs(text, quoteDepth: quoteDepth)

		case .blockquote(let innerBlocks):
			lastListType = nil
			var xml = ""
			for inner in innerBlocks {
				xml += renderBlock(inner, quoteDepth: quoteDepth + 1)
			}
			return xml

		case .horizontalRule:
			lastListType = nil
			return horizontalRuleParagraph(quoteDepth: quoteDepth)
		}
	}

	// MARK: - Paragraph Builders

	private func paragraph(style: String?, runs: [Run], quoteDepth: Int) -> String {
		var pPr = ""
		if let style {
			pPr += "<w:pStyle w:val=\"\(xmlEscape(style))\"/>"
		}
		if quoteDepth > 0 {
			let indent = quoteDepth * 360 // 0.25 inch per level
			pPr += "<w:ind w:left=\"\(indent)\"/>"
			if style == nil {
				pPr += "<w:pBdr><w:left w:val=\"single\" w:sz=\"12\" w:space=\"4\" w:color=\"CCCCCC\"/></w:pBdr>"
			}
		}
		let pPrXML = pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>"
		return "<w:p>\(pPrXML)\(renderRuns(runs))</w:p>\n"
	}

	private func listParagraph(runs: [Run], numId: Int, ilvl: Int, quoteDepth: Int) -> String {
		var indentXML = ""
		if quoteDepth > 0 {
			let indent = quoteDepth * 360
			indentXML = "<w:ind w:left=\"\(indent + (ilvl + 1) * 720)\"/>"
		}
		let pPr = """
		<w:pPr>\
		<w:pStyle w:val="ListParagraph"/>\
		<w:numPr><w:ilvl w:val="\(ilvl)"/><w:numId w:val="\(numId)"/></w:numPr>\
		\(indentXML)\
		</w:pPr>
		"""
		return "<w:p>\(pPr)\(renderRuns(runs))</w:p>\n"
	}

	private func codeBlockParagraphs(_ text: String, quoteDepth: Int) -> String {
		let lines = text.components(separatedBy: "\n")
		var xml = ""
		let baseIndent = quoteDepth * 360
		let codeIndent = baseIndent + 360 // left padding inside the block

		for (index, line) in lines.enumerated() {
			var pPr = "<w:pStyle w:val=\"CodeBlock\"/>"
			let afterSpacing = (index == lines.count - 1) ? "200" : "0"
			pPr += "<w:spacing w:before=\"0\" w:after=\"\(afterSpacing)\" w:line=\"240\" w:lineRule=\"auto\"/>"
			pPr += "<w:ind w:left=\"\(codeIndent)\" w:right=\"360\"/>"
			pPr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F5F5F5\"/>"

			// Borders: top on first line, bottom on last line, left+right on all
			var borders = "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"E0E0E0\"/>"
			borders += "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"E0E0E0\"/>"
			if index == 0 {
				borders += "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"E0E0E0\"/>"
			}
			if index == lines.count - 1 {
				borders += "<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"4\" w:color=\"E0E0E0\"/>"
			} else {
				// Between lines: suppress paragraph border gaps
				borders += "<w:between w:val=\"none\" w:sz=\"0\" w:space=\"0\" w:color=\"auto\"/>"
			}
			pPr += "<w:pBdr>\(borders)</w:pBdr>"

			let run = "<w:r><w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/><w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(line))</w:t></w:r>"
			xml += "<w:p><w:pPr>\(pPr)</w:pPr>\(run)</w:p>\n"
		}
		return xml
	}

	private func horizontalRuleParagraph(quoteDepth: Int) -> String {
		var indentXML = ""
		if quoteDepth > 0 {
			indentXML = "<w:ind w:left=\"\(quoteDepth * 360)\"/>"
		}
		return """
		<w:p><w:pPr>\
		<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="DDDDDD"/></w:pBdr>\
		\(indentXML)\
		</w:pPr></w:p>

		"""
	}

	// MARK: - Run Rendering

	private func renderRuns(_ runs: [Run]) -> String {
		var xml = ""
		for run in runs {
			if let link = run.link {
				let rId = nextHyperlinkId(url: link)
				var rPr = "<w:rStyle w:val=\"Hyperlink\"/>"
				if run.bold { rPr += "<w:b/><w:bCs/>" }
				if run.italic { rPr += "<w:i/><w:iCs/>" }
				xml += "<w:hyperlink r:id=\"\(rId)\"><w:r><w:rPr>\(rPr)</w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(run.text))</w:t></w:r></w:hyperlink>"
			} else {
				var rPr = ""
				if run.bold { rPr += "<w:b/><w:bCs/>" }
				if run.italic { rPr += "<w:i/><w:iCs/>" }
				if run.code {
					rPr += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
					rPr += "<w:sz w:val=\"21\"/><w:szCs w:val=\"21\"/>"
				}
				let rPrXML = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
				xml += "<w:r>\(rPrXML)<w:t xml:space=\"preserve\">\(xmlEscape(run.text))</w:t></w:r>"
			}
		}
		return xml
	}

	private func nextHyperlinkId(url: String) -> String {
		hyperlinkCounter += 1
		let rId = "rLink\(hyperlinkCounter)"
		hyperlinks.append((id: rId, url: url))
		return rId
	}

	// MARK: - OOXML Boilerplate

	private func wrapDocument(_ body: String) -> String {
		"""
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<w:document \
		xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
		xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
		xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
		mc:Ignorable="w14">
		<w:body>
		\(body)
		</w:body>
		</w:document>
		"""
	}

	private func generateContentTypes() -> String {
		"""
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
		<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
		<Default Extension="xml" ContentType="application/xml"/>
		<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
		<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
		<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
		</Types>
		"""
	}

	private func generateRootRels() -> String {
		"""
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
		<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
		</Relationships>
		"""
	}

	private func generateDocumentRels() -> String {
		var rels = """
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
		<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
		<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>

		"""
		for link in hyperlinks {
			rels += "<Relationship Id=\"\(link.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xmlEscape(link.url))\" TargetMode=\"External\"/>\n"
		}
		rels += "</Relationships>"
		return rels
	}

	// MARK: - Styles

	private func generateStyles() -> String {
		// Font sizes in half-points: 12pt = 24, 24pt = 48, etc.
		// Matches the PDF generator CSS styling.
		"""
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
		<w:docDefaults>
		<w:rPrDefault><w:rPr>
		<w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Arial"/>
		<w:sz w:val="22"/><w:szCs w:val="22"/>
		<w:color w:val="222222"/>
		<w:lang w:val="en-US"/>
		</w:rPr></w:rPrDefault>
		<w:pPrDefault><w:pPr>
		<w:spacing w:after="120" w:line="276" w:lineRule="auto"/>
		</w:pPr></w:pPrDefault>
		</w:docDefaults>

		<w:style w:type="paragraph" w:default="1" w:styleId="Normal">
		<w:name w:val="Normal"/>
		</w:style>

		\(headingStyle(level: 1, size: 48, borderBottom: true, borderSize: 12))
		\(headingStyle(level: 2, size: 36, borderBottom: true, borderSize: 6))
		\(headingStyle(level: 3, size: 30, borderBottom: false))
		\(headingStyle(level: 4, size: 26, borderBottom: false))
		\(headingStyle(level: 5, size: 24, borderBottom: false))
		\(headingStyle(level: 6, size: 22, borderBottom: false))

		<w:style w:type="paragraph" w:styleId="ListParagraph">
		<w:name w:val="List Paragraph"/>
		<w:basedOn w:val="Normal"/>
		<w:pPr><w:ind w:left="720"/></w:pPr>
		</w:style>

		<w:style w:type="paragraph" w:styleId="CodeBlock">
		<w:name w:val="Code Block"/>
		<w:basedOn w:val="Normal"/>
		<w:pPr>
		<w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/>
		<w:spacing w:after="0" w:line="240" w:lineRule="auto"/>
		</w:pPr>
		<w:rPr>
		<w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/>
		<w:sz w:val="20"/><w:szCs w:val="20"/>
		</w:rPr>
		</w:style>

		<w:style w:type="character" w:styleId="Hyperlink">
		<w:name w:val="Hyperlink"/>
		<w:rPr>
		<w:color w:val="0366D6"/>
		<w:u w:val="single"/>
		</w:rPr>
		</w:style>

		</w:styles>
		"""
	}

	private func headingStyle(level: Int, size: Int, borderBottom: Bool, borderSize: Int = 0) -> String {
		let spaceBefore = level <= 2 ? "240" : "200"
		let spaceAfter = "80"
		var pPr = "<w:spacing w:before=\"\(spaceBefore)\" w:after=\"\(spaceAfter)\"/>"
		pPr += "<w:keepNext/><w:keepLines/>"
		if borderBottom {
			let color = level == 1 ? "DDDDDD" : "EEEEEE"
			pPr += "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"\(borderSize)\" w:space=\"4\" w:color=\"\(color)\"/></w:pBdr>"
		}
		return """
		<w:style w:type="paragraph" w:styleId="Heading\(level)">
		<w:name w:val="heading \(level)"/>
		<w:basedOn w:val="Normal"/>
		<w:next w:val="Normal"/>
		<w:pPr><w:outlineLvl w:val="\(level - 1)"/>\(pPr)</w:pPr>
		<w:rPr><w:b/><w:bCs/><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
		</w:style>
		"""
	}

	// MARK: - Numbering

	private func generateNumbering() -> String {
		"""
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">

		<!-- Abstract 0: bullet list -->
		<w:abstractNum w:abstractNumId="0">
		<w:multiLevelType w:val="hybridMultilevel"/>
		\(bulletLevels())
		</w:abstractNum>

		<!-- Abstract 1: decimal list -->
		<w:abstractNum w:abstractNumId="1">
		<w:multiLevelType w:val="hybridMultilevel"/>
		\(decimalLevels())
		</w:abstractNum>

		<!-- Concrete numbering instances -->
		\(numInstances.map { "<w:num w:numId=\"\($0.numId)\"><w:abstractNumId w:val=\"\($0.abstractNumId)\"/></w:num>" }.joined(separator: "\n"))

		</w:numbering>
		"""
	}

	private func bulletLevels() -> String {
		// Use Unicode bullet characters with standard fonts (cross-platform safe).
		let symbols = ["\u{2022}", "\u{25CB}", "\u{25AA}"] // •, ○, ▪
		return (0..<9).map { lvl in
			let symbol = symbols[lvl % symbols.count]
			let indent = (lvl + 1) * 720
			let hanging = 360
			return """
			<w:lvl w:ilvl="\(lvl)">
			<w:start w:val="1"/>
			<w:numFmt w:val="bullet"/>
			<w:lvlText w:val="\(symbol)"/>
			<w:lvlJc w:val="left"/>
			<w:pPr><w:ind w:left="\(indent)" w:hanging="\(hanging)"/></w:pPr>
			<w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:hint="default"/></w:rPr>
			</w:lvl>
			"""
		}.joined(separator: "\n")
	}

	private func decimalLevels() -> String {
		(0..<9).map { lvl in
			let indent = (lvl + 1) * 720
			let hanging = 360
			let fmt: String
			switch lvl % 3 {
			case 0: fmt = "decimal"
			case 1: fmt = "lowerLetter"
			default: fmt = "lowerRoman"
			}
			return """
			<w:lvl w:ilvl="\(lvl)">
			<w:start w:val="1"/>
			<w:numFmt w:val="\(fmt)"/>
			<w:lvlText w:val="%\(lvl + 1)."/>
			<w:lvlJc w:val="left"/>
			<w:pPr><w:ind w:left="\(indent)" w:hanging="\(hanging)"/></w:pPr>
			</w:lvl>
			"""
		}.joined(separator: "\n")
	}

	// MARK: - Utilities

	private func xmlEscape(_ text: String) -> String {
		text.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
	}
}

// MARK: - Errors

public enum DocxWriterError: Error, LocalizedError {
	case archiveCreationFailed

	public var errorDescription: String? {
		switch self {
		case .archiveCreationFailed:
			return "Failed to create DOCX archive"
		}
	}
}
