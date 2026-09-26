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

	dismantle(document)
}

@Test
func skippedSiblingDoesNotDefeatDeepInlineUnwrapping() async throws {
	let depth = 2_000
	var html = "<html><body><p><input>"
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

	dismantle(document)
}

@Test
func nonRenderingWrapperSiblingDoesNotDefeatDeepInlineUnwrapping() async throws {
	// The sibling span renders nothing, so the tower is still the paragraph's
	// only content and its indentation must not stop iterative unwrapping.
	let document = try await HTMLDocument(
		data: Data(prettyPrintedSpanTower(before: "<span><input></span>").utf8),
		baseURL: nil)
	#expect(document.markdown() == "*Hello ü*")
	dismantle(document)
}

@Test
func deepInlineWrapperChainKeepsItsSeparatorsFromSurroundingText() async throws {
	// Text on both sides makes the tower's edge whitespace significant: it is
	// the only separator. Unwrapping keeps one space for it on each side
	// instead of falling back to recursion through every wrapper.
	let document = try await HTMLDocument(
		data: Data(prettyPrintedSpanTower(before: "Before", after: "After").utf8),
		baseURL: nil)
	#expect(document.markdown() == "Before *Hello ü* After")
	dismantle(document)
}

@Test
func nonRenderingSiblingOnEveryLevelDoesNotDefeatUnwrapping() async throws {
	let depth = 2_000
	var html = "<html><body><p>"
	for _ in 0..<depth {
		html += "\n<span><span></span><script>x()</script>"
	}
	html += "\n<em>Hello ü</em>\n"
	for _ in 0..<depth {
		html += "</span>\n"
	}
	html += "</p></body></html>"

	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	#expect(document.markdown() == "*Hello ü*")
	dismantle(document)
}

@Test
func renderlessSiblingsOnEveryLevelDoNotDefeatUnwrapping() async throws {
	// An empty anchor, a source-less image and an empty code span each convert
	// to nothing, so none of them makes a wrapper branch.
	let depth = 2_000
	var html = "<html><body><p>"
	for _ in 0..<depth {
		html += "<span><a></a><img><code></code>\n"
	}
	html += "<em>Hello ü</em>"
	for _ in 0..<depth {
		html += "\n</span>"
	}
	html += "</p></body></html>"

	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	#expect(document.markdown() == "*Hello ü*")
	dismantle(document)
}

/// A tower that branches on every level — text beside each nested element —
/// cannot be unwrapped. Past the nesting limit its words are gathered flat
/// instead of recursing once per level until the stack runs out.
@Test(arguments: [
	("<span>x", "</span>"),
	("<b>x<i>", "</i></b>"),
	("<blockquote>x", "</blockquote>"),
	("<ul><li>x", "</li></ul>")
])
func deeplyBranchingMarkupKeepsItsWords(_ level: (open: String, close: String)) async throws {
	let depth = 2_000
	let html = "<html><body><p>" + String(repeating: level.open, count: depth) + "Hello ü"
		+ String(repeating: level.close, count: depth) + "</p></body></html>"

	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	let markdown = document.markdown()
	let text = document.text()
	#expect(markdown.contains("Hello ü"))
	#expect(text.contains("Hello ü"))
	#expect(text.filter { $0 == "x" }.count == depth)
	dismantle(document)
}

/// A paragraph holding a 2,000-deep tower of pretty-printed spans around an
/// emphasised `Hello ü`, with optional markup on either side of the tower. The
/// emphasis survives only if the tower is unwrapped rather than flattened.
private func prettyPrintedSpanTower(before: String = "", after: String = "") -> String {
	let depth = 2_000
	var html = "<html><body><p>" + before
	for _ in 0..<depth {
		html += "<span>\n"
	}
	html += "<em>Hello ü</em>"
	for _ in 0..<depth {
		html += "\n</span>"
	}
	return html + after + "</p></body></html>"
}

/// Swift ARC releases an ownership chain recursively. Dismantle a deliberately
/// pathological fixture iteratively after exercising conversion, so test
/// teardown does not measure an unrelated runtime recursion limit.
private func dismantle(_ document: HTMLDocument) {
	var elements = [document.root]
	var index = 0
	while index < elements.count {
		elements.append(contentsOf: elements[index].children.compactMap { $0 as? DOMElement })
		index += 1
	}
	for element in elements { element.children.removeAll() }
}
