#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import SwiftTextCLI

@Suite("render PDF title page and contents", .serialized)
@MainActor
struct FrontMatterPDFTests {
	private func render(engine: String, footnotes: String = "section") async throws -> PDFDocument {
		let lorem = "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna aliquyam erat, sed diam voluptua. "
		let markdown = (1...3).map { chapter in
			let sections = (1...2).map { section in
				"## Abschnitt \(chapter).\(section)\n\n" + (1...6).map { _ in String(repeating: lorem, count: 4) }.joined(separator: "\n\n")
			}.joined(separator: "\n\n")
			return "# Kapitel \(chapter)\n\n\(sections)"
		}.joined(separator: "\n\n")
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let input = directory.appendingPathComponent("buch.md")
		let output = directory.appendingPathComponent("buch.pdf")
		try markdown.write(to: input, atomically: true, encoding: .utf8)
		let command = try Render.parse([input.path, "-o", output.path, "--engine", engine, "--title", "Ein Buch", "--subtitle", "Ein Untertitel",
		                                "--author", "A. Autor", "--language", "de", "--page-break-before", "h1", "--toc-depth", "1",
		                                "--title-page", "--toc", "--footnotes", footnotes])
		try await command.run()
		return try #require(PDFDocument(data: Data(contentsOf: output)))
	}

	@Test("title page, then contents whose numbers match the pages", .timeLimit(.minutes(3)), arguments: ["section", "page"])
	func webkit(footnotes: String) async throws {
		let document = try await render(engine: "webkit", footnotes: footnotes)
		let first = try #require(document.page(at: 0)?.string)
		#expect(first.contains("Ein Buch") && first.contains("Ein Untertitel") && first.contains("A. Autor"))
		#expect(!first.contains("Kapitel 1"))
		let second = try #require(document.page(at: 1)?.string)
		#expect(second.contains("Inhalt") && second.contains("Kapitel 1"))
		#expect(!second.contains("Lorem"))

		// Each contents line ends in the page where that heading begins.
		let lines = second.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
		for heading in ["Kapitel 1", "Abschnitt 1.2", "Kapitel 2", "Abschnitt 3.1"] {
			let pageNumber = try #require(lines.compactMap { line -> Int? in
				guard line.hasPrefix(heading) else { return nil }
				return Int(line.split(separator: " ").last ?? "")
			}.first, "no contents number for \(heading)")
			let page = try #require(document.page(at: pageNumber - 1))
			let match = try #require(document.findString(heading, withOptions: []).first { $0.pages.contains(page) })
			#expect(match.bounds(for: page).maxY > 0)
			#expect(pageNumber > 2, "\(heading) must come after the contents")
		}
	}

	@Test("the swift engine numbers the contents too", .timeLimit(.minutes(3)))
	func swiftEngine() async throws {
		let document = try await render(engine: "swift")
		let first = try #require(document.page(at: 0)?.string)
		#expect(first.contains("Ein Buch") && !first.contains("Kapitel 1"))
		#expect(try #require(document.page(at: 1)?.string).contains("Inhalt"))
	}
}
#endif
