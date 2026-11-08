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
		// Four, not three: the rule fires on the first `h1` too, so the break
		// before it opens a page of its own. Both platforms agree on that — which
		// is the parity claim, since this same number is asserted on each.
		#expect(try await paginate(html).pageCount == 4)
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
}
#endif
