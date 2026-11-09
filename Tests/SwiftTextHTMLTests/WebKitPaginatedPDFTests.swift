//  WebKitPaginatedPDFTests.swift
//  SwiftTextHTMLTests
//
//  Paginated PDF export goes through the platform print pipeline —
//  `NSPrintOperation` on macOS, `UIPrintPageRenderer` on iOS. Both are APIs onto
//  the same WebKit paginator, and this suite is what holds them to that: the
//  expectations below are not per-platform.

#if os(macOS) || os(iOS)
import Foundation
import PDFKit
import Testing
@testable import SwiftTextHTML

@Suite("WebKit integration", .serialized)
@MainActor
struct WebKitIntegrationTests {
	private let a4 = CGSize(width: 595.28, height: 841.89)
	private static var isWarmedUp = false

	private func paginate(_ html: String) async throws -> PDFDocument {
		// The first web view of the run pays for launching the web content
		// process. Spend that on a trivial page rather than on a test's fixture.
		if !Self.isWarmedUp {
			Self.isWarmedUp = true
			_ = try? await exportPaginated("<html><body>x</body></html>")
		}
		return try #require(PDFDocument(data: try await exportPaginated(html)), "the export produced no readable PDF")
	}

	private func exportPaginated(_ html: String) async throws -> Data {
		let browser = WebKitBrowser(htmlString: html)
		// The default commit watchdog retries a navigation that has not committed
		// after 15 s once on a fresh web view, within this same budget.
		browser.timeout = 30
		browser.frameSize = a4
		// Let WebKit paginate rather than stretching the frame to the content.
		browser.preserveFrameHeight = true
		return try await browser.exportPaginatedPDFData(paperSize: a4)
	}

	/// The first page's media box in millimetres, for a page of `@page { size }` taken from `css`.
	private func firstPageMillimetres(css: String) async throws -> (width: Int, height: Int) {
		let size = try #require(PageSizeRule.pointSize(in: css), "no @page size found in \(css)")
		let browser = WebKitBrowser(htmlString: "<html><head><style>\(css)</style></head><body><h1>Eins</h1><p>Text.</p></body></html>")
		browser.timeout = 30
		browser.frameSize = CGSize(width: size.width, height: size.height)
		browser.preserveFrameHeight = true
		let data = try await browser.exportPaginatedPDFData(paperSize: CGSize(width: size.width, height: size.height))
		let box = try #require(PDFDocument(data: data)?.page(at: 0)?.bounds(for: .mediaBox))
		return (Int((box.width / 72 * 25.4).rounded()), Int((box.height / 72 * 25.4).rounded()))
	}

	@Test("@page size sets the paper size: named, two lengths, landscape", .timeLimit(.minutes(1)))
	func pageSizeFromCSS() async throws {
		let a5 = try await firstPageMillimetres(css: "@page { size: A5; }")
		#expect(a5 == (148, 210))
		let trim = try await firstPageMillimetres(css: "@page { size: 170mm 240mm; }")
		#expect(trim == (170, 240))
		let landscape = try await firstPageMillimetres(css: "@page { size: A4 landscape; }")
		#expect(landscape == (297, 210))
	}

	@Test("PageSizeRule reads the last size, ignores comments, and returns nil without one")
	func pageSizeParsing() {
		let letter = PageSizeRule.pointSize(in: "@page { size: letter; }")
		#expect(letter?.width == 612 || abs((letter?.width ?? 0) - 612.2) < 0.5)
		#expect(PageSizeRule.pointSize(in: "/* @page { size: A5 } */ body { margin: 0 }") == nil)
		let last = PageSizeRule.pointSize(in: "@page { size: A5 } @page { margin: 1cm; size: 5in 8in }")
		#expect(last?.width == 360 && last?.height == 576)
		#expect(PageSizeRule.pointSize(in: "@page { size: bogus }") == nil)
		let nested = PageSizeRule.pointSize(in: "@page { @top-center { content: \"T\"; } size: 5in 8in }")
		#expect(nested?.width == 360 && nested?.height == 576)
		let fallback = (width: 595.0, height: 842.0)
		let landscape = PageSizeRule.pointSize(in: "@page { size: landscape }", fallback: fallback)
		#expect(landscape?.width == 842 && landscape?.height == 595)
		let portrait = PageSizeRule.pointSize(in: "@page { size: portrait }", fallback: fallback)
		#expect(portrait?.width == 595 && portrait?.height == 842)
		#expect(PageSizeRule.pointSize(in: "@page { size: landscape }") == nil)
	}

