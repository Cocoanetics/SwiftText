import Foundation
import Testing
@testable import SwiftTextCLI

/// `swifttext pdf message.eml` renders HTML its sender wrote, which may not make
/// the renderer read local files; an `.html` file on the user's own disk may.
@Suite("pdf of an .eml reads no local files")
struct PDFMailLocalFilesTests {
	/// A 2×2 RGBA PNG.
	private static let iconPNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mOQTL/0H4gZGEAEiAMAPksHR3+zUn4AAAAASUVORK5CYII="

	@Test("An .eml's local image is not read; the same image in an .html file is")
	func mailMayNotReadLocalFiles() async throws {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eml-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let icon = directory.appendingPathComponent("icon.png")
		try #require(Data(base64Encoded: Self.iconPNG)).write(to: icon)
		let body = "<html><body><p>Receipt</p><img src=\"\(icon.path)\" width=\"10\" height=\"10\"></body></html>"

		let eml = directory.appendingPathComponent("mail.eml")
		try "From: shop@example.com\r\nSubject: Receipt\r\nContent-Type: text/html; charset=utf-8\r\n\r\n\(body)\r\n"
			.write(to: eml, atomically: true, encoding: .utf8)
		let html = directory.appendingPathComponent("page.html")
		try body.write(to: html, atomically: true, encoding: .utf8)

		func embedsImage(_ input: URL) async throws -> Bool {
			let output = input.deletingPathExtension().appendingPathExtension("pdf")
			var command = try PDF.parse([input.path, "-o", output.path, "--engine", "swift"])
			try await command.run()
			return String(decoding: try Data(contentsOf: output), as: UTF8.self).contains("/Subtype /Image")
		}
		let mailEmbeds = try await embedsImage(eml)
		let pageEmbeds = try await embedsImage(html)
		#expect(!mailEmbeds)
		#expect(pageEmbeds)
	}
}
