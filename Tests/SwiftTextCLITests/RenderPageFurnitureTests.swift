#if os(macOS)
import ArgumentParser
import Foundation
import PDFKit
import SwiftTextHTML
import Testing
@testable import SwiftTextCLI

@Suite("render PDF page furniture", .serialized)
@MainActor
struct RenderPageFurnitureTests {
	private func render(_ markdown: String, arguments: [String] = [], css: String? = nil, engine: String = "webkit") async throws -> PDFDocument {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let input = directory.appendingPathComponent("book.md")
		let output = directory.appendingPathComponent("book.pdf")
		try markdown.write(to: input, atomically: true, encoding: .utf8)
		var options = [input.path, "-o", output.path, "--engine", engine, "--title", "Ein Buch", "--page-break-before", "h1"] + arguments
		if let css {
			let stylesheet = directory.appendingPathComponent("furniture.css")
			try css.write(to: stylesheet, atomically: true, encoding: .utf8)
			options += ["--css", stylesheet.path]
		}
		let command = try Render.parse(options)
		try await command.run()
		return try #require(PDFDocument(data: Data(contentsOf: output)))
	}

	private func text(on page: PDFPage, from bottom: CGFloat, to top: CGFloat) -> String {
		let bounds = page.bounds(for: .mediaBox)
		let band = CGRect(x: bounds.minX, y: bounds.minY + bottom * bounds.height, width: bounds.width, height: (top - bottom) * bounds.height)
		return (page.selection(for: band)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	private func bodyHeadingTop(_ heading: String, on page: PDFPage, in document: PDFDocument) throws -> CGFloat {
		let pageTop = page.bounds(for: .mediaBox).maxY
		let selection = try #require(document.findString(heading, withOptions: []).first {
			$0.pages.contains(page) && $0.bounds(for: page).maxY < pageTop - 42
		})
		return selection.bounds(for: page).maxY
	}

	@Test("numbers and current chapter occupy the margin bands on every page", .timeLimit(.minutes(2)), arguments: ["section", "page"])
	func chapterFurniture(footnotes: String) async throws {
		let prose = "Langer Absatz mit vielen Wörtern für den Seitenumbruch und die Fortsetzung des Kapitels. "
		let markdown = (1...3).map { chapter in
			let sections = (1...2).map { section in
				let paragraphs = (1...6).map { paragraph in
					"\(String(repeating: "chapter-marker-\(chapter) \(prose)", count: 12))[^n\(chapter)-\(section)-\(paragraph)]"
				}.joined(separator: "\n\n")
				let notes = (1...6).map { "[^n\(chapter)-\(section)-\($0)]: Fußnote zum Absatz \($0)." }.joined(separator: "\n\n")
				return "## Abschnitt \(section)\n\n\(paragraphs)\n\n\(notes)"
			}.joined(separator: "\n\n")
			return "# Kapitel \(chapter)\n\n\(sections)"
		}.joined(separator: "\n\n")
		let document = try await render(markdown, arguments: ["--running-heads", "--footnotes", footnotes],
		                                css: "@page { @bottom-center { content: counter(page); } @top-center { content: 'Ein Buch'; } }")
		try #require(document.pageCount > 3, "the fixture must exercise chapter continuation pages")
		#expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Ein Buch")
		var currentChapter = 1
		for index in 0..<document.pageCount {
			let page = try #require(document.page(at: index))
			let body = text(on: page, from: 0.08, to: 0.92)
			for chapter in 1...3 where body.contains("Kapitel \(chapter)") { currentChapter = chapter }
			let header = text(on: page, from: 0.92, to: 1)
			#expect(header.contains("Ein Buch"), "page \(index + 1) has no book title in its top band")
			#expect(header.contains("Kapitel \(currentChapter)"), "page \(index + 1) has the wrong running chapter")
			let footer = text(on: page, from: 0, to: 0.08)
			#expect(footer.split(separator: " ").contains(Substring(String(index + 1))), "page \(index + 1) has no footer number")
			#expect(text(on: page, from: 0, to: 42 / page.bounds(for: .mediaBox).height) == String(index + 1), "the footer number must be clear of body text")
			#expect(!body.isEmpty, "page \(index + 1) must retain its body text")
		}
	}

