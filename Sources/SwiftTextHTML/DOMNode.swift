import Foundation

public protocol DOMNode {
	var name: String { get }
	func markdown() -> String
	func markdown(imageResolver: ((String) -> String?)?) -> String
	func text() -> String

	/// The node's characters exactly as the source spelled them.
	///
	/// ``text()`` collapses whitespace for *extraction*, where the surrounding
	/// nodes are no longer available; that is lossy at a node boundary, because
	/// a newline or tab ending a text node carries a word separator that no
	/// longer has anywhere to go. A consumer that reassembles the nodes itself —
	/// CSS layout, which collapses per `white-space` and trims per line box —
	/// reads the source instead and keeps the separator.
	var sourceText: String { get }
}

private let blockLevelElements: Set<String> = [
	"p", "div", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
	"blockquote", "pre", "figure", "table", "noscript"
]

public extension DOMNode {
	var isBlockLevelElement: Bool {
		blockLevelElements.contains(name)
	}

	/// Nodes that are not runs of characters have no source of their own.
	var sourceText: String { "" }

	/// Whether this node begins and ends a block of text, so that whitespace
	/// beside it separates nothing.
	///
	/// Wider than ``isBlockLevelElement``, which decides paragraph spacing: the
	/// sectioning and grouping containers start no paragraph of their own, yet
	/// they are just as much a block boundary.
	var startsTextBlock: Bool {
		isBlockLevelElement || [
			"html", "body", "document", "section", "article", "main", "header",
			"footer", "aside", "form", "fieldset", "details", "summary",
			"dl", "dt", "dd", "li", "thead", "tbody", "tfoot", "tr", "th", "td",
			"caption", "figcaption", "address", "hgroup", "hr", "br"
		].contains(name)
	}
}
