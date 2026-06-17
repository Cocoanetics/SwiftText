//  SelectorTests.swift
//  SwiftTextCSSTests

import Testing
@testable import SwiftTextCSS

/// A minimal in-memory element used to exercise selector matching.
private final class MockElement: SelectorElement {
	let localName: String
	private let attributes: [String: String]
	weak var parent: MockElement?
	private(set) var children: [MockElement] = []

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
	func appending(_ child: MockElement) -> MockElement {
		child.parent = self
		children.append(child)
		return self
	}
}

@Suite("CSS Selectors")
struct SelectorTests {

	/// html > body > div#main.box > (h1.title, p.intro, p, span[data-x="y"])
	private func sampleTree() -> (root: MockElement, h1: MockElement, intro: MockElement, plain: MockElement, span: MockElement) {
		let html = MockElement("html")
		let body = MockElement("body")
		let div = MockElement("div", ["id": "main", "class": "box"])
		let h1 = MockElement("h1", ["class": "title"])
		let intro = MockElement("p", ["class": "intro lead"])
		let plain = MockElement("p")
		let span = MockElement("span", ["data-x": "y", "lang": "en-US"])
		html.appending(body)
		body.appending(div)
		div.appending(h1)
		div.appending(intro)
		div.appending(plain)
		div.appending(span)
		return (html, h1, intro, plain, span)
	}

	private func matches(_ selector: String, _ element: SelectorElement) -> Bool {
		guard let complexes = parseSelectorList(selector) else {
			Issue.record("failed to parse selector: \(selector)")
			return false
		}
		return complexes.contains { $0.matches(element) }
	}

	@Test("Type, class and id selectors")
	func simpleSelectors() {
		let tree = sampleTree()
		#expect(matches("p", tree.intro))
		#expect(!matches("div", tree.intro))
		#expect(matches(".intro", tree.intro))
		#expect(matches(".lead", tree.intro)) // multi-class attribute
		#expect(!matches(".intro", tree.plain))
		#expect(matches("#main", tree.h1.parentSelectorElement!))
		#expect(matches("p.intro", tree.intro))
		#expect(!matches("p.intro", tree.plain))
	}

	@Test("Descendant and child combinators")
	func combinators() {
		let tree = sampleTree()
		#expect(matches("div p", tree.intro))
		#expect(matches("html p", tree.intro))     // deep descendant
		#expect(matches("div > p", tree.intro))     // direct child
		#expect(!matches("body > p", tree.intro))   // p is not a direct child of body
		#expect(matches("body div p", tree.intro))
	}

	@Test("Sibling combinators")
	func siblings() {
		let tree = sampleTree()
		#expect(matches("h1 + p", tree.intro))       // intro immediately follows h1
		#expect(!matches("h1 + p", tree.plain))       // plain does not immediately follow h1
		#expect(matches("h1 ~ p", tree.plain))        // plain is a later sibling of h1
		#expect(matches(".title + .intro", tree.intro))
	}

	@Test("Attribute selectors")
	func attributes() {
		let tree = sampleTree()
		#expect(matches("[data-x]", tree.span))
		#expect(matches("[data-x=y]", tree.span))
		#expect(matches("span[lang|=en]", tree.span)) // dash-match en-US
		#expect(matches("[lang^=en]", tree.span))
		#expect(matches("[lang$=US]", tree.span))
		#expect(matches("[lang*=n-U]", tree.span))
		#expect(!matches("[data-x=z]", tree.span))
	}

	@Test("Structural pseudo-classes")
	func pseudoClasses() {
		let tree = sampleTree()
		#expect(matches("h1:first-child", tree.h1))
		#expect(!matches("p:first-child", tree.intro))
		#expect(matches("span:last-child", tree.span))
		#expect(matches(":root", tree.h1.parentSelectorElement!.parentSelectorElement!.parentSelectorElement!)) // html
	}

	@Test("Unsupported pseudo-classes never match")
	func unsupportedPseudo() {
		let tree = sampleTree()
		#expect(!matches("p:hover", tree.intro))
		#expect(!matches("p:nth-child(1)", tree.intro))
		#expect(!matches("p::before", tree.intro))
	}

	@Test("Selector lists and specificity")
	func specificity() {
		#expect(parseSelectorList("#a")?.first?.specificity == Specificity(1, 0, 0))
		#expect(parseSelectorList(".a")?.first?.specificity == Specificity(0, 1, 0))
		#expect(parseSelectorList("a")?.first?.specificity == Specificity(0, 0, 1))
		#expect(parseSelectorList("div p")?.first?.specificity == Specificity(0, 0, 2))
		#expect(parseSelectorList("div.cls > p#x")?.first?.specificity == Specificity(1, 1, 2))
		#expect(parseSelectorList("h1, h2, h3")?.count == 3)
	}
}
