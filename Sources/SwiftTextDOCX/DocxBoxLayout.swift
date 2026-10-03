import SwiftTextMarkdown

/// Style ids and names of the paragraph styles SwiftText writes for alert boxes and
/// rules. The reader recognises them by id, or by name when another app rewrote the ids.
enum DocxStyleID {
	static let rule = "SwiftTextRule"
	static let ruleName = "Horizontal Rule"
	private static let calloutPrefix = "SwiftTextCallout-"
	private static let calloutTitlePrefix = "SwiftTextCalloutTitle-"

	/// `SwiftTextCallout-note`: the body paragraphs of a `> [!NOTE]` box.
	static func callout(kind: String) -> String { calloutPrefix + kind }
	/// `SwiftTextCalloutTitle-note`: its title paragraph.
	static func calloutTitle(kind: String) -> String { calloutTitlePrefix + kind }
	/// "Callout Note" / "Callout Note Title", as Word lists them.
	static func calloutName(kind: String, title: Bool) -> String {
		"Callout " + kind.prefix(1).uppercased() + kind.dropFirst() + (title ? " Title" : "")
	}

	/// The alert kind and role of a callout style, from its id or else its name.
	static func callout(styleId: String, name: String?) -> (kind: String, isTitle: Bool)? {
		if styleId.hasPrefix(calloutTitlePrefix) {
			return (String(styleId.dropFirst(calloutTitlePrefix.count)), true)
		}
		if styleId.hasPrefix(calloutPrefix) {
			return (String(styleId.dropFirst(calloutPrefix.count)), false)
		}
		guard let name, name.hasPrefix("Callout ") else { return nil }
		var kind = Substring(name.dropFirst("Callout ".count))
		let isTitle = kind.hasSuffix(" Title")
		if isTitle { kind = kind.dropLast(" Title".count) }
		guard MarkdownAlertBlock.isValidKind(String(kind)) else { return nil }
		return (kind.lowercased(), isTitle)
	}

	static func isRule(styleId: String, name: String?) -> Bool {
		styleId == rule || name == ruleName
	}
}

/// What faces an alert box or a rule from above or below, as far as spacing goes.
enum DocxEdge: Equatable {
	/// An ordinary paragraph or table, with its own space before/after (twips).
	case spacing(Int)
	/// Another alert box.
	case box
	/// A horizontal rule.
	case rule
}

/// Lays out alert boxes and rules the way the CSS (`MarkdownAlertLayout`) does, in
/// Word's paragraph model. Every distance is the CSS `em` value times the body font
/// size, in twips; only the hairlines are fixed.
///
/// How Word draws bordered paragraphs (ECMA-376 §17.3.1.24, and Word's documented
/// behaviour):
/// - Consecutive paragraphs with identical borders and identical left/right indents are
///   one box. The space between them lies inside the box and is shaded.
/// - A border's `w:space` is the padding between text and border (whole points, at most
///   31), and the shading fills it. Side borders are drawn outside the indents, so a
///   box lines up with the text column when its indent is padding + border width.
/// - The first paragraph's space before and the last one's space after lie outside the
///   box: they are its margins.
/// - Word adds one paragraph's space after to the next one's space before, where CSS
///   margins collapse to the larger. A box or rule therefore takes only what its
///   neighbour's own spacing leaves of the CSS margin.
struct DocxBoxLayout {
	/// The body font size in points (1em).
	let fontSize: Double

	/// Space and border width of the invisible top, bottom and right borders (drawn in
	/// the fill colour; Word pads only towards a border), and the rule's line.
	static let hairlineBorderEighths = 4
	static let ruleBorderEighths = 6
	/// The height of the empty paragraphs that only carry spacing (rules, the spacer
	/// between two boxes): an exact 1pt line in 1pt type.
	static let hairlineTwips = 20
	static let hairlineHalfPoints = 2

	func twips(_ em: Double) -> Int { Int((em * fontSize * 20).rounded()) }
	/// A border's `w:space`, in whole points (Word's limit is 31).
	func borderSpace(_ em: Double, extraTwips: Int = 0) -> Int {
		min(31, Int(((em * fontSize) + Double(extraTwips) / 20).rounded()))
	}

	var margin: Int { twips(MarkdownAlertLayout.marginEm) }
	var paddingBlock: Int { borderSpace(MarkdownAlertLayout.paddingBlockEm) }
	var paragraphGap: Int {
		twips(MarkdownAlertLayout.collapsedGap(MarkdownAlertLayout.titleMarginBottomEm, MarkdownAlertLayout.paragraphMarginEm))
	}
	var bodyGap: Int { twips(MarkdownAlertLayout.paragraphMarginEm) }
	var itemGap: Int { twips(MarkdownAlertLayout.listItemMarginEm) }
	var ruleMargin: Int { twips(MarkdownAlertLayout.ruleMarginEm) }
	/// CSS puts half the leading above a line, Word below it: the line after a box or
	/// rule gets that half back as extra margin, so the gap looks as it does in CSS.
	var halfLeading: Int { twips(MarkdownAlertLayout.halfLeadingEm) }

	/// The left border: the CSS border width, in eighths of a point.
	var accentBorderEighths: Int { Int((MarkdownAlertLayout.borderWidthPoints * 8).rounded()) }

	/// Left padding (`w:space` of the left border); `listHang` widens it so that list
	/// bullets hang in the padding while every paragraph keeps the box's one indent.
	func paddingLeft(listHang: Int) -> Int { borderSpace(MarkdownAlertLayout.paddingInlineEm, extraTwips: listHang) }
	var paddingRight: Int { borderSpace(MarkdownAlertLayout.paddingInlineEm) }

	/// The indents that put the box's outer edges on the text column (plus `offset`, a
	/// block quote's indent).
	func leftIndent(listHang: Int, offset: Int) -> Int {
		offset + paddingLeft(listHang: listHang) * 20 + accentBorderEighths * 20 / 8
	}
	var rightIndent: Int { paddingRight * 20 + Self.hairlineBorderEighths * 20 / 8 }

	/// What a neighbour that is itself a box or rule leaves on the side facing us: its
	/// full margin, which it always takes when the next block is a box or rule.
	func facingSpace(_ edge: DocxEdge?) -> Int {
		switch edge {
		case nil: return 0
		case .spacing(let twips): return twips
		case .box: return margin
		case .rule: return ruleMargin
		}
	}

	/// Space before a box's title: the margin above, less what the paragraph above
	/// already leaves (none at the start of the document, as in Pages).
	func boxSpaceBefore(above: DocxEdge?) -> Int {
		above == nil ? 0 : max(0, margin - facingSpace(above))
	}

	/// Space after a box's last paragraph: the margin below, less the next paragraph's
	/// own space before, plus the half-leading of its first line. Before another box it
	/// leaves room for the spacer that keeps the two from joining.
	func boxSpaceAfter(below: DocxEdge?) -> Int {
		switch below {
		case .spacing(let twips): return max(0, margin - twips) + halfLeading
		case .box: return max(0, margin - Self.hairlineTwips)
		case .rule, nil: return margin
		}
	}

	/// A rule's space before and after: the CSS `hr` margins, less the neighbours' own.
	func ruleSpaceBefore(above: DocxEdge?) -> Int {
		above == nil ? 0 : max(0, ruleMargin - facingSpace(above) - Self.hairlineTwips)
	}

	func ruleSpaceAfter(below: DocxEdge?) -> Int {
		switch below {
		case .spacing(let twips): return max(0, ruleMargin - twips) + halfLeading
		case .box, .rule, nil: return ruleMargin
		}
	}
}
