//  CascadeTests.swift
//  SwiftTextCSSTests

import Testing
@testable import SwiftTextCSS

/// A mock element supporting attributes (including `style`), parent and siblings.
private final class Element: SelectorElement {
	let localName: String
	private let attributes: [String: String]
	weak var parent: Element?
	private(set) var children: [Element] = []

	init(_ localName: String, _ attributes: [String: String] = [:]) {
		self.localName = localName
		var lowered: [String: String] = [:]
		for (key, value) in attributes { lowered[key.lowercased()] = value }
		self.attributes = lowered
	}

	func attributeValue(_ name: String) -> String? { attributes[name.lowercased()] }
	var parentSelectorElement: SelectorElement? { parent }
	var previousSelectorSibling: SelectorElement? {
		guard let parent, let index = parent.children.firstIndex(where: { $0 === self }), index > 0 else { return nil }
		return parent.children[index - 1]
	}
	var nextSelectorSibling: SelectorElement? {
		guard let parent, let index = parent.children.firstIndex(where: { $0 === self }), index + 1 < parent.children.count else { return nil }
		return parent.children[index + 1]
	}

	@discardableResult
	func adding(_ child: Element) -> Element { child.parent = self; children.append(child); return self }
}

@Suite("CSS Cascade")
struct CascadeTests {

	private func style(_ element: Element, resolver: StyleResolver, parent: ComputedStyle = .initial) -> ComputedStyle {
		resolver.style(for: element, inheriting: parent, rootFontSize: 16)
	}

	@Test("User-agent defaults: block display and margins")
	func uaDefaults() {
		let resolver = StyleResolver()
		let p = style(Element("p"), resolver: resolver)
		#expect(p.display == .block)
		#expect(p.fontSize == 16)
		#expect(p.margin.top == .px(16))    // 1em
		#expect(p.margin.bottom == .px(16))
		#expect(p.color == RGBA(0, 0, 0, 1))
	}

	@Test("User-agent headings: size and weight")
	func uaHeadings() {
		let resolver = StyleResolver()
		let h1 = style(Element("h1"), resolver: resolver)
		#expect(h1.fontSize == 32)           // 2em
		#expect(h1.fontWeight == 700)
		#expect(h1.display == .block)
		#expect(h1.margin.top == .px(32 * 0.67)) // .67em of the h1 font size
	}

	@Test("User-agent inline styling: em is italic, script is hidden")
	func uaInline() {
		let resolver = StyleResolver()
		#expect(style(Element("em"), resolver: resolver).fontStyle == .italic)
		#expect(style(Element("script"), resolver: resolver).display == Display.none)
		#expect(style(Element("b"), resolver: resolver).fontWeight == 700)
	}

	@Test("Author rules override the UA, and em margins follow the new size")
	func authorOverride() {
		let resolver = StyleResolver(authorStyleSheets: ["p { color: red; font-size: 20px }"])
		let p = style(Element("p"), resolver: resolver)
		#expect(p.color == RGBA(1, 0, 0, 1))
		#expect(p.fontSize == 20)
		#expect(p.margin.top == .px(20)) // 1em now resolves against 20px
	}

	@Test("Inline styles beat author rules; !important beats inline")
	func importance() {
		let normal = StyleResolver(authorStyleSheets: ["p { color: red }"])
		#expect(style(Element("p", ["style": "color: green"]), resolver: normal).color == RGBA(0, 0.5019607843137255, 0, 1))

		let important = StyleResolver(authorStyleSheets: ["p { color: red !important }"])
		#expect(style(Element("p", ["style": "color: green"]), resolver: important).color == RGBA(1, 0, 0, 1))
	}

	@Test("Higher specificity wins")
	func specificity() {
		let resolver = StyleResolver(authorStyleSheets: ["p { color: red } .foo { color: blue }"])
		let element = Element("p", ["class": "foo"])
		#expect(style(element, resolver: resolver).color == RGBA(0, 0, 1, 1))
	}

	@Test("Inherited properties flow to children")
	func inheritance() {
		let resolver = StyleResolver(authorStyleSheets: ["div { color: red; font-size: 20px }"])
		let parent = Element("div")
		let child = Element("span")
		parent.adding(child)
		let parentStyle = style(parent, resolver: resolver)
		let childStyle = resolver.style(for: child, inheriting: parentStyle, rootFontSize: 16)
		#expect(childStyle.color == RGBA(1, 0, 0, 1))
		#expect(childStyle.fontSize == 20)
		#expect(childStyle.display == .inline) // display does not inherit
	}

	@Test("Box shorthands expand to edges")
	func boxShorthand() {
		let resolver = StyleResolver(authorStyleSheets: ["div { margin: 10px 20px; padding: 5px }"])
		let div = style(Element("div"), resolver: resolver)
		#expect(div.margin.top == .px(10))
		#expect(div.margin.right == .px(20))
		#expect(div.margin.bottom == .px(10))
		#expect(div.margin.left == .px(20))
		#expect(div.padding.left == .px(5))
	}

	@Test("Border shorthand sets width, style and color")
	func borderShorthand() {
		let resolver = StyleResolver(authorStyleSheets: ["div { border: 2px solid red }"])
		let div = style(Element("div"), resolver: resolver)
		#expect(div.borderWidth.top == 2)
		#expect(div.borderStyle.top == .solid)
		#expect(div.borderColor.top == RGBA(1, 0, 0, 1))
		#expect(div.borderStyle.top.isVisible)
	}

	@Test("text-decoration from UA and author rules")
	func textDecoration() {
		// Links are underlined by the user-agent stylesheet.
		#expect(style(Element("a"), resolver: StyleResolver()).underline)

		let resolver = StyleResolver(authorStyleSheets: ["span { text-decoration: line-through }"])
		let span = style(Element("span"), resolver: resolver)
		#expect(span.lineThrough)
		#expect(span.underline == false)
	}

	@Test("inherit and initial keywords")
	func globalKeywords() {
		let resolver = StyleResolver(authorStyleSheets: [
			"div { color: red } span { color: initial }",
		])
		let parent = Element("div")
		let child = Element("span")
		parent.adding(child)
		let parentStyle = style(parent, resolver: resolver)
		let childStyle = resolver.style(for: child, inheriting: parentStyle, rootFontSize: 16)
		// `initial` resets color to black even though the parent is red.
		#expect(childStyle.color == RGBA(0, 0, 0, 1))
	}
}
