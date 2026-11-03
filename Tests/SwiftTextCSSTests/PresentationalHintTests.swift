//  PresentationalHintTests.swift
//  SwiftTextCSSTests

import Testing
@testable import SwiftTextCSS

/// A mock element with attributes and a parent.
private final class Element: SelectorElement {
	let localName: String
	private let attributes: [String: String]
	weak var parent: Element?
	private var children: [Element] = []

	init(_ localName: String, _ attributes: [String: String] = [:]) {
		self.localName = localName
		self.attributes = attributes
	}

	func attributeValue(_ name: String) -> String? { attributes[name.lowercased()] }
	var parentSelectorElement: SelectorElement? { parent }
	var previousSelectorSibling: SelectorElement? { nil }
	var nextSelectorSibling: SelectorElement? { nil }

	@discardableResult
	func adding(_ child: Element) -> Element {
		child.parent = self
		children.append(child)
		return child
	}
}

/// HTML email spells much of its layout in attributes, which HTML maps to CSS
/// as presentational hints.
@Suite("Presentational hints")
struct PresentationalHintTests {
	private let resolver = StyleResolver()

	private func style(_ element: Element, resolver: StyleResolver? = nil, parent: ComputedStyle = .initial) -> ComputedStyle {
		(resolver ?? self.resolver).style(for: element, inheriting: parent, rootFontSize: 16)
	}

	@Test("Dimension attributes become width and height")
	func dimensions() {
		let image = style(Element("img", ["width": "250", "height": " 44 "]))
		#expect(image.width == .px(250))
		#expect(image.height == .px(44))
		#expect(style(Element("table", ["width": "600px"])).width == .px(600))
		#expect(style(Element("table", ["width": "100%"])).width == .percent(100))
		#expect(style(Element("td", ["width": "12.5%"])).width == .percent(12.5))
		// A table or cell width must be non-zero; an image's may be zero.
		#expect(style(Element("td", ["width": "0"])).width == .auto)
		#expect(style(Element("img", ["width": "0"])).width == .px(0))
		#expect(style(Element("td", ["width": "wide"])).width == .auto)
	}

	@Test("Table attributes: cellspacing, cellpadding, border, bgcolor and align")
	func tableAttributes() {
		let table = Element("table", ["cellspacing": "0", "cellpadding": "7", "border": "2",
		                              "bgcolor": "#ffffff", "align": "center"])
		let row = table.adding(Element("tr", ["bgcolor": "f0f0f0"]))
		let cell = row.adding(Element("td"))

		let tableStyle = style(table)
		#expect(tableStyle.borderSpacing == BorderSpacing(horizontal: 0, vertical: 0))
		#expect(tableStyle.backgroundColor == RGBA(1, 1, 1, 1))
		#expect(tableStyle.borderWidth == Edges(2.0))
		#expect(tableStyle.borderStyle == Edges(.outset))
		#expect(tableStyle.margin.left == .auto)
		#expect(tableStyle.margin.right == .auto)
		#expect(style(row, parent: tableStyle).backgroundColor == RGBA(240.0 / 255, 240.0 / 255, 240.0 / 255, 1))

		let cellStyle = style(cell, parent: tableStyle)
		#expect(cellStyle.padding == Edges(.px(7)))
		#expect(cellStyle.borderWidth == Edges(1.0))
		#expect(cellStyle.borderStyle == Edges(.inset))

		// The common border="0" draws nothing.
		let plain = Element("table", ["border": "0"])
		let plainCell = plain.adding(Element("tr")).adding(Element("td"))
		#expect(style(plain).borderStyle == Edges(.none))
		#expect(style(plainCell).borderStyle == Edges(.none))
	}

	@Test("Any CSS for the same property beats a presentational hint")
	func cssBeatsHints() {
		let resolver = StyleResolver(authorStyleSheets: ["* { width: 10px }"])
		#expect(style(Element("img", ["width": "250"]), resolver: resolver).width == .px(10))
		#expect(style(Element("img", ["width": "250", "style": "width: 20px"])).width == .px(20))
		#expect(style(Element("img", ["width": "250", "height": "50"]), resolver: resolver).height == .px(50))
	}

	@Test("align gives divs and cells the legacy alignment, which tables reset")
	func legacyAlignment() {
		let div = Element("div", ["align": "center"])
		let table = div.adding(Element("table"))
		let divStyle = style(div)
		#expect(divStyle.textAlign == .webkitCenter)
		#expect(style(table, parent: divStyle).textAlign == .start)

		#expect(style(Element("p", ["align": "center"])).textAlign == .center)
		#expect(style(Element("td", ["align": "right"])).textAlign == .webkitRight)
		#expect(style(Element("td", ["align": "justify"])).textAlign == .justify)
		#expect(style(Element("center")).textAlign == .webkitCenter)
	}

	@Test("Cells are vertically centred unless valign says otherwise")
	func verticalAlignment() {
		let row = Element("tr")
		let cell = row.adding(Element("td"))
		let rowStyle = style(row)
		#expect(style(cell, parent: rowStyle).verticalAlign == .middle)

		let topRow = Element("tr", ["valign": "top"])
		let topCell = topRow.adding(Element("td"))
		#expect(style(topCell, parent: style(topRow)).verticalAlign == .top)
		#expect(style(Element("td", ["valign": "bottom"]), parent: rowStyle).verticalAlign == .bottom)
	}

	@Test("Image spacing and alignment attributes")
	func imageAttributes() {
		let image = style(Element("img", ["hspace": "4", "vspace": "8", "border": "0", "align": "absmiddle"]))
		#expect(image.margin == Edges(top: .px(8), right: .px(4), bottom: .px(8), left: .px(4)))
		#expect(image.borderWidth == Edges(0.0))
		#expect(image.verticalAlign == .middle)
	}

	@Test("<font> colour, face and legacy size")
	func fontElement() {
		let font = style(Element("font", ["color": "red", "size": "5", "face": "Arial, sans-serif"]))
		#expect(font.color == RGBA(1, 0, 0, 1))
		#expect(font.fontSize == 24)
		#expect(font.fontFamily == ["Arial", "sans-serif"])
		#expect(style(Element("font", ["size": "+1"])).fontSize == 18)
		#expect(style(Element("font", ["size": "-2"])).fontSize == 10)
	}

	@Test("body bgcolor, text colour and margin attributes")
	func bodyAttributes() {
		let body = style(Element("body", ["bgcolor": "#202124", "text": "white", "marginwidth": "0", "topmargin": "5"]))
		#expect(body.backgroundColor == RGBA(32.0 / 255, 33.0 / 255, 36.0 / 255, 1))
		#expect(body.color == RGBA(1, 1, 1, 1))
		#expect(body.margin == Edges(top: .px(5), right: .px(0), bottom: .px(8), left: .px(0)))
	}

	@Test("Attribute values cannot inject CSS of their own")
	func attributesCannotInjectCSS() {
		let cell = style(Element("td", ["bgcolor": "red; display: none", "width": "40px; color: blue"]))
		#expect(cell.display == .tableCell)
		#expect(cell.backgroundColor == nil)
		#expect(cell.width == .px(40))
		#expect(cell.color == RGBA(0, 0, 0, 1))
		#expect(style(Element("font", ["face": "x; color: red"])).color == RGBA(0, 0, 0, 1))
	}
}
