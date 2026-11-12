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
	///
	/// - Parameter loadedImages: Images fetched ahead of layout (see
	///   `RenderOptions.imageLoader`), by `src` attribute value.
	public static func build(
		from element: StyledElement,
		baseURL: URL? = nil,
		loadedImages: LoadedImages = [:],
		warningHandler: ((String) -> Void)? = nil
	) -> Box? {
		let style = element.computedStyle
		if style.display == .none { return nil }

		// Replaced <img>: a leaf carrying the decoded image or a visible
		// placeholder when its source cannot be rendered. Like any inline
		// element it sits in the line, unless it is styled block-level.
		if element.localName == "img" {
			let image = loadImage(
				source: element.attributeValue("src"),
				baseURL: baseURL,
				loadedImages: loadedImages,
				warningHandler: warningHandler)
			let box: Box
			if style.display.isBlockLevel {
				let block = BlockBox(style: style)
				block.image = image
				box = block
			} else {
				let inline = InlineBox(style: style)
				inline.image = image
				box = inline
			}
			box.element = element
			return box
		}

		let childBoxes = buildChildBoxes(of: element, baseURL: baseURL, loadedImages: loadedImages, warningHandler: warningHandler)

		let box: Box
		switch style.display {
		case .inline:
			box = InlineBox(style: style, children: childBoxes)
		case .inlineBlock where !childBoxes.contains(where: { $0 is BlockBox }):
			box = InlineBox(style: style, children: childBoxes)
		default:
			// An inline-block that holds block-level boxes — `<span
			// style="display: inline-block"><p>…</p></span>`, a column `<div>` —
			// lays out as a block: there is no atomic inline-block layout yet,
			// and inline layout would drop the blocks with all they contain.
			var blockStyle = style
			if blockStyle.display == .inlineBlock { blockStyle.display = .block }
			let block = BlockBox(style: blockStyle)
			block.children = normalizeBlockChildren(childBoxes, parentStyle: blockStyle)
			if blockStyle.display == .tableRow {
				block.children = wrappingNonCells(block.children, rowStyle: blockStyle)
			}
			// A block-level link (`<a style="display: block">`, an email button)
			// links its content the way an inline one does.
			if element.localName == "a", let href = element.attributeValue("href") {
				inheritLink(href, into: block)
			}
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

	/// This item's ordinal value per the HTML list-numbering rules: counting
	/// starts at the `<ol start>` value (or 1, or the item count when the list is
	/// `reversed`), steps by one per `<li>`, and an `<li value>` resets it.
	private static func listOrdinal(of element: StyledElement) -> Int {
		guard let parent = element.parent else { return 1 }
		let items = parent.elementChildren.filter { $0.localName == "li" }
		let isOrderedList = parent.localName == "ol"
		let reversed = isOrderedList && parent.attributeValue("reversed") != nil
		let step = reversed ? -1 : 1
		let start = isOrderedList ? integerAttribute("start", of: parent) : nil
		var ordinal = (start ?? (reversed ? items.count : 1)) - step
		for item in items {
			ordinal = integerAttribute("value", of: item) ?? ordinal + step
			if item === element { break }
		}
		return ordinal
	}

	/// An attribute parsed as an HTML valid integer, or `nil` when absent or invalid.
	/// Values are limited to 32 bits (as browsers do), so stepping by one from
	/// them can never overflow `Int`.
	private static func integerAttribute(_ name: String, of element: StyledElement) -> Int? {
		element.attributeValue(name).flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.map(Int.init)
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
		loadedImages: LoadedImages,
		warningHandler: ((String) -> Void)?
	) -> [Box] {
		var result: [Box] = []
		for child in element.children {
			switch child {
			case .element(let childElement):
				guard let box = build(from: childElement, baseURL: baseURL, loadedImages: loadedImages, warningHandler: warningHandler) else {
					continue
				}
				if let inline = box as? InlineBox, inline.children.contains(where: { $0 is BlockBox }) {
					result.append(contentsOf: splittingAroundBlocks(inline))
				} else {
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
		source rawSource: String?,
		baseURL: URL?,
		loadedImages: LoadedImages,
		warningHandler: ((String) -> Void)?
	) -> DecodedImage {
		let source = rawSource?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		guard !source.isEmpty else {
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

		let data: Data
		if let loaded = loadedImages[source] {
			switch loaded {
			case .success(let bytes):
				data = bytes
			case .failure(let error):
				warningHandler?("image source '\(source)' could not be loaded: \(error); rendering a placeholder")
				return missingImagePlaceholder()
			}
		} else {
			guard let url = resolvedImageURL(source, baseURL: baseURL) else {
				warningHandler?("image source '\(source)' is not a local file; rendering a placeholder")
				return missingImagePlaceholder()
			}
			do {
				data = try Data(contentsOf: url)
			} catch {
				warningHandler?("image source '\(source)' could not be read: \(error.localizedDescription); rendering a placeholder")
				return missingImagePlaceholder()
			}
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
	/// The file an image source is read from, or `nil` when it is not a local file.
	static func resolvedImageURL(_ source: String, baseURL: URL?) -> URL? {
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

	/// CSS 2.1 §9.2.1.1: an inline box that holds a block-level box — `<a
	/// href="…"><img style="display: block"></a>`, as HTML email wraps its
	/// images — is broken around it, and the block becomes a sibling of the
	/// inline pieces either side, which the enclosing block container wraps in
	/// anonymous blocks. Inline layout cannot place a block, so without this
	/// the block and everything in it went missing. Nested inline boxes have
	/// been split already, so a block can only be a direct child here.
	private static func splittingAroundBlocks(_ inline: InlineBox) -> [Box] {
		let isAnchor = inline.element.map { element in
			!(element.attributeValue("id") ?? "").isEmpty
				|| (element.localName == "a" && !(element.attributeValue("name") ?? "").isEmpty)
		} ?? false
		// A block split out of a link stays part of it: its text and image link there.
		let href = inline.element?.localName == "a" ? inline.element?.attributeValue("href") : nil
		var pieces: [Box] = []
		var run: [Box] = []
		func flushRun() {
			defer { run = [] }
			// A piece of nothing but collapsible whitespace generates no line box
			// in a browser, so it is left out — all but the first piece of an
			// element with an id, which keeps the target of internal links.
			if run.allSatisfy(isCollapsibleWhitespace) {
				guard isAnchor, pieces.isEmpty else { return }
			}
			let piece = InlineBox(style: inline.style, children: run)
			piece.element = inline.element
			pieces.append(piece)
		}
		for child in inline.children {
			if child is BlockBox {
				flushRun()
				if let href { inheritLink(href, into: child) }
				pieces.append(child)
			} else {
				run.append(child)
			}
		}
		flushRun()
		return pieces
	}

	/// Give `box` and every block inside it a link's `href`, stopping at blocks
	/// a nearer link has claimed already — the tree is built from the inside out.
	private static func inheritLink(_ href: String, into box: Box) {
		guard let block = box as? BlockBox, block.linkHref == nil else { return }
		block.linkHref = href
		for child in block.children {
			inheritLink(href, into: child)
		}
	}

	/// CSS 2.1 §17.2.1: the children of a table row that are not cells — a
	/// `<td style="display: block">`, which email templates use to centre a
	/// column of fixed width — are wrapped, together with their non-cell
	/// neighbours, in an anonymous cell. Table layout places only cells, so
	/// without this their content went missing.
	private static func wrappingNonCells(_ children: [Box], rowStyle: ComputedStyle) -> [Box] {
		func isCell(_ box: Box) -> Bool { (box as? BlockBox)?.style.display == .tableCell }
		guard !children.allSatisfy(isCell) else { return children }

		var result: [Box] = []
		var run: [Box] = []
		func flushRun() {
			defer { run = [] }
			guard !run.isEmpty else { return }
			var cellStyle = ComputedStyle.anonymousBlock(from: rowStyle)
			cellStyle.display = .tableCell
			let cell = BlockBox(style: cellStyle, isAnonymous: true)
			cell.children = run
			result.append(cell)
		}
		for child in children {
			if isCell(child) {
				flushRun()
				result.append(child)
			} else {
				run.append(child)
			}
		}
		flushRun()
		return result
	}

	/// Whether `box` holds nothing but collapsible whitespace: a text box of
	/// spaces, or an inline box (not an image, `<br>` or checkbox) made only
	/// of such boxes.
	private static func isCollapsibleWhitespace(_ box: Box) -> Bool {
		if box is TextBox { return isWhitespaceOnly(box) }
		guard let inline = box as? InlineBox, inline.image == nil,
		      inline.element?.localName != "br", inline.element?.localName != "input" else { return false }
		return inline.children.allSatisfy(isCollapsibleWhitespace)
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
