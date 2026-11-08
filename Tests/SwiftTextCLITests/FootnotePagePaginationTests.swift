//  FootnotePagePaginationTests.swift
//  SwiftTextCLITests
//
//  `--footnotes page` paginates at print time in a `beforeprint` script, so
//  these tests print through WebKit and read the result back page by page.

#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import SwiftTextCLI
import SwiftTextHTML

@Suite("render footnotes page pagination", .serialized)
@MainActor
struct FootnotePagePaginationTests {
	private let a4 = CGSize(width: 595.28, height: 841.89)

	/// The repro from #177: seven long list items, each ending in a reference to
	/// a long note, then a short second chapter.
	private var overflowMarkdown: String {
		let body = String(repeating: "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna aliquyam erat, sed diam voluptua. ", count: 2)
		let note = String(repeating: "Mustermann A et al. Eine lange Studie mit einem langen Titel, randomisiert und kontrolliert, in einer Fachzeitschrift mit langem Namen 2024, Übersicht über alle Ergebnisse (Quellenverzeichnis Nr. 1.) Beispiel B et al. Noch eine Studie zum selben Thema, Folgearbeit 2025 (Quellenverzeichnis Nr. 2.) ", count: 2)
		var lines = ["# Kapitel 1", ""]
		lines += (1...7).map { "\($0). **Punkt \($0).** \(body)[^n\($0)]" }
		lines.append("")
		for index in 1...7 { lines += ["[^n\(index)]: \(note)", ""] }
		lines += ["# Kapitel 2", "", "Satz.[^z]", "", "[^z]: Kurze Note."]
		return lines.joined(separator: "\n")
	}

	private func pages(_ markdown: String) async throws -> [String] {
		let html = markdownToHTML(markdown, paper: .a4, landscape: false, pageBreakBefore: .h1, footnotes: .page)
		let browser = WebKitBrowser(htmlString: html)
		browser.timeout = 30
		browser.frameSize = a4
		browser.preserveFrameHeight = true
		let data = try await browser.exportPaginatedPDFData(paperSize: a4)
		let document = try #require(PDFDocument(data: data))
		// Line breaks become single spaces so phrases match across lines.
		return (0..<document.pageCount).map { index in
			(document.page(at: index)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
		}
	}

	private func labels(_ text: String, pattern: String) throws -> Set<String> {
		let regex = try NSRegularExpression(pattern: pattern)
		let range = NSRange(text.startIndex..., in: text)
		return Set(regex.matches(in: text, range: range).compactMap { match in
			Range(match.range(at: 1), in: text).map { String(text[$0]) }
		})
	}

	@Test("long notes shorten the page instead of leaving the heading alone", .timeLimit(.minutes(1)))
	func longNotesShortenThePage() async throws {
		let pages = try await pages(overflowMarkdown)
		try #require(pages.count >= 2)
		#expect(pages.count <= 3)
		#expect(pages[0].contains("Kapitel 1"))
		#expect(pages[0].contains("Punkt 1."))
		for (index, page) in pages.enumerated() {
			// Every reference on a page has its note at the foot of that page.
			let references = try labels(page, pattern: #"\[(\d+)\](?!:)"#)
			let notes = try labels(page, pattern: #"\[(\d+)\]:"#)
			#expect(references.isSubset(of: notes), "page \(index + 1): references \(references.sorted()) but notes \(notes.sorted())")
		}
		let last = try #require(pages.last)
		#expect(last.contains("Kapitel 2"))
		#expect(last.contains("Kurze Note."))
		// Splitting list items across pages loses and repeats no text.
		let all = pages.joined(separator: " ")
		for index in 1...7 { #expect(all.components(separatedBy: "Punkt \(index).").count == 2) }
		#expect(all.components(separatedBy: "Quellenverzeichnis Nr. 1.").count - 1 == 14)
	}

	@Test("a note longer than a page continues at the foot of the next", .timeLimit(.minutes(1)))
	func noteLongerThanAPage() async throws {
		let sentence = "Sehr lange Fußnote mit vielen Wörtern, die nicht auf eine Seite passt. "
		let text = String(repeating: "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor. ", count: 6)
		let markdown = "# Lang\n\nKurz.[^a] \(text)\n\n[^a]: \(String(repeating: sentence, count: 120))"
		let pages = try await pages(markdown)
		try #require(pages.count >= 2)
		// The heading keeps the first lines of the paragraph with it.
		#expect(pages[0].contains("Kurz."))
		#expect(pages[0].contains("Sehr lange Fußnote"))
		#expect(pages[1].contains("Sehr lange Fußnote"))
		let all = pages.joined(separator: " ")
		#expect(all.components(separatedBy: "passt.").count - 1 == 120)
	}
}
#endif
