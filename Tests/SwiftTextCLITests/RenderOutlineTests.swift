#if os(macOS)
import Foundation
import PDFKit
import Testing
@testable import SwiftTextCLI

@Suite("render PDF outline", .serialized)
@MainActor
struct RenderOutlineTests {
	private static let markdown = (1...3).map { chapter in
		"# Kapitel \(chapter)\n\nEinleitung zu Kapitel \(chapter).\n\n" + (1...2).map { section in
			"## Abschnitt \(chapter).\(section)\n\nText des Abschnitts \(chapter).\(section)."
		}.joined(separator: "\n\n")
	}.joined(separator: "\n\n")

	private func render(engine: String) async throws -> PDFDocument {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let input = directory.appendingPathComponent("buch.md")
		let output = directory.appendingPathComponent("buch.pdf")
		try Self.markdown.write(to: input, atomically: true, encoding: .utf8)
		let command = try Render.parse([input.path, "-o", output.path, "--engine", engine, "--title", "Ein Buch",
		                                "--title-page", "--toc", "--toc-depth", "1", "--page-break-before", "h1"])
		try await command.run()
		return try #require(PDFDocument(data: Data(contentsOf: output)))
	}

	/// The outline flattened in document order: nesting depth (0 = top level), title and target page.
	private func outline(of document: PDFDocument) -> [(depth: Int, title: String, page: Int?)] {
		var result: [(depth: Int, title: String, page: Int?)] = []
		func walk(_ item: PDFOutline, depth: Int) {
			for index in 0..<item.numberOfChildren {
				guard let child = item.child(at: index) else { continue }
				let page = (child.destination ?? (child.action as? PDFActionGoTo)?.destination)?.page.map { document.index(for: $0) }
				result.append((depth, child.label ?? "", page))
				walk(child, depth: depth + 1)
			}
		}
		if let root = document.outlineRoot { walk(root, depth: 0) }
		return result
	}

	@Test("the webkit engine writes the heading outline the swift engine writes", .timeLimit(.minutes(3)))
	func webkitMatchesSwift() async throws {
		let webkit = try await render(engine: "webkit")
		let swift = try await render(engine: "swift")
		let webkitOutline = outline(of: webkit)
		let swiftOutline = outline(of: swift)

		var expected: [(depth: Int, title: String)] = [(0, "Ein Buch")]
		for chapter in 1...3 {
			expected.append((0, "Kapitel \(chapter)"))
			for section in 1...2 { expected.append((1, "Abschnitt \(chapter).\(section)")) }
		}
		#expect(webkitOutline.map(\.depth) == expected.map(\.depth))
		#expect(webkitOutline.map(\.title) == expected.map(\.title))
		#expect(swiftOutline.map(\.depth) == webkitOutline.map(\.depth))
		#expect(swiftOutline.map(\.title) == webkitOutline.map(\.title))

		// Each bookmark opens the page where its heading is set, not the contents page.
		#expect(webkitOutline.first?.page == 0)
		for entry in webkitOutline.dropFirst() {
			let index = try #require(entry.page, "\(entry.title) has no destination")
			#expect(index >= 2, "\(entry.title) points at the front matter")
			let text = try #require(webkit.page(at: index)?.string)
			#expect(text.contains(entry.title), "\(entry.title) is not on page \(index + 1)")
		}
		let chapterPages = webkitOutline.filter { $0.title.hasPrefix("Kapitel") }.compactMap(\.page)
		#expect(chapterPages == chapterPages.sorted() && Set(chapterPages).count == 3)

		// The contents links stay internal GoTo destinations.
		let contents = try #require(webkit.page(at: 1))
		let targets = contents.annotations.compactMap { ($0.action as? PDFActionGoTo)?.destination ?? $0.destination }
		#expect(targets.count == 9)
		#expect(targets.allSatisfy { $0.page.map { webkit.index(for: $0) >= 2 } ?? false })
	}
}
#endif
