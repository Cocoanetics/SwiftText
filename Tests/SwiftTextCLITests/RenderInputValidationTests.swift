import ArgumentParser
import Foundation
import Testing
@testable import SwiftTextCLI

@Suite("render input validation")
struct RenderInputValidationTests {
	@Test("an .html or .htm input is rejected with a clear error", arguments: ["page.html", "/tmp/PAGE.HTM"])
	func rejectsHTML(path: String) {
		do {
			try Render.validateMarkdownInput(URL(fileURLWithPath: path))
			Issue.record("expected a ValidationError for \(path)")
		} catch let error as ValidationError {
			#expect(error.message.contains("HTML input is not supported"))
			#expect(error.message.contains(".md/.markdown"))
		} catch {
			Issue.record("unexpected error \(error)")
		}
	}

	@Test("Markdown inputs are accepted", arguments: ["a.md", "a.markdown", "A.MD", "notes.txt"])
	func acceptsMarkdown(path: String) throws {
		try Render.validateMarkdownInput(URL(fileURLWithPath: path))
	}
}

@Suite("render run rejects HTML input")
struct RenderRunTests {
	@Test("run() on an existing .html file throws a ValidationError")
	func runRejectsHTMLFile() async throws {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
		try "<!DOCTYPE html><html><body>x</body></html>".write(to: url, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: url) }
		var command = try Render.parse([url.path, "-o", url.deletingPathExtension().appendingPathExtension("pdf").path])
		await #expect(throws: ValidationError.self) { try await command.run() }
	}
}
