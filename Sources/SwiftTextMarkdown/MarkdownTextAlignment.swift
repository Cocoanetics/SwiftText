import Foundation

/// The alignment of body paragraphs and list items for the writers that don't read CSS
/// (Pages): a stylesheet's `text-align` on `p` and `li`, so one stylesheet justifies
/// the text in every format.
///
/// Only plain type selectors count: `p` (also `body p`, `html body p`) for paragraphs,
/// `li` (also `ol li`, `ul li`, `body li`) for list items, and `body` or `html` as an
/// inherited fallback for paragraphs. A selector with a class, id, attribute,
/// pseudo-class or another tag doesn't — `.markdown-alert p`, `blockquote p`, `h1`, `td` —
/// so alert boxes, quotes, headings and table cells keep their own alignment. Rules in
/// `@media` and other at-rules are ignored. A declaration wins as in CSS: `!important`
/// first, then specificity, then order in the stylesheet; a `p` rule beats an inherited
/// `body` one whatever their order. `start` and `end` read as `left` and `right`.
public struct MarkdownTextAlignment: Sendable, Equatable {
	public enum Alignment: String, Sendable, Equatable {
		case left, right, center, justify
	}

	/// No alignment declared: every writer keeps its own.
	public static let unspecified = MarkdownTextAlignment()

	/// The alignment of body paragraphs (`p`, falling back to `body`/`html`), or `nil`.
	public var paragraph: Alignment?
	/// The alignment of list items (`li`), or `nil` when they follow `paragraph`.
	public var listItem: Alignment?

	public init(paragraph: Alignment? = nil, listItem: Alignment? = nil) {
		self.paragraph = paragraph
		self.listItem = listItem
	}

	/// The alignment a stylesheet sets for paragraphs and list items.
	public init(css: String) {
		var winners = [Target: Declaration]()
		var order = 0
		for rule in MarkdownCSSRules.styleRules(in: css) {
			let alignments = MarkdownCSSRules.declarations(in: rule.declarations).compactMap { declaration in
				declaration.name == "text-align" ? Self.alignment(declaration.value).map { ($0, declaration.important) } : nil
			}
			guard !alignments.isEmpty else { continue }
			for selector in rule.selectors {
				guard let match = Self.target(of: selector) else { continue }
				for (alignment, important) in alignments {
					order += 1
					let declaration = Declaration(important: important, specificity: match.specificity, order: order, alignment: alignment)
					if let current = winners[match.target], !declaration.wins(over: current) { continue }
					winners[match.target] = declaration
				}
			}
		}
		self.init(paragraph: (winners[.paragraph] ?? winners[.root])?.alignment, listItem: winners[.listItem]?.alignment)
	}

	// MARK: - Reading the stylesheet

	private enum Target: Hashable {
		case paragraph, listItem, root
	}

	private struct Declaration {
		var important: Bool
		var specificity: Int
		var order: Int
		var alignment: Alignment

		func wins(over other: Declaration) -> Bool {
			(important ? 1 : 0, specificity, order) > (other.important ? 1 : 0, other.specificity, other.order)
		}
	}

	/// What a selector of plain type names targets, and its specificity (the number of
	/// type names), or `nil` when it can't match a body paragraph or list item.
	private static func target(of selector: String) -> (target: Target, specificity: Int)? {
		let parts = selector.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
		guard let last = parts.last, parts.allSatisfy({ $0.range(of: "^[a-z][a-z0-9]*$", options: .regularExpression) != nil })
		else { return nil }
		let ancestors = parts.dropLast()
		let target: Target
		let allowed: Set<String>
		switch last {
		case "p": target = .paragraph; allowed = ["html", "body"]
		case "li": target = .listItem; allowed = ["html", "body", "ol", "ul"]
		case "body": target = .root; allowed = ["html"]
		case "html": target = .root; allowed = []
		default: return nil
		}
		guard ancestors.allSatisfy(allowed.contains) else { return nil }
		return (target, parts.count)
	}

	private static func alignment(_ value: String) -> Alignment? {
		switch value.lowercased() {
		case "left", "start": return .left
		case "right", "end": return .right
		case "center": return .center
		case "justify": return .justify
		default: return nil
		}
	}
}
