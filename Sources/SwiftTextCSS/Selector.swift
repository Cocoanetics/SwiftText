//  Selector.swift
//  SwiftTextCSS
//
//  CSS selector model, specificity, and matching against an abstract element
//  tree. This is the role cssselect2 plays for WeasyPrint, kept independent of
//  any particular DOM via the `SelectorElement` protocol.

import Foundation

/// The element interface the matcher needs. An adapter over the real DOM (e.g.
/// SwiftTextHTML's `DOMElement`) supplies these in the engine module.
public protocol SelectorElement: AnyObject {
	/// The element's lowercased local (tag) name.
	var localName: String { get }
	/// The value of an attribute, looked up case-insensitively by `name`.
	func attributeValue(_ name: String) -> String?
	/// The parent element, or `nil` for the root.
	var parentSelectorElement: SelectorElement? { get }
	/// The previous sibling that is an element, skipping text nodes.
	var previousSelectorSibling: SelectorElement? { get }
	/// The next sibling that is an element, skipping text nodes.
	var nextSelectorSibling: SelectorElement? { get }
}

/// CSS specificity as an `(a, b, c)` triple: ids, then class/attr/pseudo-class,
/// then type/pseudo-element.
public struct Specificity: Comparable, Equatable, Sendable {
	public var a: Int
	public var b: Int
	public var c: Int

	public init(_ a: Int, _ b: Int, _ c: Int) {
		self.a = a
		self.b = b
		self.c = c
	}

	public static let zero = Specificity(0, 0, 0)

	public static func < (lhs: Specificity, rhs: Specificity) -> Bool {
		(lhs.a, lhs.b, lhs.c) < (rhs.a, rhs.b, rhs.c)
	}
}

/// An attribute selector such as `[type="text"]` or `[class~="foo"]`.
public struct AttributeSelector: Equatable, Sendable {
	public enum Match: Equatable, Sendable {
		case exists           // [attr]
		case equals           // [attr=val]
		case includes         // [attr~=val]
		case dashMatch        // [attr|=val]
		case prefix           // [attr^=val]
		case suffix           // [attr$=val]
		case substring        // [attr*=val]
	}
	public var name: String
	public var match: Match
	public var value: String
}

/// A supported structural pseudo-class.
public enum PseudoClass: Equatable, Sendable {
	case root
	case firstChild
	case lastChild
	case onlyChild
}

/// A compound selector: simple selectors with no combinator between them.
public struct CompoundSelector: Equatable, Sendable {
	public var type: String? = nil          // lowercased element name; nil = none
	public var universal: Bool = false
	public var ids: [String] = []
	public var classes: [String] = []
	public var attributes: [AttributeSelector] = []
	public var pseudoClasses: [PseudoClass] = []
	/// Set when an unsupported pseudo-class/element appeared; such a compound
	/// never matches a normal element (conservative, avoids over-matching).
	public var hasUnsupportedPseudo: Bool = false

	var isEmpty: Bool {
		type == nil && !universal && ids.isEmpty && classes.isEmpty
			&& attributes.isEmpty && pseudoClasses.isEmpty && !hasUnsupportedPseudo
	}
}

/// A combinator joining two compound selectors.
public enum Combinator: Equatable, Sendable {
	case descendant          // (whitespace)
	case child               // >
	case nextSibling         // +
	case subsequentSibling   // ~
}

/// A complex selector: a rightmost compound plus combinator-joined ancestors,
/// stored right-to-left for matching.
public struct ComplexSelector: Equatable, Sendable {
	public var rightmost: CompoundSelector
	public var ancestors: [(Combinator, CompoundSelector)]
	public var specificity: Specificity

	public static func == (lhs: ComplexSelector, rhs: ComplexSelector) -> Bool {
		lhs.rightmost == rhs.rightmost && lhs.specificity == rhs.specificity
			&& lhs.ancestors.count == rhs.ancestors.count
			&& zip(lhs.ancestors, rhs.ancestors).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
	}

	/// Whether `element` matches this complex selector.
	public func matches(_ element: SelectorElement) -> Bool {
		guard matchCompound(rightmost, element) else { return false }
		return matchAncestors(ancestors[...], from: element)
	}
}

// MARK: - Matching

private func matchAncestors(_ remaining: ArraySlice<(Combinator, CompoundSelector)>, from element: SelectorElement) -> Bool {
	guard let (combinator, compound) = remaining.first else { return true }
	let rest = remaining.dropFirst()
	switch combinator {
	case .child:
		guard let parent = element.parentSelectorElement else { return false }
		return matchCompound(compound, parent) && matchAncestors(rest, from: parent)
	case .descendant:
		var ancestor = element.parentSelectorElement
		while let current = ancestor {
			if matchCompound(compound, current) && matchAncestors(rest, from: current) { return true }
			ancestor = current.parentSelectorElement
		}
		return false
	case .nextSibling:
		guard let previous = element.previousSelectorSibling else { return false }
		return matchCompound(compound, previous) && matchAncestors(rest, from: previous)
	case .subsequentSibling:
		var sibling = element.previousSelectorSibling
		while let current = sibling {
			if matchCompound(compound, current) && matchAncestors(rest, from: current) { return true }
			sibling = current.previousSelectorSibling
		}
		return false
	}
}

private func matchCompound(_ selector: CompoundSelector, _ element: SelectorElement) -> Bool {
	if selector.hasUnsupportedPseudo { return false }
	if let type = selector.type, type != "*", element.localName != type { return false }
	if !selector.ids.isEmpty {
		let id = element.attributeValue("id")
		for required in selector.ids where required != id { return false }
	}
	if !selector.classes.isEmpty {
		let classList = Set((element.attributeValue("class") ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init))
		for required in selector.classes where !classList.contains(required) { return false }
	}
	for attribute in selector.attributes where !matchAttribute(attribute, element) { return false }
	for pseudo in selector.pseudoClasses where !matchPseudo(pseudo, element) { return false }
	return true
}

private func matchAttribute(_ selector: AttributeSelector, _ element: SelectorElement) -> Bool {
	guard let value = element.attributeValue(selector.name) else { return false }
	switch selector.match {
	case .exists:
		return true
	case .equals:
		return value == selector.value
	case .includes:
		guard !selector.value.isEmpty else { return false }
		return value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).contains { $0 == selector.value[...] }
	case .dashMatch:
		return value == selector.value || value.hasPrefix(selector.value + "-")
	case .prefix:
		return !selector.value.isEmpty && value.hasPrefix(selector.value)
	case .suffix:
		return !selector.value.isEmpty && value.hasSuffix(selector.value)
	case .substring:
		return !selector.value.isEmpty && value.contains(selector.value)
	}
}

private func matchPseudo(_ pseudo: PseudoClass, _ element: SelectorElement) -> Bool {
	switch pseudo {
	case .root:
		return element.parentSelectorElement == nil
	case .firstChild:
		return element.previousSelectorSibling == nil
	case .lastChild:
		return element.nextSelectorSibling == nil
	case .onlyChild:
		return element.previousSelectorSibling == nil && element.nextSelectorSibling == nil
	}
}
