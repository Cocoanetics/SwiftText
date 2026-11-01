import Foundation

/// The horizontal alignment of body paragraphs and list items for the writers that
/// don't read CSS (Pages): a stylesheet's `text-align`, as a browser applies it to the
/// `<p>` and `<li>` elements the HTML writer generates. One stylesheet therefore
/// justifies the text in every format.
///
/// A paragraph takes the alignment of a `p` rule, else the one it inherits from `body`
/// or `html`; a list item takes the alignment of an `li` rule, else the one it inherits
/// from `ul`/`ol`, `body` or `html` (the nearest ancestor wins, as CSS inherits). Values
/// are `left`, `right`, `center` and `justify`; `start` and `end` read as `left` and
/// `right`. Between declarations for the same element `!important` wins first, then
/// order in the stylesheet. Only plain type selectors count (`p`, `li`, `body`, …), so
/// `.markdown-alert p` (the alert boxes, which stay left-aligned), `p.note` or
/// `blockquote p` are ignored, as are rules in `@media` and other at-rules. Headings,
/// table cells and alert boxes keep their own alignment.
public struct MarkdownTextAlignment: Sendable, Equatable {
	/// A horizontal text alignment.
	public enum Alignment: String, Sendable, Equatable {
		case left, center, right, justify
	}

	/// The alignment of body paragraphs, or `nil` to keep the writer's default.
	public var paragraph: Alignment?
	/// The alignment of unordered (`ul`) list items, or `nil` to keep the writer's default.
	public var unorderedListItem: Alignment?
	/// The alignment of ordered (`ol`) list items, or `nil` to keep the writer's default.
	public var orderedListItem: Alignment?

	/// No alignment from a stylesheet: every writer keeps its default.
	public static let none = MarkdownTextAlignment()

	public init(paragraph: Alignment? = nil, unorderedListItem: Alignment? = nil, orderedListItem: Alignment? = nil) {
		self.paragraph = paragraph
		self.unorderedListItem = unorderedListItem
		self.orderedListItem = orderedListItem
	}

	/// Aligns paragraphs and both kinds of list item.
	public init(paragraph: Alignment? = nil, listItem: Alignment?) {
		self.init(paragraph: paragraph, unorderedListItem: listItem, orderedListItem: listItem)
	}

	/// The alignment a stylesheet sets for body paragraphs and list items.
	public init(css: String) {
		var winners = [String: (alignment: Alignment, important: Bool)]()
		for rule in MarkdownAlertColors.styleRules(in: css) {
			for (alignment, important) in Self.alignments(in: rule.declarations) {
				for selector in rule.selectors {
					let element = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
					guard Self.elements.contains(element) else { continue }
					// Later declarations win unless the current winner is !important.
					if let current = winners[element], current.important, !important { continue }
					winners[element] = (alignment, important)
				}
			}
		}
		func nearest(_ chain: [String]) -> Alignment? {
			chain.lazy.compactMap { winners[$0]?.alignment }.first
		}
		paragraph = nearest(["p", "body", "html"])
		unorderedListItem = nearest(["li", "ul", "body", "html"])
		orderedListItem = nearest(["li", "ol", "body", "html"])
	}

	/// Whether the stylesheet set no alignment.
	public var isEmpty: Bool { paragraph == nil && unorderedListItem == nil && orderedListItem == nil }

	/// The elements whose `text-align` reaches a paragraph or a list item.
	private static let elements: Set<String> = ["p", "li", "ul", "ol", "body", "html"]

	/// The `text-align` values declared in a rule's block, in order, with whether each
	/// is `!important`.
	private static func alignments(in declarations: String) -> [(Alignment, Bool)] {
		var result = [(Alignment, Bool)]()
		for declaration in declarations.split(separator: ";") {
			guard let colon = declaration.firstIndex(of: ":"),
				  declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "text-align" else { continue }
			var value = String(declaration[declaration.index(after: colon)...])
			let importance = value.range(of: #"!\s*important\s*$"#, options: [.regularExpression, .caseInsensitive])
			if let importance { value.removeSubrange(importance) }
			let alignment: Alignment
			switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
			case "left", "start": alignment = .left
			case "right", "end": alignment = .right
			case "center": alignment = .center
			case "justify", "justify-all": alignment = .justify
			default: continue
			}
			result.append((alignment, importance != nil))
		}
		return result
	}
}
