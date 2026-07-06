//  EpubTests.swift
//  SwiftTextEPUBTests

import Foundation
import Testing
@testable import SwiftTextEPUB

@Suite("Markdown → EPUB")
struct EpubTests {

	// A minimal valid 1×1 PNG, for cover tests.
	static let onePixelPNG = Data(base64Encoded:
		"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==")!

	// MARK: - OCF container

	@Test("mimetype is the first entry, stored, with the exact media type")
	func mimetypeFirst() {
		let files = MarkdownToEpub.makeFiles("# Chapter\n\nBody.", metadata: fixedMetadata(), options: EpubOptions())
		let first = files.first
		#expect(first?.path == "mimetype")
		#expect(first?.compression == .stored)
		#expect(string(first) == "application/epub+zip")
	}

	@Test("the built archive puts mimetype first and stored (byte level)")
	func archiveMimetypeBytes() throws {
		let data = try MarkdownToEpub.makeData("# Chapter\n\nBody.", metadata: fixedMetadata(), options: EpubOptions())
		let bytes = [UInt8](data)
		// Local file header signature "PK\x03\x04".
		#expect(Array(bytes[0..<4]) == [0x50, 0x4B, 0x03, 0x04])
		// Compression method (offset 8, little-endian) == 0 (stored).
		#expect(UInt16(bytes[8]) | UInt16(bytes[9]) << 8 == 0)
		let nameLen = Int(UInt16(bytes[26]) | UInt16(bytes[27]) << 8)
		let extraLen = Int(UInt16(bytes[28]) | UInt16(bytes[29]) << 8)
		let name = String(decoding: bytes[30 ..< 30 + nameLen], as: UTF8.self)
		#expect(name == "mimetype")
		let payloadStart = 30 + nameLen + extraLen
		let payload = String(decoding: bytes[payloadStart ..< payloadStart + 20], as: UTF8.self)
		#expect(payload == "application/epub+zip")
	}

	@Test("container.xml points at the package document")
	func containerXML() {
		let files = MarkdownToEpub.makeFiles("# A\n\nx", metadata: fixedMetadata(), options: EpubOptions())
		let container = string(file(files, "META-INF/container.xml"))
		expectWellFormedXML(container, "container.xml")
		#expect(container.contains("full-path=\"OEBPS/content.opf\""))
		#expect(container.contains("media-type=\"application/oebps-package+xml\""))
	}

	// MARK: - Package document

	@Test("OPF carries the Dublin Core metadata")
	func opfMetadata() {
		let metadata = fixedMetadata(title: "The Book", authors: ["Jane Doe", "John Roe"], language: "de")
		let files = MarkdownToEpub.makeFiles("# One\n\nx", metadata: metadata, options: EpubOptions())
		let opf = string(file(files, "OEBPS/content.opf"))
		expectWellFormedXML(opf, "content.opf")
		#expect(opf.contains("<dc:title>The Book</dc:title>"))
		#expect(opf.contains("<dc:language>de</dc:language>"))
		#expect(opf.contains("<dc:creator id=\"creator-1\">Jane Doe</dc:creator>"))
		#expect(opf.contains("<dc:creator id=\"creator-2\">John Roe</dc:creator>"))
		#expect(opf.contains("scheme=\"marc:relators\">aut</meta>"))
		#expect(opf.contains("<dc:identifier id=\"pub-id\">urn:uuid:00000000-0000-0000-0000-000000000000</dc:identifier>"))
		#expect(opf.contains("<meta property=\"dcterms:modified\">2023-11-14T22:13:20Z</meta>"))
		#expect(opf.contains("unique-identifier=\"pub-id\""))
	}

	@Test("metadata with XML-special characters is escaped")
	func metadataEscaping() {
		let metadata = fixedMetadata(title: "Tom & Jerry <3", authors: ["A \"Quote\" Smith"])
		let files = MarkdownToEpub.makeFiles("# One\n\nx", metadata: metadata, options: EpubOptions())
		let opf = string(file(files, "OEBPS/content.opf"))
		expectWellFormedXML(opf, "content.opf with specials")
		#expect(opf.contains("Tom &amp; Jerry &lt;3"))
	}

