import Foundation

/// A stylesheet reference found in the DOM, in document order.
public enum StyleSheetSource: Sendable, Equatable {
	/// CSS from an inline `<style>` element.
	case inline(String)
	/// The `href` of a `<link rel="stylesheet">`, unresolved — resolve it
	/// against the document base URL before fetching.
	case link(href: String)
}

public class DOMElement: DOMNode, @unchecked Sendable {
	// MARK: - Public Properties

	public let name: String
	public let attributes: [AnyHashable: Any]
	public var children: [DOMNode]

	/// Marks elements that are considered layout-only wrappers for Markdown rendering.
	/// (e.g. deeply nested div/span towers in HTML emails). When true, the Markdown renderer
	/// may treat single-child wrapper chains as transparent to avoid deep recursion.
	public var isTransparentWrapper: Bool = false

	// MARK: - Initialization

	init(name: String, attributes: [AnyHashable: Any] = [:]) {
		self.name = name
		self.attributes = attributes
		self.children = []
	}

	// MARK: - Public Functions

	func addChild(_ child: DOMNode) {
		children.append(child)
	}

	public func markdown() -> String {
		markdown(imageResolver: nil)
	}

	/// Renders this element and its subtree to Markdown.
	///
	/// The DOM is converted into a swift-markdown `Document` (see
	/// ``DOMMarkupConverter``) and rendered with swift-markdown's
	/// `MarkupFormatter`, which owns all spacing, list numbering, table padding,
	/// and nested-structure indentation.
	public func markdown(imageResolver: ((String) -> String?)?) -> String {
		DOMMarkupConverter.markdown(from: self, imageResolver: imageResolver)
	}

	public func text() -> String {
		var builder = PlainTextBuilder()
		appendText(to: &builder)
		return builder.text
	}

	/// Writes this element's text into `builder`, which sees the characters of
	/// every node in order and so can collapse whitespace across their
	/// boundaries — something no node can do from its own text alone.
	private func appendText(to builder: inout PlainTextBuilder) {
		if ["script", "style", "iframe", "nav", "meta", "link", "title", "select", "input", "button", "noscript", "footer"].contains(name) {
			return
		}

		switch name {
		case "br":
			builder.appendLineBreak()

		case "ul", "ol":
			var result = ""
			for child in children {
				let childText = child.text().trimmingCharacters(in: .whitespacesAndNewlines)
				guard !childText.isEmpty else { continue }
				result += childText
				result.ensureTwoTrailingNewlines()
			}
			builder.append(result)

		case "li":
			var item = PlainTextBuilder()
			for child in children {
				Self.append(child, to: &item)
			}
			builder.append(item.text.trimmingCharacters(in: .whitespacesAndNewlines))

		case "table":
			var result = ""
			for row in collectTableRows() {
				let rowText = row.text().trimmingCharacters(in: .whitespacesAndNewlines)
				guard !rowText.isEmpty else { continue }
				result += rowText + "\n"
			}
			builder.append(result)

		case "tr":
			let cells = children.map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
			builder.append(cells.filter { !$0.isEmpty }.joined(separator: " | "))

		default:
			for child in children {
				Self.append(child, to: &builder)
			}
		}

		if isBlockLevelElement {
			builder.endBlock()
		}
	}

	private static func append(_ node: DOMNode, to builder: inout PlainTextBuilder) {
		if let element = node as? DOMElement {
			element.appendText(to: &builder)
		} else if let text = node as? DOMText, !text.preserveWhitespace {
			builder.appendCollapsing(text.textValue)
		} else {
			builder.append(node.text())
		}
	}

	/// Every stylesheet reference in this subtree, in document order: inline
	/// `<style>` blocks and `<link rel="stylesheet">` hrefs. Order is preserved
	/// so the cascade is honoured when the two interleave.
	public func styleSheetSources() -> [StyleSheetSource] {
		var sources: [StyleSheetSource] = []
		collectStyleSheetSources(into: &sources)
		return sources
	}

	/// The CSS of every inline `<style>` element in this subtree, in document
	/// order. Mirrors the DOM's `styleSheets`: the source is already in the tree
	/// (as `DOMRawText`), so this needs no HTML re-parse. External `<link>`
	/// sheets are not fetched here — see `HTMLDocument.resolvedStyleSheets()`.
	public func styleSheets() -> [String] {
		styleSheetSources().compactMap { source in
			if case .inline(let css) = source { return css }
			return nil
		}
	}

	private func collectStyleSheetSources(into sources: inout [StyleSheetSource]) {
		switch name.lowercased() {
		case "style":
			let css = children.compactMap { ($0 as? DOMRawText)?.content }.joined()
			if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				sources.append(.inline(css))
			}

		case "link":
			if let rel = (attributes["rel"] as? String)?.lowercased(),
			   rel.split(whereSeparator: \.isWhitespace).contains("stylesheet"),
			   let href = attributes["href"] as? String,
			   !href.isEmpty {
				sources.append(.link(href: href))
			}

		default:
			break
		}

		for case let child as DOMElement in children {
			child.collectStyleSheetSources(into: &sources)
		}
	}

	// MARK: - Plain-text table helpers

	private func collectTableRows() -> [DOMElement] {
		collectTableRows(from: self)
	}

	private func collectTableRows(from element: DOMElement) -> [DOMElement] {
		var rows: [DOMElement] = []
		for child in element.children {
			guard let childElement = child as? DOMElement else { continue }
			if childElement.name == "tr" {
				rows.append(childElement)
				continue
			}

			if ["thead", "tbody", "tfoot"].contains(childElement.name) {
				rows.append(contentsOf: collectTableRows(from: childElement))
			}
		}
		return rows
	}
}

/// Plain text assembled node by node, collapsing whitespace the way a line box
/// does.
///
/// A run of collapsible whitespace becomes one space even when it is spread
/// over several nodes — `<span>Hello </span>\n<span>world</span>` — and none
/// survives at the start of a line, before a line break, or at the end of a
/// block. No single node can decide that from its own text, so the space is
/// held back until the next character shows whether anything on the same line
/// follows it.
private struct PlainTextBuilder {
	private(set) var text = ""
	/// A collapsible space seen since the last character and not yet written.
	private var pendingSpace = false

	/// Appends characters as they are: preserved text, or text that was already
	/// assembled on its own.
	mutating func append(_ string: String) {
		guard let first = string.first else { return }
		if pendingSpace, !first.isWhitespace {
			text += " "
		}
		pendingSpace = false
		text += string
	}

	/// Appends text whose whitespace collapses. A run of it separates words only
	/// once a word precedes it on the same line.
	mutating func appendCollapsing(_ string: String) {
		var remainder = Substring(string)
		while !remainder.isEmpty {
			let whitespace = remainder.prefix(while: \.isWhitespace)
			if !whitespace.isEmpty {
				if let last = text.last, !last.isWhitespace {
					pendingSpace = true
				}
				remainder = remainder.dropFirst(whitespace.count)
			}
			let word = remainder.prefix { !$0.isWhitespace }
			append(String(word))
			remainder = remainder.dropFirst(word.count)
		}
	}

	mutating func appendLineBreak() {
		pendingSpace = false
		text += "\n"
	}

	mutating func endBlock() {
		pendingSpace = false
		text.ensureTwoTrailingNewlines()
	}
}
