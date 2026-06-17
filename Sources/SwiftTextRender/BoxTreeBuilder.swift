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
				block.marker = markerText(for: element)
			}
			box = block
		}
		box.element = element
		return box
	}

	/// The marker string for a list item: an ordinal "N." inside an `<ol>`, a
	/// bullet otherwise.
	private static func markerText(for element: StyledElement) -> String {
		guard let parent = element.parent else { return "•" }
		if parent.localName == "ol" {
			var ordinal = 0
			for sibling in parent.elementChildren {
				if sibling.localName == "li" { ordinal += 1 }
				if sibling === element { break }
			}
			return "\(ordinal)."
		}
		return "•"
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
