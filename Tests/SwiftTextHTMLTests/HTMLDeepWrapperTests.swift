import Foundation
import SwiftTextHTML
import Testing

@Test
func htmlDeepWrapperChainDoesNotCrash() async throws {
	// Build a pathological wrapper chain that would previously risk stack overflow.
	let depth = 400
	var html = "<html><body>"
	for i in 0..<depth {
		html += (i % 2 == 0) ? "<div class=\"w\">" : "<span style=\"color:#000\">"
	}
	html += "Hello ü"
	for i in (0..<depth).reversed() {
		html += (i % 2 == 0) ? "</div>" : "</span>"
	}
	html += "</body></html>"

	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	let md = document.markdown()
	#expect(md.contains("Hello ü"))
}

@Test
func prettyPrintedDeepWrapperChainDoesNotCrash() async throws {
	// Indentation-only text nodes around each child are not meaningful branches
	// and must not defeat iterative transparent-wrapper unwrapping.
	let depth = 400
	var html = "<html><body>"
	for _ in 0..<depth {
		html += "\n<div class=\"w\">"
	}
	html += "\nHello ü\n"
	for _ in 0..<depth {
		html += "</div>\n"
	}
	html += "</body></html>"

	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	#expect(document.markdown().contains("Hello ü"))
}

@Test
func inlineWrapperUnwrappingPreservesItsTrailingSeparator() async throws {
	let html = "<p><span><span>Hello</span> </span><em>world</em></p>"
	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	#expect(document.markdown() == "Hello *world*")
}

@Test
func prettyPrintedDeepInlineWrapperChainDoesNotCrash() async throws {
	let depth = 2_000
	var html = "<html><body><p>"
	for _ in 0..<depth {
		html += "\n<span>"
	}
	html += "\nHello ü\n"
	for _ in 0..<depth {
		html += "</span>\n"
	}
	html += "</p></body></html>"

	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	#expect(document.markdown().contains("Hello ü"))

	// Swift ARC releases an ownership chain recursively. Dismantle this
	// deliberately pathological fixture iteratively after exercising conversion
	// so test teardown does not measure an unrelated runtime recursion limit.
	var elements = [document.root]
	var index = 0
	while index < elements.count {
		elements.append(contentsOf: elements[index].children.compactMap { $0 as? DOMElement })
		index += 1
	}
	for element in elements { element.children.removeAll() }
}
