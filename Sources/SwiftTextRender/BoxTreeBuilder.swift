//  BoxTreeBuilder.swift
//  SwiftTextRender
//
//  Builds the box tree from a styled DOM tree, generating anonymous block boxes
//  so that a block container holds either all block-level or all inline-level
//  children (never a mix), and dropping insignificant whitespace.

import Foundation
import SwiftTextCSS

public enum BoxTreeBuilder {

	/// Build a box for a styled element, or `nil` if it is `display: none`.
	public static func build(from element: StyledElement) -> Box? {
		let style = element.computedStyle
		if style.display == .none { return nil }

		// Replaced <img>: a leaf block carrying the decoded image. (Only data:
		// URIs are resolved for now; other sources produce no box.)
		if element.localName == "img" {
			guard let src = element.attributeValue("src"), src.hasPrefix("data:"),
			      let image = ImageDecoder.decode(dataURI: src) else { return nil }
			let box = BlockBox(style: style)
			box.image = image
			box.element = element
			return box
		}

		let childBoxes = buildChildBoxes(of: element)

		let box: Box
		switch style.display {
		case .inline, .inlineBlock:
			box = InlineBox(style: style, children: childBoxes)
		default:
			let block = BlockBox(style: style)
			block.children = normalizeBlockChildren(childBoxes, parentStyle: style)
			if style.display == .listItem {
				let marker = markerText(for: element)
				if !marker.isEmpty { block.marker = marker }
			}
			box = block
		}
		box.element = element
		return box
	}

	/// The marker string for a list item, per its `list-style-type`.
	private static func markerText(for element: StyledElement) -> String {
		switch element.computedStyle.listStyleType {
		case .none: return ""
		case .disc: return "•"
		case .circle: return "◦"
		case .square: return "▪"
		case let ordered:
			return formatOrdinal(listOrdinal(of: element), as: ordered) + "."
		}
	}

	/// This item's 1-based position among its `<li>` siblings.
	private static func listOrdinal(of element: StyledElement) -> Int {
		guard let parent = element.parent else { return 1 }
		var ordinal = 0
		for sibling in parent.elementChildren {
			if sibling.localName == "li" { ordinal += 1 }
			if sibling === element { break }
		}
		return ordinal
	}

	/// Format a 1-based ordinal per a `list-style-type`-like keyword. Also used
	/// to render `@page` margin-box `counter(page, <style>)` values.
	static func formatOrdinal(_ number: Int, as type: ListStyleType) -> String {
		switch type {
		case .lowerAlpha: return alphabetic(number, uppercase: false)
		case .upperAlpha: return alphabetic(number, uppercase: true)
		case .lowerRoman: return roman(number).lowercased()
		case .upperRoman: return roman(number)
		case .arabicIndic: return arabicIndic(number)
		default: return "\(number)" // decimal
		}
	}

	/// Render a non-negative integer with Arabic-Indic digits (U+0660…U+0669).
	private static func arabicIndic(_ number: Int) -> String {
		guard number >= 0 else { return "\(number)" }
		let zero = UnicodeScalar(0x0660)!.value
		var result = ""
		for character in "\(number)" {
			if let digit = character.wholeNumberValue {
				result.append(String(UnicodeScalar(zero + UInt32(digit))!))
			} else {
				result.append(character)
			}
		}
		return result
	}

	/// Bijective base-26: 1→a, 26→z, 27→aa …
	private static func alphabetic(_ number: Int, uppercase: Bool) -> String {
		guard number > 0 else { return "\(number)" }
		var value = number
		var result = ""
		let base = (uppercase ? "A" : "a").unicodeScalars.first!.value
		while value > 0 {
			value -= 1
			result = String(UnicodeScalar(base + UInt32(value % 26))!) + result
			value /= 26
		}
		return result
	}

	private static func roman(_ number: Int) -> String {
		guard number > 0, number < 4000 else { return "\(number)" }
		let table: [(Int, String)] = [
			(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
			(50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
		]
		var value = number
		var result = ""
		for (amount, numeral) in table {
			while value >= amount { result += numeral; value -= amount }
		}
		return result
	}

	private static func buildChildBoxes(of element: StyledElement) -> [Box] {
		var result: [Box] = []
		for child in element.children {
			switch child {
			case .element(let childElement):
				if let box = build(from: childElement) {
					result.append(box)
				}
			case .text(let text):
				// Text inherits the containing element's style.
				result.append(TextBox(style: element.computedStyle, text: text))
			}
		}
		return result
	}

	/// Ensure block containers don't mix block- and inline-level children: wrap
	/// inline runs in anonymous block boxes when block siblings are present.
	private static func normalizeBlockChildren(_ children: [Box], parentStyle: ComputedStyle) -> [Box] {
		let hasBlock = children.contains { $0 is BlockBox }
		if !hasBlock {
			return trimWhitespace(children)
		}

		var result: [Box] = []
		var inlineRun: [Box] = []

		func flushInlineRun() {
			let trimmed = trimWhitespace(inlineRun)
			inlineRun = []
			guard !trimmed.isEmpty else { return }
			let anonymous = BlockBox(style: ComputedStyle.anonymousBlock(from: parentStyle), isAnonymous: true)
			anonymous.children = trimmed
			result.append(anonymous)
		}

		for child in children {
			if child is BlockBox {
				flushInlineRun()
				result.append(child)
			} else {
				inlineRun.append(child)
			}
		}
		flushInlineRun()
		return result
	}

	private static func isWhitespaceOnly(_ box: Box) -> Bool {
		guard let text = box as? TextBox, text.style.whiteSpace.collapsesWhitespace else { return false }
		return text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// Drop whitespace-only text boxes at the start and end of an inline run.
	private static func trimWhitespace(_ boxes: [Box]) -> [Box] {
		var boxes = boxes
		while let first = boxes.first, isWhitespaceOnly(first) { boxes.removeFirst() }
		while let last = boxes.last, isWhitespaceOnly(last) { boxes.removeLast() }
		return boxes
	}
}

extension ComputedStyle {
	/// The style of an anonymous block box: inherited text properties from the
	/// parent, block display, and no margins/padding/border.
	static func anonymousBlock(from parent: ComputedStyle) -> ComputedStyle {
		var style = ComputedStyle.inheriting(from: parent)
		style.display = .block
		return style
	}
}
