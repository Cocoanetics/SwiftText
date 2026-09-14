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
	public static func build(
		from element: StyledElement,
		baseURL: URL? = nil,
		warningHandler: ((String) -> Void)? = nil
	) -> Box? {
		let style = element.computedStyle
		if style.display == .none { return nil }

		// Replaced <img>: a leaf block carrying the decoded image or a visible
		// placeholder when its source cannot be rendered.
		if element.localName == "img" {
			let box = BlockBox(style: style)
			box.image = loadImage(
				source: element.attributeValue("src"),
				baseURL: baseURL,
				warningHandler: warningHandler)
			box.element = element
			return box
		}

		let childBoxes = buildChildBoxes(of: element, baseURL: baseURL, warningHandler: warningHandler)

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

	private static func buildChildBoxes(
		of element: StyledElement,
		baseURL: URL?,
		warningHandler: ((String) -> Void)?
	) -> [Box] {
		var result: [Box] = []
		for child in element.children {
			switch child {
			case .element(let childElement):
				if let box = build(from: childElement, baseURL: baseURL, warningHandler: warningHandler) {
					result.append(box)
				}
			case .text(let text):
				// Text inherits the containing element's style.
				result.append(TextBox(style: element.computedStyle, text: text))
			}
		}
		return result
	}

	private static func loadImage(
		source: String?,
		baseURL: URL?,
		warningHandler: ((String) -> Void)?
	) -> DecodedImage {
		guard let source, !source.isEmpty else {
			warningHandler?("an <img> element has no source; rendering a placeholder")
			return missingImagePlaceholder()
		}

		if source.hasPrefix("data:") {
			guard let image = ImageDecoder.decode(dataURI: source) else {
				warningHandler?("image data URI could not be decoded; rendering a placeholder")
				return missingImagePlaceholder()
			}
			if image.pdfStream == nil {
				warningHandler?("image data URI uses an unsupported image variant; rendering a placeholder")
			}
			return image
		}

		guard let url = resolvedImageURL(source, baseURL: baseURL) else {
			warningHandler?("image source '\(source)' is not a local file; rendering a placeholder")
			return missingImagePlaceholder()
		}

		let data: Data
		do {
			data = try Data(contentsOf: url)
		} catch {
			warningHandler?("image source '\(source)' could not be read: \(error.localizedDescription); rendering a placeholder")
			return missingImagePlaceholder()
		}

		guard let image = ImageDecoder.decode(data) else {
			warningHandler?("image source '\(source)' has an unsupported format; rendering a placeholder")
			return missingImagePlaceholder()
		}
		if image.pdfStream == nil {
			warningHandler?("image source '\(source)' uses an unsupported image variant; rendering a placeholder")
		}
		return image
	}

	private static func missingImagePlaceholder() -> DecodedImage {
		DecodedImage(width: 300, height: 150, pdfStream: nil)
	}

	/// Resolves relative paths against the document directory and accepts absolute
	/// paths and file URLs. Other URL schemes are deliberately not fetched during
	/// synchronous layout.
	private static func resolvedImageURL(_ source: String, baseURL: URL?) -> URL? {
		#if os(Windows)
		if source.count >= 3 {
			let characters = Array(source)
			if characters[1] == ":", characters[2] == "\\" || characters[2] == "/" {
				return URL(fileURLWithPath: source)
			}
		}
		if source.hasPrefix("\\\\") {
			return URL(fileURLWithPath: source)
		}
		#endif

		if source.hasPrefix("/") {
			return URL(fileURLWithPath: source)
		}
		if let sourceURL = URL(string: source), sourceURL.scheme != nil {
			return sourceURL.isFileURL ? sourceURL : nil
		}
		guard let baseURL,
		      let resolved = URL(string: source, relativeTo: baseURL)?.absoluteURL,
		      resolved.isFileURL else { return nil }
		return resolved
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
