//  PageFootnoteTests.swift
//  SwiftTextRenderTests
//
//  `RenderOptions.pageFootnotes`: a note stands at the foot of the page that
//  holds its reference; a line moves to the next page with its note, and a note
//  too long for the page continues on the next one.

#if canImport(PDFKit)
import Foundation
import PDFKit
import Testing
@testable import SwiftTextRender

@Suite("Page footnotes")
struct PageFootnoteTests {
	/// A short page, so a few paragraphs fill it.
	private func options(footnotes: Bool) -> RenderOptions {
		var options = RenderOptions(pageWidthPx: 600, pageHeightPx: 360, pageMarginPx: 32)
		options.pageFootnotes = footnotes
		options.compressStreams = false
		return options
	}

	private func reference(_ index: Int) -> String { "Ref\(String(format: "%02d", index))" }
	private func note(_ index: Int) -> String { "Note\(String(format: "%02d", index))" }

	/// `count` paragraphs, each with a reference to a note of `noteWords` words, the notes after the last paragraph.
	private func document(count: Int, noteWords: Int = 12) -> String {
		var html = ""
		var notes = ""
		for index in 1...count {
			html += "<p>Paragraph \(index) with some words in it to fill a line or two of the page.<sup><a href=\"#fn-\(index)\">\(reference(index))</a></sup></p>\n"
			let words = (1...noteWords).map { "w\(index)x\($0)" }.joined(separator: " ")
			notes += "<div class=\"footnote-definition\" id=\"fn-\(index)\"><strong>\(note(index))</strong> \(words) End\(String(format: "%02d", index))</div>\n"
		}
		return html + notes
	}

	private func pages(_ html: String, footnotes: Bool = true) async throws -> [String] {
		let data = try await HTMLRenderer.renderPDF(html: html, options: options(footnotes: footnotes))
		let pdf = try #require(PDFDocument(data: data))
		return (0..<pdf.pageCount).map { index in
			(pdf.page(at: index)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
		}
	}

	private func numbers(_ text: String, prefix: String) -> Set<Int> {
		var found = Set<Int>()
		var rest = Substring(text)
		while let range = rest.range(of: prefix) {
			let digits = rest[range.upperBound...].prefix(2)
			if let number = Int(digits) { found.insert(number) }
			rest = rest[range.upperBound...]
		}
		return found
	}

	@Test("each note is on the page of its reference")
	func notesShareThePageWithTheirReference() async throws {
		let pages = try await pages(document(count: 14))
		#expect(pages.count > 1)
		for (index, text) in pages.enumerated() {
			#expect(numbers(text, prefix: "Ref") == numbers(text, prefix: "Note"), "page \(index + 1): \(text)")
		}
		#expect(pages.reduce(into: Set<Int>()) { $0.formUnion(numbers($1, prefix: "Note")) } == Set(1...14))
	}

	@Test("without the option the notes stay where the document puts them")
	func notesStayInTheFlow() async throws {
		let pages = try await pages(document(count: 14), footnotes: false)
		let last = try #require(pages.last)
		#expect(numbers(last, prefix: "Note").count > 3)
		#expect(numbers(pages[0], prefix: "Note").isEmpty)
	}

	@Test("a note stands below the paragraphs on its page")
	func noteComesAfterTheText() async throws {
		let pages = try await pages(document(count: 3, noteWords: 4))
		#expect(pages.count == 1)
		let text = try #require(pages.first)
		let lastParagraph = try #require(text.range(of: "Paragraph 3"))
		let firstNote = try #require(text.range(of: "Note01"))
		#expect(firstNote.lowerBound > lastParagraph.lowerBound)
	}

	@Test("a note longer than a page continues on the next page")
	func longNoteSpillsOver() async throws {
		let words = (1...400).map { "word\($0)" }.joined(separator: " ")
		let html = """
		<p>Before the reference.</p>
		<p>The reference is here.<sup><a href="#fn-1">Ref01</a></sup></p>
		<p>After the reference.</p>
		<div class="footnote-definition" id="fn-1"><strong>Note01</strong> \(words) End01</div>
		"""
		let pages = try await pages(html)
		// The reference line does not fit with its long note on the first page, so it
		// goes to the next one; the note starts there and continues on the page after.
		let home = try #require(pages.firstIndex { $0.contains("Ref01") })
		#expect(home > 0)
		#expect(pages[home].contains("Note01"))
		#expect(!pages[home].contains("End01"))
		#expect(!pages[home - 1].contains("Note01"))
		#expect(pages.count > home + 1)
		#expect(try #require(pages.last).contains("End01"))
		#expect(!pages.dropLast().contains { $0.contains("End01") })
	}

	@Test("a line whose note does not fit moves to the next page with it")
	func lineMigratesWithItsNote() async throws {
		let pages = try await pages(document(count: 14, noteWords: 40))
		for text in pages {
			#expect(numbers(text, prefix: "Ref").isSubset(of: numbers(text, prefix: "Note")))
		}
	}

	@Test("a note referenced only from another note is set with it")
	func nestedNoteIsKept() async throws {
		let html = """
		<p>Text.<sup><a href="#fn-1">Ref01</a></sup></p>
		<div class="footnote-definition" id="fn-1"><strong>Note01</strong> see<sup><a href="#fn-2">Ref02</a></sup></div>
		<div class="footnote-definition" id="fn-2"><strong>Note02</strong> inner</div>
		"""
		let pages = try await pages(html)
		#expect(pages.count == 1)
		#expect(pages[0].contains("Note01"))
		#expect(pages[0].contains("Note02"))
	}

	@Test("an @page size turns the page footnotes on")
	func atPageSizeCounts() async throws {
		var options = options(footnotes: true)
		options.pageHeightPx = nil
		let html = "<style>@page { size: 600px 360px; margin: 32px }</style>" + document(count: 14)
		let data = try await HTMLRenderer.renderPDF(html: html, options: options)
		let pdf = try #require(PDFDocument(data: data))
		let first = try #require(pdf.page(at: 0)?.string)
		#expect(numbers(first, prefix: "Ref") == numbers(first, prefix: "Note"))
		#expect(pdf.pageCount > 1)
	}

	@Test("a page too small for any note still finishes", .timeLimit(.minutes(1)))
	func tinyPageTerminates() async throws {
		var options = options(footnotes: true)
		options.pageHeightPx = 80
		options.pageMargins = PageMargins(32)
		let data = try await HTMLRenderer.renderPDF(html: document(count: 2, noteWords: 30), options: options)
		#expect(PDFDocument(data: data) != nil)
	}
}
#endif