	@Test("the webkit engine leaves the title page bare", .timeLimit(.minutes(2)))
	func webkitTitlePageBare() async throws {
		let prose = "Langer Absatz mit vielen Wörtern für den Seitenumbruch und die Fortsetzung des Kapitels. "
		let markdown = (1...3).map { chapter in
			"# Kapitel \(chapter)\n\n" + (1...6).map { _ in String(repeating: prose, count: 8) }.joined(separator: "\n\n")
		}.joined(separator: "\n\n")
		let document = try await render(markdown, arguments: ["--running-heads", "--title-page", "--toc", "--author", "A. Autor"])
		try #require(document.pageCount > 3)
		let title = try #require(document.page(at: 0))
		#expect(text(on: title, from: 0, to: 0.08).isEmpty && text(on: title, from: 0.92, to: 1).isEmpty, "the title page carries no furniture")
		let contents = try #require(document.page(at: 1))
		#expect(text(on: contents, from: 0, to: 0.08) == "2", "the contents page keeps its number")
		#expect(text(on: contents, from: 0.92, to: 1).isEmpty, "no running head before the first chapter")
	}

	@Test("the webkit engine leaves a title page bare when the title wraps", .timeLimit(.minutes(2)))
	func webkitWrappingTitleBare() async throws {
		let title = "Wie Sie Ihre Parkinson-Erkrankung bremsen können"
		let document = try await render("# Eins\n\nText.\n\n# Zwei\n\nText.\n",
		                                arguments: ["--running-heads", "--title-page", "--toc", "--title", title, "--subtitle", "Untertitel", "--author", "Autor"],
		                                css: ".titlepage h1.title { font-size: 40pt; }")
		let first = try #require(document.page(at: 0))
		let lines = (first.string ?? "").split(separator: "\n").filter { $0.contains("Parkinson") || $0.contains("bremsen") }
		try #require(lines.count > 1, "the fixture must wrap the title")
		#expect(text(on: first, from: 0, to: 0.08).isEmpty && text(on: first, from: 0.92, to: 1).isEmpty, "the title page carries no furniture")
	}

	@Test("the webkit engine follows a chapter heading that wraps: head, outline and link", .timeLimit(.minutes(2)))
	func webkitWrappingChapterHeading() async throws {
		let long = "Ein ziemlich langer Kapiteltitel der sicher über mehrere Zeilen umbricht"
		let document = try await render("# Kurz\n\nText.\n\n# \(long)\n\nText.\n\n# Nochmal kurz\n\nText.\n",
		                                arguments: ["--running-heads", "--toc"], css: "h1 { font-size: 28pt; }")
		let page = try #require(document.findString("Kapiteltitel", withOptions: []).last?.pages.first)
		let longPage = document.index(for: page)
		let head = text(on: page, from: 0.92, to: 1)
		#expect(head.contains("Ein ziemlich langer"), "the head follows the wrapping chapter, got: \(head)")
		let outline = try #require(document.outlineRoot)
		let titles = (0..<outline.numberOfChildren).compactMap { outline.child(at: $0)?.label }
		#expect(titles.contains(long), "the outline lists the wrapping chapter")
		let entry = (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }.first { $0.label == long }
		#expect(entry?.destination.flatMap { $0.page.map(document.index(for:)) } == longPage)
	}

	@Test("the webkit engine leaves every page of a multi-page title section bare", .timeLimit(.minutes(2)))
	func webkitLongTitleSectionBare() async throws {
		let authors = (1...40).flatMap { ["--author", "Autorin Nummer \($0)"] }
		let document = try await render("# Kapitel 1\n\nText.", arguments: ["--running-heads", "--title-page"] + authors)
		let first = try #require(document.findString("Kapitel 1", withOptions: []).first?.pages.first)
		let chapterIndex = document.index(for: first)
		try #require(chapterIndex > 1, "the fixture must spill the title section onto a second page")
		for index in 0..<chapterIndex {
			let page = try #require(document.page(at: index))
			// Author lines are title-section content that may reach the band; furniture is a number or head.
			func furniture(_ from: Double, _ to: Double) -> String {
				text(on: page, from: from, to: to).split(separator: "\n").filter { !$0.contains("Autorin") }.joined()
			}
			#expect(furniture(0, 0.08).isEmpty && furniture(0.92, 1).isEmpty, "title page \(index + 1) carries furniture")
		}
		#expect(text(on: try #require(document.page(at: chapterIndex)), from: 0, to: 0.08) == String(chapterIndex + 1))
	}

