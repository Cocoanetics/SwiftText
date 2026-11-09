//  StyledElement.swift
//  SwiftTextRender
//
//  Adapts SwiftTextHTML's DOM (`DOMElement`/`DOMNode`) to the CSS engine: it
//  conforms to `SelectorElement` for selector matching and carries the
//  element's computed style. Building the tree resolves styles top-down so each
//  element inherits from its parent.

import Foundation
import SwiftTextHTML
import SwiftTextCSS

/// A DOM element paired with its computed style and tree links.
public final class StyledElement: SelectorElement {
	/// The wrapped DOM element.
	public let domElement: DOMElement
	/// The element's resolved style (filled while building the tree).
	public internal(set) var computedStyle: ComputedStyle = .initial

	weak var parent: StyledElement?
	/// This element's index among its parent's element children.
	private let elementIndex: Int
	/// All element children, in document order (text nodes excluded).
	public private(set) var elementChildren: [StyledElement] = []

	/// A child of an element box: either a nested element or a run of text.
	public enum Child {
		case element(StyledElement)
		case text(String)
	}
	/// Children in document order, interleaving elements and text.
	public private(set) var children: [Child] = []

	private let attributes: [String: String]

	init(domElement: DOMElement, parent: StyledElement?, elementIndex: Int) {
		self.domElement = domElement
		self.parent = parent
		self.elementIndex = elementIndex
		var lowered: [String: String] = [:]
		for (key, value) in domElement.attributes {
			guard let key = key as? String else { continue }
			lowered[key.lowercased()] = value as? String ?? String(describing: value)
		}
		self.attributes = lowered
	}

	// MARK: - SelectorElement

	public var localName: String { domElement.name.lowercased() }

	public func attributeValue(_ name: String) -> String? {
		attributes[name.lowercased()]
	}

	public var parentSelectorElement: SelectorElement? { parent }

	public var previousSelectorSibling: SelectorElement? {
		guard let parent, elementIndex > 0 else { return nil }
		return parent.elementChildren[elementIndex - 1]
	}

	public var nextSelectorSibling: SelectorElement? {
		guard let parent, elementIndex + 1 < parent.elementChildren.count else { return nil }
		return parent.elementChildren[elementIndex + 1]
	}

	/// The element's own `lang` (or `xml:lang`) attribute, trimmed. Present but
	/// empty means "language unknown" and is kept distinct from absent (`nil`).
	var languageAttribute: String? {
		(attributes["lang"] ?? attributes["xml:lang"])?.trimmingCharacters(in: .whitespaces)
	}

	// MARK: - Building

	/// Build a styled tree from a DOM root, resolving styles top-down.
	public static func build(domElement: DOMElement, resolver: StyleResolver, baseDirection: Direction = .ltr) -> StyledElement {
		let root = StyledElement(domElement: domElement, parent: nil, elementIndex: 0)
		// The document inherits the base direction (overridable by dir/CSS).
		var rootParent = ComputedStyle.initial
		rootParent.direction = baseDirection
		root.computedStyle = resolver.style(for: root, inheriting: rootParent, rootFontSize: ComputedStyle.initial.fontSize)
		// The root element establishes the initial containing block and is always
		// a block container. (SwiftTextHTML wraps documents in a synthetic
		// "document" element with no UA rule, which would otherwise be inline.)
		root.computedStyle.display = .block
		root.computedStyle.language = root.languageAttribute
		let rootFontSize = root.computedStyle.fontSize
		root.buildChildren(resolver: resolver, rootFontSize: rootFontSize)
		return root
	}

	private func buildChildren(resolver: StyleResolver, rootFontSize: Double) {
		var elementIndex = 0
		for node in domElement.children {
			if let childElement = node as? DOMElement {
				let child = StyledElement(domElement: childElement, parent: self, elementIndex: elementIndex)
				elementChildren.append(child)
				children.append(.element(child))
				elementIndex += 1
			} else if node.name == "#text" {
				// Verbatim: `collectInline` collapses it per `white-space`, and the
				// line box drops what is left over at its edges.
				children.append(.text(Self.normalizingNewlines(node.sourceText)))
			}
		}

		// Sibling links are now complete, so styles (and :first-child etc.) resolve
		// correctly. Resolve children, then recurse.
		for child in elementChildren {
			child.computedStyle = resolver.style(for: child, inheriting: computedStyle, rootFontSize: rootFontSize)
			child.computedStyle.language = child.languageAttribute ?? computedStyle.language
			child.buildChildren(resolver: resolver, rootFontSize: rootFontSize)
		}
	}

	/// HTML reads CR LF and a lone CR as LF before it tokenizes (the input
	/// stream preprocessing step). The parser leaves them in place, and email
	/// bodies travel with CR LF line ends — where Swift sees `"\r\n"` as one
	/// `Character` that is neither `"\n"` nor whitespace to the inline tokenizer,
	/// so every source line break would be laid out as a visible word.
	static func normalizingNewlines(_ text: String) -> String {
		guard text.unicodeScalars.contains("\r") else { return text }
		return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
	}
}