	private func pageHeads(_ document: PDFDocument) -> [String] {
		(0..<document.pageCount).map { index in
			document.page(at: index)?.string?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "<blank>"
		}
	}

	private func chapters(_ rule: String) -> String {
		"""
		<html><head><style>h1 { \(rule) }</style></head><body>
		<h1>Eins</h1><p>Text eins.</p><h1>Zwei</h1><p>Text zwei.</p><h1>Drei</h1><p>Text drei.</p>
		</body></html>
		"""
	}

	@available(iOS 16.0, *)
	@Test("break-before: right starts each chapter on an odd page with blank pages between", .timeLimit(.minutes(1)))
	func breakBeforeRight() async throws {
		let document = try await paginate(chapters("break-before: right;"))
		#expect(pageHeads(document) == ["Eins", "<blank>", "Zwei", "<blank>", "Drei"])
	}

	@available(iOS 16.0, *)
	@Test("break-before: left puts the first chapter on page 2", .timeLimit(.minutes(1)))
	func breakBeforeLeft() async throws {
		let document = try await paginate(chapters("break-before: left;"))
		#expect(pageHeads(document) == ["<blank>", "Eins", "<blank>", "Zwei", "<blank>", "Drei"])
	}

	@available(iOS 16.0, *)
	@Test("recto and verso are the same as right and left", .timeLimit(.minutes(1)))
	func rectoAndVerso() async throws {
		#expect(pageHeads(try await paginate(chapters("break-before: recto;"))) == ["Eins", "<blank>", "Zwei", "<blank>", "Drei"])
		#expect(pageHeads(try await paginate(chapters("break-before: verso;"))) == ["<blank>", "Eins", "<blank>", "Zwei", "<blank>", "Drei"])
	}

	@available(iOS 16.0, *)
	@Test("break-before: page on the first block opens no blank page", .timeLimit(.minutes(1)))
	func leadingBreakAddsNoBlankPage() async throws {
		#expect(pageHeads(try await paginate(chapters("break-before: page;"))) == ["Eins", "Zwei", "Drei"])
	}

	/// Forced breaks are the reason this path exists at all: `exportPDFData`
	/// would emit one continuous page regardless of the CSS.
	@available(iOS 16.0, *)
	@Test("Forced page breaks are honoured", .timeLimit(.minutes(1)))
	func forcedPageBreaks() async throws {
		let html = """
		<html><head><style>h1 { page-break-before: always; }</style></head>
		<body>
		<h1>Alpha</h1><p>First.</p>
		<h1>Beta</h1><p>Second.</p>
		<h1>Gamma</h1><p>Third.</p>
		</body></html>
		"""
		// Three: a break with nothing above it does not open a blank first page.
		#expect(try await paginate(html).pageCount == 3)
	}

	/// The same document without the rule stays on one page, so the count above
	/// is the CSS being honoured rather than the content simply overflowing.
	@available(iOS 16.0, *)
	@Test("Without the rule the same content is a single page", .timeLimit(.minutes(1)))
	func withoutForcedBreaks() async throws {
		let html = """
		<html><body>
		<h1>Alpha</h1><p>First.</p>
		<h1>Beta</h1><p>Second.</p>
		<h1>Gamma</h1><p>Third.</p>
		</body></html>
		"""
		#expect(try await paginate(html).pageCount == 1)
	}

	/// Natural overflow paginates too — measured at 7 pages on both macOS and the
	/// iOS Simulator. The assertion stays loose because that number rides on
	/// default text metrics, which move between OS releases; the parity claim is
	/// carried by the forced-break case above, where the layout is pinned by CSS.
	@available(iOS 16.0, *)
	@Test("Content that overflows the page is split", .timeLimit(.minutes(2)))
	func naturalOverflow() async throws {
		let paragraphs = (1 ... 200).map { "<p>Paragraph number \($0) of the overflow fixture.</p>" }.joined()
		let document = try await paginate("<html><body>\(paragraphs)</body></html>")
		#expect(document.pageCount > 1)
		// The first page must carry real content — a paginator that emits blank
		// pages would still satisfy a bare count check.
		#expect(document.page(at: 0)?.string?.contains("Paragraph number 1") == true)
	}