	@Test("the swift engine draws numbers and running heads, and leaves the title page bare", .timeLimit(.minutes(2)))
	func swiftEngineFurniture() async throws {
		let prose = "Langer Absatz mit vielen Wörtern für den Seitenumbruch und die Fortsetzung des Kapitels. "
		let markdown = (1...3).map { chapter in
			"# Kapitel \(chapter)\n\n" + (1...6).map { _ in String(repeating: prose, count: 8) }.joined(separator: "\n\n")
		}.joined(separator: "\n\n")
		let document = try await render(markdown, arguments: ["--running-heads", "--title-page", "--toc", "--author", "A. Autor"], engine: "swift")
		try #require(document.pageCount > 5)
		var currentChapter = 0
		for index in 0..<document.pageCount {
			let page = try #require(document.page(at: index))
			let footer = text(on: page, from: 0, to: 0.08)
			let header = text(on: page, from: 0.92, to: 1)
			if index == 0 {
				#expect(footer.isEmpty && header.isEmpty, "the title page carries no furniture")
				continue
			}
			#expect(footer == String(index + 1), "page \(index + 1) has no footer number")
			#expect(header.contains("Ein Buch"), "page \(index + 1) has no book title")
			let body = text(on: page, from: 0.08, to: 0.92)
			for chapter in 1...3 where body.contains("Kapitel \(chapter) Langer") { currentChapter = chapter }
			if currentChapter > 0 { #expect(header.contains("Kapitel \(currentChapter)"), "page \(index + 1) has the wrong running chapter") }
		}
		// The contents' numbers agree with the numbers drawn on the pages.
		let contents = text(on: try #require(document.page(at: 1)), from: 0.08, to: 0.92)
		let chapterPage = try #require((0..<document.pageCount).first { index in
			index > 1 && text(on: document.page(at: index)!, from: 0.08, to: 0.92).contains("Kapitel 2 Langer")
		})
		#expect(contents.contains("Kapitel 2 \(chapterPage + 1)"))
	}