	// MARK: - Chapter splitting

	@Test("splits into one file per heading at the chosen level")
	func splitsAtLevel() {
		let markdown = "# One\n\naa\n\n# Two\n\nbb\n\n# Three\n\ncc"
		let files = MarkdownToEpub.makeFiles(markdown, metadata: fixedMetadata(), options: EpubOptions(chapterLevel: 1))
		let chapterFiles = files.filter { $0.path.hasPrefix("OEBPS/text/ch") }
		#expect(chapterFiles.count == 3)
		let nav = string(file(files, "OEBPS/nav.xhtml"))
		#expect(nav.contains(">One</a>"))
		#expect(nav.contains(">Two</a>"))
		#expect(nav.contains(">Three</a>"))
	}

	@Test("a chapter's leading headings are combined into its title")
	func combinedTitles() {
		let markdown = "# Book\n\n## 1\n\n### The Birthday\n\nprose\n\n## 2\n\n### The Journey\n\nprose"
		let files = MarkdownToEpub.makeFiles(markdown, metadata: fixedMetadata(), options: EpubOptions(chapterLevel: 2))
		let nav = string(file(files, "OEBPS/nav.xhtml"))
		#expect(nav.contains("1: The Birthday"))
		#expect(nav.contains("2: The Journey"))
	}

	@Test("content before the first chapter heading becomes front matter, kept out of the TOC")
	func frontMatter() {
		let markdown = "# Book Title\n\n*subtitle*\n\n> epigraph\n\n## Chapter One\n\nprose"
		let files = MarkdownToEpub.makeFiles(markdown, metadata: fixedMetadata(), options: EpubOptions(chapterLevel: 2))
		let nav = string(file(files, "OEBPS/nav.xhtml"))
		// The front-matter section holds the leading material…
		let front = string(file(files, "OEBPS/text/ch001.xhtml"))
		#expect(front.contains("epub:type=\"frontmatter\""))
		#expect(front.contains("epigraph"))
		// …but only the real chapter appears in the reading-order TOC.
		#expect(nav.contains(">Chapter One</a>"))
		#expect(!nav.contains("epigraph"))
		let ncx = string(file(files, "OEBPS/toc.ncx"))
		#expect(ncx.components(separatedBy: "<navPoint").count - 1 == 1)
	}

	@Test("a document with no headings still yields one navigable chapter")
	func noHeadings() {
		let files = MarkdownToEpub.makeFiles("Just a paragraph.\n\nAnd another.", metadata: fixedMetadata(title: "Solo"), options: EpubOptions())
		let nav = string(file(files, "OEBPS/nav.xhtml"))
		expectWellFormedXML(nav, "nav.xhtml")
		#expect(nav.contains(">Solo</a>"))
		#expect(file(files, "OEBPS/text/ch001.xhtml") != nil)
	}

	// MARK: - Content documents

	@Test("chapter bodies are well-formed XHTML with self-closed void elements")
	func chapterXHTMLWellFormed() {
		let markdown = "# Chapter\n\nA line.\n\n---\n\nAfter a scene break.\n\nHard\\\nbreak."
		let files = MarkdownToEpub.makeFiles(markdown, metadata: fixedMetadata(), options: EpubOptions())
		let chapter = string(file(files, "OEBPS/text/ch001.xhtml"))
		expectWellFormedXML(chapter, "chapter")
		#expect(chapter.contains("<hr />"))
		#expect(chapter.contains("<br />"))
	}

	@Test("a code block with special characters in its info string stays well-formed")
	func codeBlockLanguageStaysWellFormed() {
		let markdown = "# Chapter\n\n```xml&<\"bad\n<tag/>\n```\n"
		let files = MarkdownToEpub.makeFiles(markdown, metadata: fixedMetadata(), options: EpubOptions())
		expectWellFormedXML(string(file(files, "OEBPS/text/ch001.xhtml")), "chapter with special code language")
	}

