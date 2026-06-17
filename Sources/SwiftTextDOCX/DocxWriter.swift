import Foundation
import SwiftTextCore
import ZIPFoundation

/// Page configuration for DOCX output.
public struct DocxPageSetup: Sendable {
	/// Page width in twips (1 inch = 1440 twips).
	public let width: Int
	/// Page height in twips.
	public let height: Int
	/// Margin on each side in twips.
	public let margin: Int
	/// Whether the page is landscape.
	public let landscape: Bool

	/// Content width (page width minus left and right margins).
	public var contentWidth: Int { width - 2 * margin }

	/// A4 portrait with 2cm margins (default).
	public static let a4 = DocxPageSetup(width: 11906, height: 16838, margin: 1134, landscape: false)
	/// A4 landscape with 2cm margins.
	public static let a4Landscape = DocxPageSetup(width: 16838, height: 11906, margin: 1134, landscape: true)
	/// US Letter portrait with 1-inch margins.
	public static let letter = DocxPageSetup(width: 12240, height: 15840, margin: 1440, landscape: false)
	/// US Letter landscape with 1-inch margins.
	public static let letterLandscape = DocxPageSetup(width: 15840, height: 12240, margin: 1440, landscape: true)

	public init(width: Int, height: Int, margin: Int, landscape: Bool = false) {
		self.width = width
		self.height = height
		self.margin = margin
		self.landscape = landscape
	}
}

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

	/// Column alignment for tables.
	public enum ColumnAlignment: Sendable {
		case left
		case center
		case right
	}

	/// A block-level element in the document.
	public enum Block {
		case heading(level: Int, runs: [Run])
		case paragraph(runs: [Run])
		case listItem(ordered: Bool, level: Int, runs: [Run])
		case codeBlock(language: String?, text: String)
		case blockquote(blocks: [Block])
		case horizontalRule
		case table(headers: [[Run]], rows: [[[Run]]], alignments: [ColumnAlignment])
		/// A standalone image: `source` is resolved against ``DocxWriter/baseURL`` and
		/// embedded as an inline picture; `alt` is the placeholder used when the file
		/// can't be read (or when no `baseURL` is set).
		case image(source: String, alt: String)
	}

	/// A styled span of inline text.
	public struct Run: Sendable {
		public var text: String
		public var bold: Bool
		public var italic: Bool
		public var strike: Bool
		public var code: Bool
		public var link: String?

		public init(text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false, link: String? = nil) {
			self.text = text
			self.bold = bold
			self.italic = italic
			self.strike = strike
			self.code = code
			self.link = link
		}
	}

	// MARK: - Public Properties

	/// The blocks to render into the DOCX document.
	public var blocks: [Block] = []

	/// Page setup (paper size, margins, orientation). Defaults to A4 portrait.
	public var pageSetup: DocxPageSetup = .a4

	/// Directory that standalone-image sources are resolved against. When `nil`,
	/// images render as their alt-text placeholder instead of being embedded.
	public var baseURL: URL?

	// MARK: - Private State

	/// Tracks hyperlink relationships for document.xml.rels.
	private var hyperlinks: [(id: String, url: String)] = []
	private var hyperlinkCounter = 0

	/// Embedded image media collected while rendering the body: the `word/media/*`
	/// part bytes, the `document.xml.rels` relationship, and the `[Content_Types].xml`
	/// `<Default>` for each distinct extension. Populated as a side effect of
	/// `generateBodyXML()`, which runs before the rels/content-types are emitted.
	private var mediaFiles: [(path: String, data: Data)] = []
	private var imageRels: [(id: String, target: String)] = []
	private var imageContentDefaults: [String: String] = [:]
	private var imageCounter = 0

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
		mediaFiles = []
		imageRels = []
		imageContentDefaults = [:]
		imageCounter = 0

		// Build document body XML. This populates `hyperlinks` and the image media
		// state as a side effect, so it must run before the rels / content-types parts.
		let bodyXML = generateBodyXML()

		// Build all required parts
		let contentTypes = generateContentTypes()
		let rels = generateRootRels()
		let documentRels = generateDocumentRels()
		let documentXML = wrapDocument(bodyXML)
		let stylesXML = generateStyles()
		let numberingXML = generateNumbering()
		let settingsXML = generateSettings()
		let fontTableXML = generateFontTable()

		// Create ZIP archive (remove existing file first)
		let dir = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		if FileManager.default.fileExists(atPath: url.path) {
			try FileManager.default.removeItem(at: url)
		}

		let archive: Archive
		do {
			archive = try Archive(url: url, accessMode: .create)
		} catch {
			throw DocxWriterError.archiveCreationFailed
		}

		try addEntry(archive, path: "[Content_Types].xml", content: contentTypes)
		try addEntry(archive, path: "_rels/.rels", content: rels)
		try addEntry(archive, path: "word/_rels/document.xml.rels", content: documentRels)
		try addEntry(archive, path: "word/document.xml", content: documentXML)
		try addEntry(archive, path: "word/styles.xml", content: stylesXML)
		try addEntry(archive, path: "word/numbering.xml", content: numberingXML)
		try addEntry(archive, path: "word/settings.xml", content: settingsXML)
		try addEntry(archive, path: "word/fontTable.xml", content: fontTableXML)

		// Embedded image media parts (word/media/imageN.ext).
		for media in mediaFiles {
			try addEntry(archive, path: media.path, data: media.data)
		}
	}

	// MARK: - Archive Helpers

	private func addEntry(_ archive: Archive, path: String, content: String) throws {
		try addEntry(archive, path: path, data: Data(content.utf8))
	}

	private func addEntry(_ archive: Archive, path: String, data: Data) throws {
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
		let orient = pageSetup.landscape ? "landscape" : "portrait"
		let m = pageSetup.margin
		xml += """
		<w:sectPr>
		<w:pgSz w:w="\(pageSetup.width)" w:h="\(pageSetup.height)" w:orient="\(orient)"/>
		<w:pgMar w:top="\(m)" w:right="\(m)" w:bottom="\(m)" w:left="\(m)" w:header="709" w:footer="709" w:gutter="0"/>
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

		case .table(let headers, let rows, let alignments):
			lastListType = nil
			return tableXML(headers: headers, rows: rows, alignments: alignments, quoteDepth: quoteDepth)

		case .image(let source, let alt):
			lastListType = nil
			return imageParagraph(source: source, alt: alt, quoteDepth: quoteDepth)
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

		// Build code paragraphs inside the table cell
		var paragraphs = ""
		for line in lines {
			let run = "<w:r><w:t xml:space=\"preserve\">\(xmlEscape(line))</w:t></w:r>"
			paragraphs += "<w:p><w:pPr><w:pStyle w:val=\"CodeBlock\"/></w:pPr>\(run)</w:p>\n"
		}

		// Single-cell table with cell margins for true inner padding
		let cellBorder = "w:val=\"single\" w:color=\"000000\" w:sz=\"2\" w:space=\"0\""
		let tblBorder = "w:val=\"single\" w:color=\"ffffff\" w:sz=\"8\" w:space=\"0\" w:shadow=\"0\" w:frame=\"0\""
		let indent = 108 + quoteDepth * 360
		let cellWidth = pageSetup.contentWidth - indent

		return """
		<w:tbl>
		<w:tblPr>
		<w:tblW w:w="\(cellWidth)" w:type="dxa"/>
		<w:jc w:val="left"/>
		<w:tblInd w:w="\(indent)" w:type="dxa"/>
		<w:tblBorders>
		<w:top \(tblBorder)/>
		<w:left \(tblBorder)/>
		<w:bottom \(tblBorder)/>
		<w:right \(tblBorder)/>
		<w:insideH \(tblBorder)/>
		<w:insideV \(tblBorder)/>
		</w:tblBorders>
		<w:tblLayout w:type="fixed"/>
		</w:tblPr>
		<w:tblGrid>
		<w:gridCol w:w="\(cellWidth)"/>
		</w:tblGrid>
		<w:tr>
		<w:tc>
		<w:tcPr>
		<w:tcW w:type="dxa" w:w="\(cellWidth)"/>
		<w:tcBorders>
		<w:top \(cellBorder)/>
		<w:left \(cellBorder)/>
		<w:bottom \(cellBorder)/>
		<w:right \(cellBorder)/>
		</w:tcBorders>
		<w:shd w:val="clear" w:color="auto" w:fill="f5f5f5"/>
		<w:tcMar>
		<w:top w:type="dxa" w:w="80"/>
		<w:left w:type="dxa" w:w="80"/>
		<w:bottom w:type="dxa" w:w="80"/>
		<w:right w:type="dxa" w:w="80"/>
		</w:tcMar>
		<w:vAlign w:val="top"/>
		</w:tcPr>
		\(paragraphs)
		</w:tc>
		</w:tr>
		</w:tbl>

		"""
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

	// MARK: - Image Rendering

	/// Renders a standalone image. Resolves `source` against ``baseURL``, reads the
	/// bytes + pixel dimensions, and emits an OOXML inline picture (`w:drawing` →
	/// `wp:inline` → `a:graphic` → `pic:pic` → `a:blip`). Registers the media part,
	/// its relationship, and its content-type as a side effect. Any failure (no
	/// `baseURL`, unreadable/remote file, unsupported format) degrades to the italic
	/// alt-text placeholder the inline renderer also uses.
	private func imageParagraph(source: String, alt: String, quoteDepth: Int) -> String {
		guard let baseURL,
			  let resolved = resolvedImageURL(source, baseURL: baseURL),
			  let data = try? Data(contentsOf: resolved), !data.isEmpty,
			  let (pixelWidth, pixelHeight) = ImageDimensions.dimensions(of: [UInt8](data)),
			  let format = imageFormat(path: resolved, data: data) else {
			return imagePlaceholderParagraph(alt: alt, quoteDepth: quoteDepth)
		}

		imageCounter += 1
		let n = imageCounter
		let target = "media/image\(n).\(format.ext)"
		let rId = "rImg\(n)"
		mediaFiles.append((path: "word/\(target)", data: data))
		imageRels.append((id: rId, target: target))
		imageContentDefaults[format.ext] = format.contentType

		// EMU sizing: natural pixels × 9525, capped to the content width (preserving
		// aspect ratio) so a large image doesn't overflow the page — mirrors Pages.
		let emuPerPixel = 9525
		let emuPerTwip = 635 // 914400 EMU/inch ÷ 1440 twips/inch
		var cx = pixelWidth * emuPerPixel
		var cy = pixelHeight * emuPerPixel
		let indentTwips = quoteDepth * 360
		let maxCx = max(0, pageSetup.contentWidth - indentTwips) * emuPerTwip
		if maxCx > 0, cx > maxCx {
			cy = Int((Double(cy) * Double(maxCx) / Double(cx)).rounded())
			cx = maxCx
		}

		let indentXML = quoteDepth > 0 ? "<w:ind w:left=\"\(indentTwips)\"/>" : ""
		let pPrXML = indentXML.isEmpty ? "" : "<w:pPr>\(indentXML)</w:pPr>"
		let descr = xmlEscape(alt)
		let drawing = """
		<w:drawing>\
		<wp:inline distT="0" distB="0" distL="0" distR="0">\
		<wp:extent cx="\(cx)" cy="\(cy)"/>\
		<wp:effectExtent l="0" t="0" r="0" b="0"/>\
		<wp:docPr id="\(n)" name="Picture \(n)" descr="\(descr)"/>\
		<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
		<a:graphic>\
		<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
		<pic:pic>\
		<pic:nvPicPr>\
		<pic:cNvPr id="\(n)" name="image\(n).\(format.ext)" descr="\(descr)"/>\
		<pic:cNvPicPr/>\
		</pic:nvPicPr>\
		<pic:blipFill>\
		<a:blip r:embed="\(rId)"/>\
		<a:stretch><a:fillRect/></a:stretch>\
		</pic:blipFill>\
		<pic:spPr>\
		<a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
		<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
		</pic:spPr>\
		</pic:pic>\
		</a:graphicData>\
		</a:graphic>\
		</wp:inline>\
		</w:drawing>
		"""
		return "<w:p>\(pPrXML)<w:r>\(drawing)</w:r></w:p>\n"
	}

	/// The italic alt-text fallback for an image that can't be embedded — identical
	/// to the placeholder the inline renderer emits for images mixed with text.
	private func imagePlaceholderParagraph(alt: String, quoteDepth: Int) -> String {
		let display = alt.isEmpty ? "[image]" : alt
		return paragraph(style: nil, runs: [Run(text: display, italic: true)], quoteDepth: quoteDepth)
	}

	/// Resolves a Markdown image source to a local file URL, or `nil` if it shouldn't
	/// be read from disk (remote/`data:` URLs degrade to the placeholder).
	private func resolvedImageURL(_ source: String, baseURL: URL) -> URL? {
		if let scheme = URL(string: source)?.scheme?.lowercased(),
		   scheme == "http" || scheme == "https" || scheme == "data" {
			return nil
		}
		if source.hasPrefix("/") {
			return URL(fileURLWithPath: source)
		}
		return baseURL.appendingPathComponent(source)
	}

	/// Determines the media extension + content type from the path, falling back to a
	/// magic-byte sniff. Only PNG and JPEG are supported (matching the dimension
	/// parser); anything else returns `nil` so the caller uses the placeholder.
	private func imageFormat(path: URL, data: Data) -> (ext: String, contentType: String)? {
		switch path.pathExtension.lowercased() {
		case "png": return ("png", "image/png")
		case "jpg": return ("jpg", "image/jpeg")
		case "jpeg": return ("jpeg", "image/jpeg")
		default: break
		}
		let head = [UInt8](data.prefix(4))
		if head.count >= 4, head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 {
			return ("png", "image/png")
		}
		if head.count >= 2, head[0] == 0xFF, head[1] == 0xD8 {
			return ("jpg", "image/jpeg")
		}
		return nil
	}

	// MARK: - Table Rendering

	private func tableXML(headers: [[Run]], rows: [[[Run]]], alignments: [ColumnAlignment], quoteDepth: Int) -> String {
		let columnCount = max(headers.count, rows.first?.count ?? 0)
		guard columnCount > 0 else { return "" }

		// Calculate column widths (evenly distributed)
		let indent = quoteDepth * 360
		let availableWidth = pageSetup.contentWidth - indent
		let colWidth = availableWidth / columnCount

		var xml = "<w:tbl>\n"

		// Table properties
		xml += "<w:tblPr>\n"
		xml += "<w:tblW w:w=\"\(availableWidth)\" w:type=\"dxa\"/>\n"
		if indent > 0 {
			xml += "<w:tblInd w:w=\"\(indent)\" w:type=\"dxa\"/>\n"
		}
		xml += "<w:tblBorders>\n"
		xml += "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>\n"
		xml += "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>\n"
		xml += "<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>\n"
		xml += "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>\n"
		xml += "<w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>\n"
		xml += "<w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>\n"
		xml += "</w:tblBorders>\n"
		xml += "<w:tblLayout w:type=\"fixed\"/>\n"
		xml += "</w:tblPr>\n"

		// Table grid
		xml += "<w:tblGrid>\n"
		for _ in 0..<columnCount {
			xml += "<w:gridCol w:w=\"\(colWidth)\"/>\n"
		}
		xml += "</w:tblGrid>\n"

		// Helper function to get alignment XML
		func alignmentXML(for index: Int) -> String {
			guard index < alignments.count else { return "" }
			switch alignments[index] {
			case .left: return ""
			case .center: return "<w:jc w:val=\"center\"/>"
			case .right: return "<w:jc w:val=\"right\"/>"
			}
		}

		// Header row
		xml += "<w:tr>\n"
		for (ci, cellRuns) in headers.enumerated() {
			xml += "<w:tc>\n"
			xml += "<w:tcPr>\n"
			xml += "<w:tcW w:w=\"\(colWidth)\" w:type=\"dxa\"/>\n"
			xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"DCDCDC\"/>\n"  // Header background
			xml += "</w:tcPr>\n"
			// Header cells force bold, but should still preserve inline styles
			// such as strikethrough from the source runs.
			let align = alignmentXML(for: ci)
			xml += "<w:p><w:pPr>\(align)</w:pPr>"
			xml += renderRuns(cellRuns, forceBold: true)
			xml += "</w:p>\n"
			xml += "</w:tc>\n"
		}
		xml += "</w:tr>\n"

		// Body rows
		for (ri, row) in rows.enumerated() {
			xml += "<w:tr>\n"
			let isEvenRow = ri % 2 == 1  // 0-indexed, so odd index = even row (2nd, 4th, etc.)
			for (ci, cellRuns) in row.enumerated() {
				xml += "<w:tc>\n"
				xml += "<w:tcPr>\n"
				xml += "<w:tcW w:w=\"\(colWidth)\" w:type=\"dxa\"/>\n"
				if isEvenRow {
					xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F9F9F9\"/>\n"  // Striped row
				}
				xml += "</w:tcPr>\n"
				let align = alignmentXML(for: ci)
				xml += "<w:p><w:pPr>\(align)</w:pPr>"
				xml += renderRuns(cellRuns)
				xml += "</w:p>\n"
				xml += "</w:tc>\n"
			}
			xml += "</w:tr>\n"
		}

		xml += "</w:tbl>\n"
		return xml
	}

	// MARK: - Run Rendering

	private func renderRuns(_ runs: [Run], forceBold: Bool = false) -> String {
		var xml = ""
		for run in runs {
			if let link = run.link {
				let rId = nextHyperlinkId(url: link)
				var rPr = "<w:rStyle w:val=\"Hyperlink\"/>"
				if run.bold || forceBold { rPr += "<w:b/><w:bCs/>" }
				if run.italic { rPr += "<w:i/><w:iCs/>" }
				if run.strike { rPr += "<w:strike/>" }
				xml += "<w:hyperlink r:id=\"\(rId)\"><w:r><w:rPr>\(rPr)</w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(run.text))</w:t></w:r></w:hyperlink>"
			} else {
				var rPr = ""
				if run.bold || forceBold { rPr += "<w:b/><w:bCs/>" }
				if run.italic { rPr += "<w:i/><w:iCs/>" }
				if run.strike { rPr += "<w:strike/>" }
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
		xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
		xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
		xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" \
		xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
		mc:Ignorable="w14">
		<w:body>
		\(body)
		</w:body>
		</w:document>
		"""
	}

	private func generateContentTypes() -> String {
		let imageDefaults = imageContentDefaults
			.sorted { $0.key < $1.key }
			.map { "<Default Extension=\"\($0.key)\" ContentType=\"\($0.value)\"/>" }
			.joined(separator: "\n")
		let imageDefaultsXML = imageDefaults.isEmpty ? "" : "\n\(imageDefaults)"
		return """
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
		<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
		<Default Extension="xml" ContentType="application/xml"/>\(imageDefaultsXML)
		<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
		<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
		<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
		<Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
		<Override PartName="/word/fontTable.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"/>
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
		<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
		<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable" Target="fontTable.xml"/>

		"""
		for link in hyperlinks {
			rels += "<Relationship Id=\"\(link.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xmlEscape(link.url))\" TargetMode=\"External\"/>\n"
		}
		for image in imageRels {
			rels += "<Relationship Id=\"\(image.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\(xmlEscape(image.target))\"/>\n"
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
		<w:u w:val="none" w:color="auto"/>
		<w:bdr w:val="nil"/>
		<w:vertAlign w:val="baseline"/>
		<w:lang w:val="en-US"/>
		</w:rPr></w:rPrDefault>
		<w:pPrDefault><w:pPr>
		<w:widowControl w:val="1"/>
		<w:pBdr>
		<w:top w:val="nil"/>
		<w:left w:val="nil"/>
		<w:bottom w:val="nil"/>
		<w:right w:val="nil"/>
		<w:between w:val="nil"/>
		<w:bar w:val="nil"/>
		</w:pBdr>
		<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>
		<w:ind w:left="0" w:right="0" w:firstLine="0"/>
		<w:jc w:val="left"/>
		</w:pPr></w:pPrDefault>
		</w:docDefaults>

		<w:style w:type="paragraph" w:default="1" w:styleId="Normal">
		<w:name w:val="Normal"/>
		<w:pPr>
		<w:spacing w:after="120" w:line="276" w:lineRule="auto"/>
		</w:pPr>
		<w:rPr>
		<w:sz w:val="22"/><w:szCs w:val="22"/>
		</w:rPr>
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
		<w:next w:val="CodeBlock"/>
		<w:pPr>
		<w:widowControl w:val="1"/>
		<w:shd w:val="clear" w:color="auto" w:fill="f5f5f5"/>
		<w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>
		<w:ind w:left="0" w:right="0" w:firstLine="0"/>
		<w:jc w:val="left"/>
		<w:outlineLvl w:val="9"/>
		</w:pPr>
		<w:rPr>
		<w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/>
		<w:b w:val="0"/><w:bCs w:val="0"/>
		<w:i w:val="0"/><w:iCs w:val="0"/>
		<w:color w:val="222222"/>
		<w:sz w:val="20"/><w:szCs w:val="20"/>
		<w:shd w:val="nil" w:color="auto" w:fill="auto"/>
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

	// MARK: - Settings

	private func generateSettings() -> String {
		"""
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
		<w:view w:val="print"/>
		<w:displayBackgroundShape/>
		<w:defaultTabStop w:val="720"/>
		<w:autoHyphenation w:val="0"/>
		<w:evenAndOddHeaders w:val="0"/>
		<w:compat>
		<w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/>
		</w:compat>
		</w:settings>
		"""
	}

	// MARK: - Font Table

	private func generateFontTable() -> String {
		"""
		<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
		<w:fonts xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
		<w:font w:name="Times New Roman">
		<w:charset w:val="00"/><w:family w:val="roman"/><w:pitch w:val="variable"/>
		</w:font>
		<w:font w:name="Helvetica Neue">
		<w:charset w:val="00"/><w:family w:val="swiss"/><w:pitch w:val="variable"/>
		</w:font>
		<w:font w:name="Courier New">
		<w:charset w:val="00"/><w:family w:val="modern"/><w:pitch w:val="fixed"/>
		</w:font>
		<w:font w:name="Arial">
		<w:charset w:val="00"/><w:family w:val="swiss"/><w:pitch w:val="variable"/>
		</w:font>
		</w:fonts>
		"""
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