	private func half(on page: PDFPage, from bottom: CGFloat, to top: CGFloat, left: Bool) -> String {
		let bounds = page.bounds(for: .mediaBox)
		let band = CGRect(x: left ? bounds.minX : bounds.midX, y: bounds.minY + bottom * bounds.height, width: bounds.width / 2, height: (top - bottom) * bounds.height)
		return (page.selection(for: band)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	@Test("mirrored heads and numbers from the first chapter give the classic book page furniture", .timeLimit(.minutes(3)), arguments: ["swift", "webkit"])
	func classicBookFurniture(engine: String) async throws {
		let prose = "Langer Absatz mit vielen Wörtern für den Seitenumbruch und die Fortsetzung des Kapitels. "
		let long = (1...14).map { _ in String(repeating: prose, count: 8) }.joined(separator: "\n\n")
		let document = try await render("# Eins\n\n\(long)\n\n# Zwei\n\nText.\n", arguments: ["--running-heads", "--mirrored-heads", "--number-from-chapter",
		                                                                                         "--title-page", "--toc", "--author", "A. Autor"], engine: engine)
		try #require(document.pageCount > 4, "the first chapter must continue over several pages")
		let first = try #require(document.page(at: 0))
		let contents = try #require(document.page(at: 1))
		for page in [first, contents] {
			#expect(text(on: page, from: 0, to: 0.08).isEmpty && text(on: page, from: 0.92, to: 1).isEmpty, "front matter carries no furniture")
		}
		var sawRightHead = false, sawLeftHead = false
		var zweiPage = 0
		for index in 2..<document.pageCount {
			let page = try #require(document.page(at: index))
			let isLeft = !index.isMultiple(of: 2)
			let body = text(on: page, from: 0.08, to: 0.92)
			let opensChapter = body.hasPrefix("Eins Langer") || body.hasPrefix("Zwei Text")
			if body.hasPrefix("Zwei") { zweiPage = index }
			let number = String(index - 1)
			#expect(half(on: page, from: 0, to: 0.08, left: isLeft) == number, "page \(index + 1) has its number \(number) on the outside edge")
			#expect(half(on: page, from: 0, to: 0.08, left: !isLeft).isEmpty, "page \(index + 1) has nothing on the inside edge")
			let outer = half(on: page, from: 0.95, to: 1, left: isLeft)
			let inner = half(on: page, from: 0.95, to: 1, left: !isLeft)
			#expect(inner.isEmpty, "page \(index + 1) has a head on the inside half")
			if opensChapter {
				#expect(outer.isEmpty, "page \(index + 1) opens a chapter and has no head")
			} else if isLeft {
				#expect(outer.contains("Ein Buch")); sawLeftHead = true
			} else {
				#expect(outer.contains("Eins")); sawRightHead = true
			}
		}
		#expect(sawLeftHead && sawRightHead)
		try #require(zweiPage > 2)
		let listed = text(on: contents, from: 0.08, to: 0.92)
		#expect(listed.contains("Eins 1"), "contents: \(listed)")
		#expect(listed.contains("Zwei \(zweiPage - 1)"), "contents lists the printed number: \(listed)")
	}

	@Test("numbering from the chapter works without running heads", .timeLimit(.minutes(3)), arguments: ["swift", "webkit"])
	func numberFromChapterWithoutHeads(engine: String) async throws {
		let document = try await render("# Eins\n\nText.\n\n# Zwei\n\nText.\n", arguments: ["--number-from-chapter", "--title-page", "--toc"], engine: engine)
		try #require(document.pageCount == 4)
		for index in 0..<2 { #expect(text(on: try #require(document.page(at: index)), from: 0, to: 0.08).isEmpty, "front matter page \(index + 1) is unnumbered") }
		#expect(text(on: try #require(document.page(at: 2)), from: 0, to: 0.08) == "1")
		#expect(text(on: try #require(document.page(at: 3)), from: 0, to: 0.08) == "2")
	}

	@Test("the swift engine keeps furniture inside the page and apart: zero margins, long heads", .timeLimit(.minutes(1)))
	func swiftEngineMarginsAndLongHeads() async throws {
		let long = String(repeating: "Ein sehr langer Kapitelname ", count: 6)
		let document = try await render("# \(long)\n\nText.", arguments: ["--running-heads", "--title", long], css: "@page { margin: 0; }", engine: "swift")
		let page = try #require(document.page(at: 0))
		#expect(text(on: page, from: 0, to: 0.08) == "1", "the footer must stay on the page with a zero margin")
		let header = text(on: page, from: 0.92, to: 1)
		#expect(header.contains("…"), "overlong heads are truncated, not overlapped: \(header)")
	}

	@Test("numbers default on, may be disabled, and running heads are opt in", .timeLimit(.minutes(1)))
	func defaultsAndOptOut() async throws {
		let numbered = try await render("# Kapitel 1\n\nText.")
		let first = try #require(numbered.page(at: 0))
		#expect(text(on: first, from: 0, to: 0.08) == "1")
		#expect(text(on: first, from: 0.92, to: 1).isEmpty)
		let plain = try await render("# Kapitel 1\n\nText.", arguments: ["--no-page-numbers"])
		#expect(text(on: try #require(plain.page(at: 0)), from: 0, to: 0.08).isEmpty)
	}

	@Test("small authored margins leave furniture clear of page footnotes and preserve links", .timeLimit(.minutes(1)))
	func smallMarginsAndLinks() async throws {
		let markdown = """
		# Kapitel 1

		[External](https://example.com) and [next chapter](#kapitel-2). Text.[^a]

		[^a]: Eine Fußnote am Seitenende.

		# Kapitel 2

		Second chapter.
		"""
		let document = try await render(markdown, arguments: ["--page-numbers", "--running-heads", "--footnotes", "page", "--paper", "letter", "--landscape"],
		                                css: "@page { margin: 0; }")
		#expect(document.pageCount == 2)
		let first = try #require(document.page(at: 0))
		#expect(text(on: first, from: 0, to: 0.08) == "1")
		#expect(text(on: first, from: 0.08, to: 0.92).contains("Eine Fußnote"))
		#expect(text(on: first, from: 0.92, to: 1).contains("Ein Buch"))
		#expect(first.annotations.contains { $0.url?.host == "example.com" })
		let internalLink = try #require(first.annotations.compactMap { $0.action as? PDFActionGoTo }.first)
		#expect(internalLink.destination.page === document.page(at: 1))
	}

	@Test("help documents both furniture controls")
	func help() throws {
		let help = Render.helpMessage()
		#expect(help.contains("--page-numbers/--no-page-numbers"))
		#expect(help.contains("--running-heads"))
		#expect(try Render.parse([]).pageNumbers)
		#expect(try !Render.parse(["--no-page-numbers"]).pageNumbers)
	}

	@Test("running heads follow the selected chapter level without numbers", .timeLimit(.minutes(1)))
	func chapterLevelAndHeaderOnly() async throws {
		let document = try await render("## Erster Teil\n\nText.\n\n## Zweiter Teil\n\nMore text.",
		                                arguments: ["--page-break-before", "h2", "--running-heads", "--no-page-numbers"],
		                                css: "@page { margin: 3cm; }")
		try #require(document.pageCount == 2)
		for (index, heading) in ["Erster Teil", "Zweiter Teil"].enumerated() {
			let page = try #require(document.page(at: index))
			let header = text(on: page, from: 0.92, to: 1)
			#expect(header.contains("Ein Buch") && header.contains(heading))
			#expect(text(on: page, from: 0, to: 0.08).isEmpty)
			#expect(try bodyHeadingTop(heading, on: page, in: document) <= page.bounds(for: .mediaBox).maxY - 80,
			        "larger authored margins must be retained")
		}
	}

	@Test("calculated page margins remain larger than the furniture band", .timeLimit(.minutes(1)))
	func calculatedMargin() async throws {
		let document = try await render("# Calculated Margin\n\nText.", arguments: ["--running-heads", "--no-page-numbers"],
		                                css: "@page { margin-top: calc(2cm + 10pt); }")
		let page = try #require(document.page(at: 0))
		#expect(try bodyHeadingTop("Calculated Margin", on: page, in: document) <= page.bounds(for: .mediaBox).maxY - 60,
		        "calc() must be resolved by WebKit instead of replaced with 48pt")
	}

	@Test("qualified and variable page margins remain scoped in the supplemental stylesheet", .timeLimit(.minutes(1)))
	func qualifiedMargins() async throws {
		let html = """
		<html><head><style>
		:root { --page-margin: 5cm; }
		@page { margin: 2cm; }
		@page :first { margin-top: 0; }
		@page :left { margin-top: 4cm; }
		@page named:right { margin-top: var(--page-margin); }
		</style></head><body><h1>Chapter</h1></body></html>
		"""
		let browser = WebKitBrowser(htmlString: html)
		await browser.waitForLoadCompletion()
		let preparation = try await browser.preparePageFurniture(paperSize: CGSize(width: 595.28, height: 841.89),
		                                                         footer: true, header: true, headingLevel: 1)
		let stylesheet = preparation.stylesheet
		#expect(stylesheet.contains("@page :first {margin-top:max(48pt, 0px) !important;"))
		#expect(stylesheet.contains("@page :left {margin-top:max(48pt, 4cm) !important;"))
		#expect(stylesheet.contains("@page named:right {margin-top:max(48pt, var(--page-margin)) !important;"))
		#expect(!stylesheet.contains("@page  {margin-top:max(48pt, 4cm)"), "qualified margins must not become document-wide")
	}

	@Test("webkit: a block with page: wide forms one landscape run, the rest stay portrait", .timeLimit(.minutes(2)))
	func webkitNamedPageRun() async throws {
		let cells = (1...10).map { "\($0)" }
		let markdown = """
		# Eins

		Text eins.

		# Drei

		<div class="wide">

		| A | B | C | D | E | F | G | H | I | J |
		|---|---|---|---|---|---|---|---|---|---|
		| \(cells.joined(separator: " | ")) |
		|   |   |   |   |   |   |   |   |   |   |

		</div>

		# Vier

		Text vier.
		"""
		let document = try await render(markdown, css: "@page wide { size: A4 landscape; }\n.wide { page: wide; }\n")
		let sizes = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox) }
		#expect(sizes.filter { $0.width > $0.height }.count == 1, "expected exactly one landscape page, got \(sizes)")
		#expect(sizes.filter { $0.width < $0.height }.count == sizes.count - 1)
		let landscape = try #require(sizes.firstIndex { $0.width > $0.height })
		#expect(document.page(at: landscape)?.string?.contains("10") == true)
		#expect(document.page(at: sizes.count - 1)?.string?.contains("Text vier") == true)
	}

	@Test("webkit: a long table that is itself the named block still forms a landscape run", .timeLimit(.minutes(2)))
	func webkitNamedTableRun() async throws {
		let rows = (1...90).map { "| r\($0) | x | y |" }.joined(separator: "\n")
		let markdown = "# Eins\n\nText eins.\n\n# Zwei\n\n| A | B | C |\n|---|---|---|\n\(rows)\n\n# Drei\n\nText drei.\n"
		let document = try await render(markdown, css: "@page wide { size: A4 landscape; }\ntable { page: wide; }\n")
		let sizes = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox) }
		#expect(sizes.contains { $0.width > $0.height }, "the table run is missing: \(sizes)")
		#expect(document.page(at: sizes.count - 1)?.string?.contains("Text drei") == true)
		#expect(sizes.last.map { $0.width < $0.height } == true)
	}

	@Test("webkit: the more specific page assignment wins, whatever its source order", .timeLimit(.minutes(2)))
	func webkitPageSpecificity() async throws {
		let markdown = "# Eins\n\n<div class=\"wide\">\n\nBreit.\n\n</div>\n\n# Zwei\n\nText.\n"
		let css = "@page wide { size: A4 landscape; }\n@page narrow { size: A5; }\n.wide { page: wide; }\ndiv { page: narrow; }\n@media screen { h1 { page: narrow; } }\n"
		let document = try await render(markdown, css: css)
		let sizes = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox) }
		#expect(sizes.filter { $0.width > $0.height }.count == 1, "got \(sizes)")
		#expect(!sizes.contains { Int($0.width.rounded()) == 420 }, "the less specific rule must not apply: \(sizes)")
	}

	@Test("webkit: a named page that matches only an empty block falls back to the plain export", .timeLimit(.minutes(2)))
	func webkitEmptyNamedRun() async throws {
		let document = try await render("# Eins\n\nText.\n\n<div class=\"wide\"></div>\n", css: "@page wide { size: A4 landscape; }\n.wide { page: wide; }\n")
		#expect(document.pageCount >= 1)
		#expect(document.page(at: 0)?.string?.contains("Eins") == true)
	}

	@Test("webkit: side margins do not move the pages of a named run", .timeLimit(.minutes(2)))
	func webkitNamedRunKeepsItsMargins() async throws {
		let markdown = "# Eins\n\nText.\n\n# Zwei\n\n<div class=\"wide\">\n\nBreit.\n\n</div>\n\n# Drei\n\nText.\n"
		let css = "@page :right { margin-left: 22mm; margin-right: 17mm; }\n@page :left { margin-left: 17mm; margin-right: 22mm; }\n"
			+ "@page wide { size: A4 landscape; margin: 10mm; }\n.wide { page: wide; }\n"
		let document = try await render(markdown, css: css)
		let index = try #require((0..<document.pageCount).first { document.page(at: $0)?.string?.contains("Breit") == true })
		let page = try #require(document.page(at: index))
		let edge = try #require(page.selection(for: page.bounds(for: .mediaBox))?.bounds(for: page).minX)
		#expect(abs(edge / 72 * 25.4 - 10) < 2, "named page content moved off its 10 mm margin: \(edge) pt")
	}

	@Test("webkit: a named or pseudo @page size never applies to the whole document", .timeLimit(.minutes(2)))
	func webkitPseudoSizeIsNotGlobal() async throws {
		let document = try await render("# Eins\n\nText.\n", css: "@page wide { size: A5; }\n@page :first { size: A3; }\n")
		let box = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
		#expect(Int(box.width.rounded()) == 595 || Int(box.width.rounded()) == 612)
	}

	@Test("webkit: @page :left and :right carry their own side margins", .timeLimit(.minutes(2)))
	func webkitSideMargins() async throws {
		let prose = String(repeating: "Wort ", count: 400)
		let markdown = "# Eins\n\n\(prose)\n\n\(prose)\n\n\(prose)\n\n\(prose)\n"
		let css = "@page { margin: 20mm; }\n@page :right { margin-left: 22mm; margin-right: 17mm; }\n@page :left { margin-left: 17mm; margin-right: 22mm; }\n"
		let document = try await render(markdown, css: css)
		try #require(document.pageCount >= 2)
		func leftEdge(_ index: Int) throws -> CGFloat {
			let page = try #require(document.page(at: index))
			return try #require(page.selection(for: page.bounds(for: .mediaBox))?.bounds(for: page).minX)
		}
		let right = try leftEdge(0), left = try leftEdge(1)
		#expect(abs((right - left) / 72 * 25.4 - 5) < 1.5, "inside margin should be 5 mm wider on the recto, got \(right) vs \(left)")
	}

	@Test("webkit: page-foot notes fit their page with :left/:right margins", .timeLimit(.minutes(3)))
	func pageFootnotesWithSideMargins() async throws {
		let line = "Dies ist ein Satz mit etwas Text, damit die Zeilen gefüllt werden und der Absatz mehrere Zeilen lang wird. "
		let note = "Eine längere Fußnote mit Quellenangabe, Autor A, Autorin B: Titel der Veröffentlichung, Zeitschrift 2024, Seiten 1–12."
		let paragraphs = (1...40).map { "\(String(repeating: line, count: 3))[^\($0)]" }.joined(separator: "\n\n")
		let definitions = (1...40).map { "[^\($0)]: \(note)" }.joined(separator: "\n")
		let markdown = "# Kapitel\n\n\(paragraphs)\n\n\(definitions)\n"
		let symmetric = try await render(markdown, arguments: ["--footnotes", "page"], css: "@page { margin: 20mm 20mm 22mm 20mm; }")
		let sided = try await render(markdown, arguments: ["--footnotes", "page"],
		                             css: "@page :left { margin: 20mm 17mm 22mm 22mm; }\n@page :right { margin: 20mm 22mm 22mm 17mm; }")
		#expect(sided.pageCount == symmetric.pageCount, "\(sided.pageCount) pages with side margins, \(symmetric.pageCount) with one margin")
		for index in 0..<sided.pageCount {
			let words = (sided.page(at: index)?.string ?? "").split(whereSeparator: \.isWhitespace).count
			#expect(words > 20, "page \(index + 1) holds only \(words) words")
		}
	}

	@Test("webkit: page-foot notes with a named page keep the title page and contents first", .timeLimit(.minutes(3)), arguments: [[], ["--toc"]])
	func pageFootnotesKeepFrontMatterFirst(extra: [String]) async throws {
		let markdown = """
		# Eins

		Text eins mit Note[^1].

		[^1]: Die Note.

		# Drei

		<div class="wide">

		| A | B | C | D | E | F | G | H | I | J |
		|---|---|---|---|---|---|---|---|---|---|
		| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |

		</div>

		# Vier

		Text vier.
		"""
		let document = try await render(markdown, arguments: ["--title-page", "--author", "Autor", "--footnotes", "page"] + extra,
		                                css: "@page wide { size: A4 landscape; }\n.wide { page: wide; }\n")
		let texts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
		let first = { (needle: String) in texts.firstIndex { $0.contains(needle) } }
		#expect(texts.filter { $0.contains("Autor") }.count == 1, "the title page must appear once")
		let title = try #require(first("Autor")), eins = try #require(first("Text eins"))
		let drei = try #require(texts.indices.first { texts[$0].contains("Drei") && $0 > eins })
		let wide = try #require(first("10")), vier = try #require(first("Text vier"))
		#expect(title == 0, "title page at \(title) in \(texts)")
		if !extra.isEmpty { #expect(try #require(first("Eins")) < eins && title < (first("Eins") ?? 0)) }
		#expect(title < eins && eins < drei && drei < wide && wide < vier, "page order \(texts)")
	}
}
#endif