	@Test("every generated XML/XHTML document is well-formed")
	func everythingWellFormed() {
		let markdown = "# One\n\ntext with <angle> & ampersand\n\n## Sub\n\n```c++\nx < y && a\n```\n\n# Two\n\nx"
		let files = MarkdownToEpub.makeFiles(markdown, metadata: fixedMetadata(coverImage: Self.onePixelPNG, coverImageFilename: "c.png"), options: EpubOptions(chapterLevel: 1))
		for file in files where file.path.hasSuffix(".xhtml") || file.path.hasSuffix(".opf") || file.path.hasSuffix(".ncx") || file.path.hasSuffix(".xml") {
			expectWellFormedXML(String(decoding: file.data, as: UTF8.self), file.path)
		}
	}

	// MARK: - Cover

	@Test("a cover image is embedded and wired into the manifest and spine")
	func coverEmbedded() {
		let files = MarkdownToEpub.makeFiles("# A\n\nx", metadata: fixedMetadata(coverImage: Self.onePixelPNG, coverImageFilename: "cover.png"), options: EpubOptions())
		// Image bytes stored (already compressed), correct media type.
		let image = file(files, "OEBPS/images/cover.png")
		#expect(image?.compression == .stored)
		let opf = string(file(files, "OEBPS/content.opf"))
		#expect(opf.contains("media-type=\"image/png\""))
		#expect(opf.contains("properties=\"cover-image\""))
		#expect(opf.contains("<itemref idref=\"cover\" linear=\"no\"/>"))
		let coverPage = string(file(files, "OEBPS/text/cover.xhtml"))
		expectWellFormedXML(coverPage, "cover.xhtml")
		// 1×1 PNG → dimensions known → SVG wrapper.
		#expect(coverPage.contains("<svg"))
		#expect(coverPage.contains("viewBox=\"0 0 1 1\""))
		#expect(opf.contains("<meta name=\"cover\" content=\"cover-image\"/>"))
	}

	@Test("no cover means no cover files or spine entry")
	func noCover() {
		let files = MarkdownToEpub.makeFiles("# A\n\nx", metadata: fixedMetadata(), options: EpubOptions())
		#expect(!files.contains { $0.path == "OEBPS/text/cover.xhtml" })
		#expect(!files.contains { $0.path.hasPrefix("OEBPS/images/") })
		let opf = string(file(files, "OEBPS/content.opf"))
		#expect(!opf.contains("cover-image"))
	}

	// MARK: - Stylesheet

	@Test("user CSS is appended after the default stylesheet")
	func userCSSAppended() {
		let css = "p { color: rebeccapurple; }"
		let files = MarkdownToEpub.makeFiles("# A\n\nx", metadata: fixedMetadata(), options: EpubOptions(userCSS: css))
		let stylesheet = string(file(files, "OEBPS/styles/stylesheet.css"))
		#expect(stylesheet.contains("SwiftText EPUB base stylesheet"))
		#expect(stylesheet.contains("rebeccapurple"))
		// Appended after (so author rules win on equal specificity).
		let defaultIndex = stylesheet.range(of: "base stylesheet")!.lowerBound
		let userIndex = stylesheet.range(of: "rebeccapurple")!.lowerBound
		#expect(defaultIndex < userIndex)
	}

	// MARK: - Determinism

	@Test("the same input and metadata produce byte-identical archives")
	func deterministic() throws {
		let markdown = "# One\n\naa\n\n# Two\n\nbb"
		let metadata = fixedMetadata(coverImage: Self.onePixelPNG, coverImageFilename: "c.png")
		let a = try MarkdownToEpub.makeData(markdown, metadata: metadata, options: EpubOptions())
		let b = try MarkdownToEpub.makeData(markdown, metadata: metadata, options: EpubOptions())
		#expect(a == b)
	}
}
