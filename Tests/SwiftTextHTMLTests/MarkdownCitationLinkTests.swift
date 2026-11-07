//  MarkdownCitationLinkTests.swift
//  SwiftTextHTMLTests
//
//  Heading ids, `{#id}` attributes, hand-placed anchors and clickable `[n]`
//  citations (issue #145), through HTML and through the WebKit PDF.

import Foundation
import Testing
@testable import SwiftTextHTML

@Suite("Markdown anchors and citations")
struct MarkdownCitationLinkTests {
	static let repro = """
	# Test

	Absatz mit Zitat [1](#q1) und [2](#q2).

	## Quellen

	<a id="q1"></a>
	- [1] Erste Quelle. https://example.org
	- <a id="q2"></a>[2] Zweite Quelle.

	## Zweite Überschrift {#zweite}
	"""

	@Test("Headings get unicode-preserving, de-duplicated slug ids")
	func headingSlugs() {
		let html = MarkdownToHTML.convert("# 2.7 Das Gehirn schützen\n\n## Quellen\n\n## Quellen", options: [.headingIDs])
		#expect(html.contains("<h1 id=\"27-das-gehirn-schützen\">2.7 Das Gehirn schützen</h1>"))
		#expect(html.contains("<h2 id=\"quellen\">Quellen</h2>"))
		#expect(html.contains("<h2 id=\"quellen-1\">Quellen</h2>"))
	}

	@Test("{#id} sets the heading id and is not rendered")
	func explicitHeadingID() {
		let html = MarkdownToHTML.convert(Self.repro, options: [.headingIDs, .passThroughRawHTML])
		#expect(html.contains("<h2 id=\"zweite\">Zweite Überschrift</h2>"))
		#expect(!html.contains("{#zweite}"))
	}

	@Test("Default output is unchanged")
	func defaultsUnchanged() {
		let html = MarkdownToHTML.convert("## Hi {#x}\n\n- [1] a\n\nSee [1].")
		#expect(html.contains("<h2>Hi {#x}</h2>"))
		#expect(!html.contains("ref-1"))
	}

	@Test("Numeric citations link to their reference items")
	func citations() {
		let html = MarkdownToHTML.convert(Self.repro, options: [.passThroughRawHTML, .linkCitations])
		#expect(html.contains("<a href=\"#ref-1\">[1]</a>"))
		#expect(html.contains("<a href=\"#ref-2\">[2]</a>"))
		#expect(html.contains("<li id=\"ref-1\">[1] Erste Quelle."))
		#expect(html.contains("<li id=\"ref-2\"><a id=\"q2\"></a>[2] Zweite Quelle.</li>"))
		#expect(html.contains("<a id=\"q1\"></a>"))

		let plain = MarkdownToHTML.convert("Text [3] and [1].\n\n- [1] First\n- [2] Second", options: [.linkCitations])
		#expect(plain.contains("[3] and <a href=\"#ref-1\">[1]</a>."))
		#expect(!plain.contains("href=\"#ref-3\""))
		#expect(plain.contains("<li id=\"ref-1\">[1] First</li>"))
	}

	#if os(macOS)
	@Test("WebKit PDF writes fragment links as internal destinations", .timeLimit(.minutes(2)))
	@MainActor
	func pdfInternalDestinations() async throws {
		let size = CGSize(width: 595.28, height: 841.89)
		let html = MarkdownToHTML.document(Self.repro, options: [.passThroughRawHTML, .linkCitations, .headingIDs])
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("test.html")
		try html.write(to: file, atomically: true, encoding: .utf8)

		let browser = WebKitBrowser(fileURL: file, readAccessRoot: directory)
		browser.frameSize = size
		browser.preserveFrameHeight = true
		await browser.waitForLoadCompletion()
		let data = try await browser.exportPaginatedPDFData(paperSize: size)

		let raw = String(decoding: data, as: UTF8.self)
		#expect(raw.contains("/GoTo") || raw.contains("/Dest"))
		#expect(!raw.contains("file://"))
	}
	#endif
}
