//  DomStyleContentTests.swift
//  SwiftTextHTMLTests

import Testing
import Foundation
@testable import SwiftTextHTML

@Suite("Raw-text element content (<style>/<script>)")
struct DomStyleContentTests {

	/// First descendant element named `name` (depth-first).
	private func firstElement(_ root: DOMElement, named name: String) -> DOMElement? {
		for case let child as DOMElement in root.children {
			if child.name.lowercased() == name { return child }
			if let found = firstElement(child, named: name) { return found }
		}
		return nil
	}

	@Test("<style> CSS becomes a DOMRawText child, not a text node")
	func styleContentCaptured() async throws {
		let html = "<style>p { color: red }\n.x { margin: 1px }</style><p>hi</p>"
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)

		let style = try #require(firstElement(root, named: "style"))
		let raw = try #require(style.children.compactMap { $0 as? DOMRawText }.first)
		#expect(raw.content == "p { color: red }\n.x { margin: 1px }")
		// The source is a DOMRawText, never a #text node.
		#expect(!style.children.contains { $0.name == "#text" })
	}

	@Test("styleSheets() returns each <style>'s CSS in document order")
	func styleSheetsAccessor() async throws {
		let html = "<head><style>a { color: red }</style></head>" +
			"<body><p>hi</p><style>b { margin: 0 }</style></body>"
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		#expect(root.styleSheets() == ["a { color: red }", "b { margin: 0 }"])
	}

	@Test("CSS text stays out of the document's text")
	func cssNotInText() async throws {
		let html = "<style>p { color: red }</style><p>hi</p>"
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)

		let text = root.text()
		#expect(text.contains("hi"))
		#expect(!text.contains("color")) // the CSS must not leak into text
	}

	@Test("<script> source is captured the same way")
	func scriptContentCaptured() async throws {
		let html = "<script>var a = 1 < 2;</script><p>hi</p>"
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)

		let script = try #require(firstElement(root, named: "script"))
		let raw = try #require(script.children.compactMap { $0 as? DOMRawText }.first)
		#expect(raw.content.contains("var a = 1"))
		#expect(!script.children.contains { $0.name == "#text" })
		#expect(!root.text().contains("var a")) // not document text
	}
}
