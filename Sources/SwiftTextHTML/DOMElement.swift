import Foundation

public class DOMElement: DOMNode, @unchecked Sendable
{
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

	func addChild(_ child: DOMNode)
	{
		children.append(child)
	}

	public func markdown() -> String
	{
		markdown(imageResolver: nil)
	}

	/// Renders this element and its subtree to Markdown.
	///
	/// The DOM is converted into a swift-markdown `Document` (see
	/// ``DOMMarkupConverter``) and rendered with swift-markdown's
	/// `MarkupFormatter`, which owns all spacing, list numbering, table padding,
	/// and nested-structure indentation.
	public func markdown(imageResolver: ((String) -> String?)?) -> String
	{
		DOMMarkupConverter.markdown(from: self, imageResolver: imageResolver)
	}

	public func text() -> String
	{
		if ["script", "style", "iframe", "nav", "meta", "link", "title", "select", "input", "button", "noscript", "footer"].contains(name)
		{
			return ""
		}

		var result = ""

		switch name
		{
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
			result += children.map { $0.text() }.joined()
		}

		if isBlockLevelElement
		{
			result.ensureTwoTrailingNewlines()
		}

		return result
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
