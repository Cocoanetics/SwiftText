//  RenderSwiftPageFootnotesTests.swift
//  SwiftTextCLITests
//
//  `render --engine swift --footnotes page` sets each note at the foot of the
//  page that holds its reference — no WebKit involved.

#if os(macOS)
import ArgumentParser
import Foundation
import PDFKit
import Testing
@testable import SwiftTextCLI

@Suite("render swift engine page footnotes", .serialized)
@MainActor
struct RenderSwiftPageFootnotesTests {
	private var markdown: String {
		var lines = ["# Kapitel 1", ""]
		for index in 1...14 {
			lines += ["Absatz \(index). " + String(repeating: "Lorem ipsum dolor sit amet, consetetur sadipscing elitr. ", count: 4) + "[^n\(index)]", ""]
		}
		for index in 1...14 { lines += ["[^n\(index)]: Notiz\(String(format: "%02d", index)) mit etwas Text.", ""] }
		lines += ["# Kapitel 2", "", "Satz.[^z]", "", "[^z]: Kurze Note."]
		return lines.joined(separator: "\n")
	}

	private func pages(arguments: [String]) async throws -> [String] {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let input = directory.appendingPathComponent("book.md")
		let output = directory.appendingPathComponent("book.pdf")
		try markdown.write(to: input, atomically: true, encoding: .utf8)
		let command = try Render.parse([input.path, "-o", output.path, "--engine", "swift", "--page-break-before", "h1"] + arguments)
		try await command.run()
		let document = try #require(PDFDocument(data: Data(contentsOf: output)))
		return (0..<document.pageCount).map { index in
			(document.page(at: index)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
		}
	}

	private func notes(_ text: String) -> Set<String> {
		Set(text.split(separator: " ").compactMap { $0.hasPrefix("Notiz") ? String($0.prefix(7)) : nil })
	}

	@Test("notes are on the page of their reference", .timeLimit(.minutes(1)))
	func notesAtTheFootOfThePage() async throws {
		let flowing = try await pages(arguments: [])
		let atFoot = try await pages(arguments: ["--footnotes", "page"])
		// In the flow the notes follow the text; at the foot, the first page already has the first ones.
		#expect(notes(flowing[0]).isEmpty)
		#expect(notes(atFoot[0]).contains("Notiz01"))
		let seen = atFoot.reduce(into: Set<String>()) { $0.formUnion(notes($1)) }
		#expect(seen.count == 14)
		for text in atFoot {
			for note in notes(text) {
				let number = Int(note.dropFirst(5)) ?? 0
				#expect(text.contains("Absatz \(number)."), "\(note) is not on the page of its paragraph")
			}
		}
	}
}
#endif
