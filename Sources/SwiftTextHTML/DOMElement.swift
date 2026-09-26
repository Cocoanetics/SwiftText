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
		if ["script", "style", "iframe", "nav", "meta", "link", "title", "select", "input", "button", "noscript", "footer"].contains(name) {
			return ""
		}

		var result = ""

		switch name {
		case "br":
			result += "\n"

		case "ul", "ol":
			for child in children {
				let childText = child.text().trimmingCharacters(in: .whitespacesAndNewlines)
				guard !childText.isEmpty else { continue }
				result += childText
				result.ensureTwoTrailingNewlines()
			}

		case "li":
			let content = children.map { $0.text() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
			guard !content.isEmpty else {
				return ""
			}
			result += content

		case "table":
			let rows = collectTableRows()
			for row in rows {
				let rowText = row.text().trimmingCharacters(in: .whitespacesAndNewlines)
				guard !rowText.isEmpty else { continue }
				result += rowText + "\n"
			}

		case "tr":
			let cells = children.map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
			result += cells.filter { !$0.isEmpty }.joined(separator: " | ")

		default:
			result += childText()
		}

		if isBlockLevelElement {
			result.ensureTwoTrailingNewlines()
		}

		return result
	}

	/// The children's text, with insignificant whitespace between them dropped.
	///
	/// A run of whitespace on its own means two different things depending on
	/// what it separates. Between two inline siblings — `<a>x</a>\n<a>y</a>` — it
	/// is the only thing keeping the words apart, so it collapses to a space and
	/// stays. Against a block boundary, including a block element's own edges,
	/// no text meets across it and it goes, the way a line box trims the start
	/// and end of a block. An inline element's edges are not text boundaries:
	/// `<span> </span>` may itself be the separator between surrounding words.
	private func childText() -> String {
		var result = ""
		var previousNode: DOMNode?
		for (index, child) in children.enumerated() {
			var text = child.text()
			guard child is DOMText, text.allSatisfy(\.isWhitespace) else {
				if let previousNode,
				   !previousNode.startsTextBlock, !child.startsTextBlock,
				   trailingWhitespaceIsCollapsible(in: previousNode),
				   leadingWhitespaceIsCollapsible(in: child),
				   result.last?.isWhitespace == true,
				   text.first?.isWhitespace == true {
					text = String(text.drop(while: \.isWhitespace))
				}
				result += text
				if !text.isEmpty { previousNode = child }
				continue
			}
			let previous = children[..<index].last(where: separatesText)
			let next = children[(index + 1)...].first(where: separatesText)
			if startsTextBlock {
				guard let previous, let next,
				      !previous.startsTextBlock, !next.startsTextBlock else { continue }
			} else if previous?.startsTextBlock == true || next?.startsTextBlock == true {
				continue
			}
			result += text
			previousNode = child
		}
		return result
	}

	private func leadingWhitespaceIsCollapsible(in node: DOMNode) -> Bool {
		if let text = node as? DOMText { return !text.preserveWhitespace }
		guard let element = node as? DOMElement else { return false }
		for child in element.children where !child.text().isEmpty {
			return leadingWhitespaceIsCollapsible(in: child)
		}
		return false
	}

	private func trailingWhitespaceIsCollapsible(in node: DOMNode) -> Bool {
		if let text = node as? DOMText { return !text.preserveWhitespace }
		guard let element = node as? DOMElement else { return false }
		for child in element.children.reversed() where !child.text().isEmpty {
			return trailingWhitespaceIsCollapsible(in: child)
		}
		return false
	}

	/// Whether a run of whitespace beside this node could be separating text
	/// from it. A whitespace-only text node cannot, and neither can a node that
	/// contributes nothing at all — a `<script>`, or an empty `<span>`. A `<br>`
	/// can: its text is a newline, but it is a boundary, not a separator.
	private func separatesText(_ node: DOMNode) -> Bool {
		let text = node.text()
		if text.isEmpty { return false }
		return !(node is DOMText && text.allSatisfy(\.isWhitespace))
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