	@Test("Spaced table fragments preserve captions, headers, and rows", .timeLimit(.minutes(2)))
	func tablePagination() async throws {
		let rows = (1 ... 50).map {
			let marker = String(format: "%02d", $0)
			return "<tr><td>row-marker-\(marker)</td><td>value-marker-\(marker)</td></tr>"
		}.joined()
		let html = """
		<html><head><style>
		@page { size: A4; margin: 2cm; }
		body { margin: 0; font: 16px sans-serif; }
		h2 { break-before: page; }
		table { border-spacing: 0 12px; border: 4px solid #555; }
		th, td { border: 1px solid #999; padding: 8px 12px; }
		</style></head><body>
		<p>Content before the forced break.</p>
		<h2>Forced page heading</h2>
		<table><caption>Preserved table caption</caption>
		<thead><tr><th>Label</th><th>Value</th></tr></thead>
		<tbody>\(rows)</tbody></table>
		</body></html>
		"""
		let document = try await paginate(html)
		#expect(document.pageCount > 1)
		let pageTexts = (0 ..< document.pageCount).map { document.page(at: $0)?.string ?? "" }
		let tablePageTexts = pageTexts.filter { $0.contains("row-marker-") }
		#expect(tablePageTexts.count > 1)
		let headingPage = try #require(pageTexts.firstIndex { $0.contains("Forced page heading") })
		#expect(pageTexts[headingPage].contains("row-marker-01"),
		        "the table was moved off the page established by the preceding forced break")
		for (index, text) in tablePageTexts.enumerated() {
			#expect(text.contains("Label"), "table page \(index + 1) has no repeated table header")
			#expect(text.contains("Value"), "table page \(index + 1) has no repeated table header")
		}
		#expect(pageTexts.filter { $0.contains("Preserved table caption") }.count == 1)
		for rowNumber in 1 ... 50 {
			let marker = String(format: "%02d", rowNumber)
			let containingPages = pageTexts.filter {
				$0.contains("row-marker-\(marker)") && $0.contains("value-marker-\(marker)")
			}
			#expect(containingPages.count == 1, "row \(rowNumber) was split or lost")
		}
	}

	@Test("A table shorter than one page is split when it straddles a page", .timeLimit(.minutes(2)))
	func shortStraddlingTable() async throws {
		let rows = (1 ... 12).map { "<tr><td>short-row-\($0)</td><td>short-value-\($0)</td></tr>" }.joined()
		let html = """
		<html><head><style>
		@page { size: A4; margin: 2cm; }
		body { margin: 0; font: 16px sans-serif; }
		table { border-collapse: collapse; }
		th, td { border: 1px solid #999; padding: 8px 12px; }
		</style></head><body>
		<div style="height: 650px">Filler</div>
		<table><thead><tr><th>Label</th><th>Value</th></tr></thead>
		<tbody>\(rows)</tbody></table>
		</body></html>
		"""
		let document = try await paginate(html)
		let tablePages = (0 ..< document.pageCount)
			.compactMap { document.page(at: $0)?.string }
			.filter { $0.contains("short-row-") }
		#expect(tablePages.count == 2)
		#expect(tablePages.allSatisfy { $0.contains("Label") && $0.contains("Value") })
	}

	@Test("Long Markdown tables use the space after introductory paragraphs", .timeLimit(.minutes(2)), arguments: [0, 80])
	func longTableAfterIntroduction(paragraphHeight: Int) async throws {
		let rows = (1 ... 40).map {
			let marker = String(format: "%02d", $0)
			return "| \(marker) | row-start-\(marker)<br>row-end-\(marker) | | |"
		}.joined(separator: "\n")
		let markdown = """
		# Fragebogen

		Ein kurzer Einleitungsabsatz.

		Noch ein Absatz.

		| Nr. | Frage | Ja | Nein |
		|---|---|---|---|
		\(rows)
		"""
		let stylesheet = """
		\(MarkdownToHTML.defaultStylesheet)
		@page { size: A4; margin: 2cm; }
		*, *::before, *::after { box-sizing: border-box; }
		@media print { body { max-width: none; padding: 0; margin: 0; } }
		h1 { break-after: avoid; break-inside: avoid; }
		p { min-height: \(paragraphHeight)px; orphans: 2; widows: 2; }
		thead { display: table-header-group; }
		tr { page-break-inside: avoid; break-inside: avoid; }
		"""
		let html = MarkdownToHTML.document(markdown, stylesheet: stylesheet, options: [.passThroughRawHTML])
		let document = try await paginate(html)
		#expect(document.pageCount > 1)
		let pageTexts = (0 ..< document.pageCount).map { document.page(at: $0)?.string ?? "" }
		#expect(pageTexts[0].contains("Fragebogen"))
		#expect(pageTexts[0].contains("row-start-01"), "the first page has room for table rows")
		for text in pageTexts {
			#expect(text.contains("row-start-"), "a page was left without table rows")
			#expect(text.contains("Frage") && text.contains("Nein"), "a table page has no repeated header")
		}
		for rowNumber in 1 ... 40 {
			let marker = String(format: "%02d", rowNumber)
			#expect(pageTexts.filter { $0.contains("row-start-\(marker)") }.count == 1)
			#expect(pageTexts.filter { $0.contains("row-end-\(marker)") }.count == 1)
			#expect(pageTexts.contains { $0.contains("row-start-\(marker)") && $0.contains("row-end-\(marker)") },
			        "row \(rowNumber) was split across pages")
		}
	}

	@Test("Long tables use a safe boundary after avoid-break content beyond page one", .timeLimit(.minutes(2)))
	func longTableAfterAvoidBreakContent() async throws {
		let rows = (1 ... 40).map {
			let marker = String(format: "%02d", $0)
			return "<tr><td>safe-row-start-\(marker)<br>safe-row-end-\(marker)</td></tr>"
		}.joined()
		let html = """
		<html><head><style>
		@page { size: A4; margin: 2cm; }
		body { margin: 0; font: 16px sans-serif; }
		table { border-collapse: collapse; }
		th, td { border: 1px solid #999; padding: 8px 12px; }
		</style></head><body>
		<div style="height: 300px">Content before the avoid-break block.</div>
		<div style="height: 650px; break-inside: avoid">Avoid-break tail.</div>
		<table><thead><tr><th>Safe header</th></tr></thead><tbody>\(rows)</tbody></table>
		</body></html>
		"""
		let document = try await paginate(html)
		let pageTexts = (0 ..< document.pageCount).map { document.page(at: $0)?.string ?? "" }
		let firstTablePage = try #require(pageTexts.firstIndex { $0.contains("safe-row-start-") })
		#expect(!pageTexts[firstTablePage].contains("Avoid-break tail"),
		        "the table needs a reliable boundary when the paginated offset may be underestimated")
		for text in pageTexts where text.contains("safe-row-start-") {
			#expect(text.contains("Safe header"), "a table page has no repeated header")
		}
		for rowNumber in 1 ... 40 {
			let marker = String(format: "%02d", rowNumber)
			#expect(pageTexts.contains { $0.contains("safe-row-start-\(marker)") && $0.contains("safe-row-end-\(marker)") },
			        "row \(rowNumber) was split across pages")
		}
	}

	@Test("Table fragments keep headers when the table starts late on a page", .timeLimit(.minutes(2)))
	func tableStartingLateOnPage() async throws {
		let rows = (1 ... 45).map {
			"| \($0) | research/very/long/path/segment-\($0)/identifier-that-cannot-wrap-\($0).md | \($0 * 7) |"
		}.joined(separator: "\n")
		let longToken = String(repeating: "A", count: 200)
		let longURL = "https://example.com/" + (1 ... 24).map { "segment\($0)" }.joined(separator: "/")
			+ "/final.html"
		let fifteenHeaders = (1 ... 15).map { "Col\($0)" }.joined(separator: " | ")
		let fifteenDividers = Array(repeating: "---", count: 15).joined(separator: "|")
		let fifteenValues = (1 ... 15).map { "v1\($0)" }.joined(separator: " | ")
		let fifteenMoreValues = (1 ... 15).map { "v2\($0)" }.joined(separator: " | ")
		let eightHeaders = (1 ... 8).map { "VeryLongHeaderName\($0)" }.joined(separator: " | ")
		let eightDividers = Array(repeating: "---", count: 8).joined(separator: "|")
		let eightValues = Array(repeating: "x", count: 8).joined(separator: " | ")
		let filler = (1 ... 8).map { "Filler paragraph \($0) before the long table." }.joined(separator: "\n\n")
		let markdown = """
		# Prüfblatt Tabellen

		## 1 Langer Token neben kurzer Spalte (war: Spaltenkollaps)

		| Key | Value |
		|---|---|
		| Long | \(longToken) |
		| Short | ok |

		## 2 Lange URL (war: rechter Rahmen abgeschnitten)

		| Key | Value |
		|---|---|
		| Link | \(longURL) |
		| Short | ok |

		## 3 Fünfzehn Spalten

		| \(fifteenHeaders) |
		|\(fifteenDividers)|
		| \(fifteenValues) |
		| \(fifteenMoreValues) |

		## 4 Acht lange Kopfzeilennamen

		| \(eightHeaders) |
		|\(eightDividers)|
		| \(eightValues) |

		\(filler)

		## 5 Tabelle über Seitenumbruch (war: Kopf verwaist, Phantomzeile)

		| ID | Path | N |
		|---:|---|---:|
		\(rows)
		"""
		let stylesheet = """
		\(MarkdownToHTML.defaultStylesheet)
		@page { size: A4; margin: 2cm; }
		*, *::before, *::after { box-sizing: border-box; }
		@media print { body { max-width: none; padding: 0; margin: 0; } }
		h1, h2 { break-after: avoid; break-inside: avoid; }
		thead { display: table-header-group; }
		tr { page-break-inside: avoid; break-inside: avoid; }
		"""
		let html = MarkdownToHTML.document(markdown, stylesheet: stylesheet)
		let document = try await paginate(html)
		let tablePages = (0 ..< document.pageCount)
			.compactMap { document.page(at: $0)?.string }
			.filter { $0.contains("segment-") }
		let rowCounts = tablePages.map { $0.components(separatedBy: "segment-").count - 1 }
		#expect(rowCounts.first.map { $0 >= 10 } == true, "the first table page is mostly empty")
		for (index, text) in tablePages.enumerated() {
			#expect(text.contains("Path"), "table page \(index + 1) has no path header")
		}
	}

	/// #242: WebKit's print shrink made text 16/15 too large; a CSS size must print at that size.
	@Test("CSS font sizes print at their CSS size", .timeLimit(.minutes(3)), arguments: [("10pt", 10.0), ("12.5pt", 12.5), ("16px", 12.0), ("1.25em", 15.0)])
	func fontSizeMatchesCSS(size: String, points: Double) async throws {
		let html = """
		<!DOCTYPE html><html><head><meta charset="utf-8">
		<style>@page { size: A4; margin: 72pt }
		body { margin: 0; font-family: Helvetica; font-size: \(size); }
		html { font-size: 12pt; }</style></head>
		<body><p>Absatz</p></body></html>
		"""
		let document = try await paginate(html)
		let match = try #require(document.findString("Absatz", withOptions: []).first)
		let page = try #require(match.pages.first)
		let bounds = match.bounds(for: page)
		let font = CTFontCreateWithName("Helvetica" as CFString, points, nil)
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Absatz", attributes: [.font: font]))
		let expected = CTLineGetTypographicBounds(line, nil, nil, nil)
		#expect(abs(bounds.width - expected) / expected < 0.02, "width \(bounds.width) vs \(expected) for \(size)")
		#expect(abs(bounds.minX - 72) < 3, "left margin moved: \(bounds.minX)")
	}

	/// #140: an over-wide table must not make WebKit's horizontal fit scale the
	/// whole document down; only the table is constrained to the page.
	@Test("A wide table does not shrink the surrounding text", .timeLimit(.minutes(3)))
	func wideTableKeepsTextSize() async throws {
		let paragraph = String(repeating: "Dies ist ein Absatz mit genügend Text, damit das Dokument mehrere Seiten lang wird. ", count: 8)
			.trimmingCharacters(in: .whitespaces) + "\n\n"
		let headers = ["Datum", "Madopar genommen um", "Beweglichkeit vormittags (1 bis 5)", "nachmittags (1 bis 5)",
			"abends (1 bis 5)", "Blutdruck liegend / stehend", "Schwindel beim Aufstehen (ja/nein)",
			"Schlaf (gut/mittel/schlecht)", "Training (was, wie lang)", "Bemerkungen"]
		let row = "| " + headers.map { _ in "" }.joined(separator: " | ") + " |\n"
		let table = "| " + headers.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 10) + "\n"
			+ String(repeating: row, count: 5)
		let narrow = "# Test\n\n" + String(repeating: paragraph, count: 25)
		let wide = "# Test\n\n" + String(repeating: paragraph, count: 20) + table + "\n" + String(repeating: paragraph, count: 5)

		func html(_ markdown: String) -> String {
			"""
			<!DOCTYPE html><html><head><meta charset="utf-8">
			<style>@page { size: A4 portrait; margin: 0; }
			\(MarkdownToHTML.defaultStylesheet)
			body { max-width: none; margin: 0; padding: 40px; }</style></head>
			<body>\(MarkdownToHTML.convert(markdown))</body></html>
			"""
		}
		func wordWidth(_ document: PDFDocument, _ word: String) throws -> CGFloat {
			let match = try #require(document.findString(word, withOptions: []).first)
			let page = try #require(match.pages.first)
			return match.bounds(for: page).width
		}

		let narrowDoc = try await paginate(html(narrow))
		let wideDoc = try await paginate(html(wide))

		let narrowWidth = try wordWidth(narrowDoc, "Absatz")
		let wideWidth = try wordWidth(wideDoc, "Absatz")
		#expect(abs(wideWidth - narrowWidth) / narrowWidth < 0.03, "body text was scaled: \(wideWidth) vs \(narrowWidth)")

		// Every glyph, table cells included, stays inside the page's horizontal bounds.
		for index in 0 ..< wideDoc.pageCount {
			let page = try #require(wideDoc.page(at: index))
			for character in 0 ..< page.numberOfCharacters {
				let bounds = page.characterBounds(at: character)
				guard bounds.width > 0 else { continue }
				#expect(bounds.minX >= 0 && bounds.maxX <= a4.width, "glyph outside the page on page \(index + 1): \(bounds)")
			}
		}
		let text = (0 ..< wideDoc.pageCount).compactMap { wideDoc.page(at: $0)?.string }.joined()
			.filter { !$0.isWhitespace }
		for header in headers {
			let compact = header.filter { !$0.isWhitespace }
			#expect(text.contains(compact), "header \(header) lost")
		}
	}

	/// #197: a title row spanning every column, and a table whose rows all span,
	/// still fit the page instead of making WebKit shrink the whole document.
	@Test("Spanning wide tables fit without shrinking the text", .timeLimit(.minutes(3)))
	func spanningWideTablesKeepTextSize() async throws {
		let words = ["Dokumentennummer", "Aufbewahrungsfrist", "Rechnungsempfänger", "Zahlungsbedingungen",
			"Lieferantenkennung", "Bestellreferenz", "Kostenstellennummer", "Umsatzsteuersatz",
			"Buchungsperiode", "Freigabevermerk"]
		let header = "<tr>" + words.map { "<th>\($0)</th>" }.joined() + "</tr>"
		let row = "<tr>" + words.map { _ in "<td>x</td>" }.joined() + "</tr>"
		let titled = "<table><thead><tr><th colspan=\"10\">Titel</th></tr>\(header)</thead><tbody>\(row)</tbody></table>"
		let spanned = "<table><tr><th colspan=\"4\">\(words[0 ..< 4].joined(separator: " "))</th>"
			+ "<th colspan=\"6\">\(words[4...].joined(separator: " "))</th></tr>"
			+ "<tr><td colspan=\"5\">\(String(repeating: "Prüfsumme", count: 8))</td><td colspan=\"5\">x</td></tr></table>"

		func html(_ body: String) -> String {
			"""
			<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">
			<style>@page { size: A4 portrait; margin: 0; }
			\(MarkdownToHTML.defaultStylesheet)
			body { max-width: none; margin: 0; padding: 40px; }</style></head>
			<body><p>Absatz</p>\(body)</body></html>
			"""
		}
		func wordWidth(_ document: PDFDocument) throws -> CGFloat {
			let match = try #require(document.findString("Absatz", withOptions: []).first)
			let page = try #require(match.pages.first)
			return match.bounds(for: page).width
		}

		let reference = try wordWidth(try await paginate(html("")))
		for table in [titled, spanned] {
			let document = try await paginate(html(table))
			let width = try wordWidth(document)
			#expect(abs(width - reference) / reference < 0.03, "body text was scaled: \(width) vs \(reference)")
			let page = try #require(document.page(at: 0))
			for character in 0 ..< page.numberOfCharacters {
				let bounds = page.characterBounds(at: character)
				guard bounds.width > 0 else { continue }
				#expect(bounds.minX >= 0 && bounds.maxX <= a4.width, "glyph outside the page: \(bounds)")
			}
		}
	}
}
#endif
