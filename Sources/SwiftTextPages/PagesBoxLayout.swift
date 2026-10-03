import SwiftTextMarkdown

/// Lays out alert boxes and rules the way the CSS (`MarkdownAlertLayout`) does, in
/// Pages' paragraph model. Every distance is the CSS `em` value times the body font
/// size; nothing is a fixed point value except the 1px-style hairlines.
///
/// How Pages draws a framed paragraph (measured on its own PDF export):
/// - Paragraph spacing **collapses** like CSS margins: the gap between two paragraphs
///   is the larger of the first's space after and the second's space before.
/// - A frame's fill covers the part of that gap that exceeds the *previous* paragraph's
///   space after — so a box's top padding is its title's space before minus the space
///   after of the paragraph above it.
/// - The fill stops at the last line of the box: the last paragraph's space after is
///   outside (white). Bottom padding therefore needs one more, empty paragraph inside the
///   box (the "end" paragraph, in tiny type), whose space before is the padding and
///   whose space after is the box's bottom margin.
/// - At the top of a page Pages drops a paragraph's space before. A box therefore opens
///   with an empty "start" paragraph too: its space before is the box's top margin (which
///   may well vanish at a page top) and its space after the top padding, which stays.
enum PagesBoxLayout {
	/// Type size of the empty paragraphs that only carry spacing (box ends, rules), and
	/// the height of their line (Body's 1.2 line spacing).
	static let hairlineFontSize: Float = 1
	static var hairlineLineHeight: Float { hairlineFontSize * 1.2 }

	/// Returns `input` with every alert box spaced like the CSS box (margins, padding,
	/// gaps between its paragraphs, an end paragraph for the bottom padding) and every
	/// rule given the CSS `hr` margins. `fontSize` is the body font size (1em);
	/// `baseSpacing` tells a paragraph's spacing in its own style.
	static func apply(to input: [BodyParagraph], fontSize: Float,
	                  baseSpacing: (BodyParagraph) -> (before: Float, after: Float)) -> [BodyParagraph] {
		let em = fontSize
		func ems(_ value: Double) -> Float { Float(value) * em }
		let margin = ems(MarkdownAlertLayout.marginEm)
		let padding = ems(MarkdownAlertLayout.paddingBlockEm)
		let paragraphGap = ems(MarkdownAlertLayout.collapsedGap(MarkdownAlertLayout.titleMarginBottomEm, MarkdownAlertLayout.paragraphMarginEm))
		let bodyGap = ems(MarkdownAlertLayout.paragraphMarginEm)
		let itemGap = ems(MarkdownAlertLayout.listItemMarginEm)
		let ruleMargin = ems(MarkdownAlertLayout.ruleMarginEm)
		// Pages leads below a line, CSS half above and half below: the next line of text
		// gets CSS's half-leading back as extra margin below a box or rule.
		let halfLeading = ems(MarkdownAlertLayout.halfLeadingEm)

		// 1. Give each box a start and an end paragraph and space its paragraphs.
		var output = [BodyParagraph]()
		var index = 0
		while index < input.count {
			guard let first = input[index].callout else {
				var paragraph = input[index]
				if paragraph.isRule {
					paragraph.spaceBefore = max(0, ruleMargin - hairlineLineHeight)
					paragraph.spaceAfter = ruleMargin + halfLeading
				}
				output.append(paragraph)
				index += 1
				continue
			}
			// The box: a title (or a stray body run) and the body paragraphs of its kind.
			var end = index + 1
			while end < input.count, let role = input[end].callout, !role.isTitle, role.kind == first.kind { end += 1 }
			var box = Array(input[index..<end])

			// Margin above (collapsing with the paragraph above): raise that paragraph's
			// space after to the box margin; the start paragraph repeats it as its space
			// before, so none of the margin is filled.
			var aboveAfter: Float = 0
			if var above = output.popLast() {
				if above.callout?.role == .end {
					// Two boxes in a row: identical frames would join into one box, so an
					// unframed hairline paragraph separates them. Its zero spacing leaves the
					// gap to the previous box's end paragraph (the CSS margin, collapsing).
					output.append(above)
					above = BodyParagraph(text: "", paragraphStyle: PagesStyleID.body, isSeparator: true)
					above.spaceBefore = 0
					above.spaceAfter = 0
					aboveAfter = 0
				} else {
					let own = above.spaceAfter ?? baseSpacing(above).after
					aboveAfter = max(own, margin)
					if aboveAfter > own { above.spaceAfter = aboveAfter }
				}
				output.append(above)
			}
			for k in box.indices {
				var role = box[k].callout!
				let next = k + 1 < box.count ? box[k + 1] : nil
				role.spaceBefore = 0                                   // the start paragraph pads
				if next == nil {
					role.spaceAfter = 0                                    // the end paragraph follows
				} else if role.role == .title {
					role.spaceAfter = paragraphGap
				} else if box[k].listStyle != nil, let next, next.listStyle != nil, next.listLevel >= 0 {
					role.spaceAfter = itemGap
				} else {
					role.spaceAfter = bodyGap
				}
				role.keepWithNext = true                                   // CSS break-inside: avoid
				box[k].callout = role
			}
			var startRole = BodyParagraph.CalloutRole(kind: first.kind, role: .start)
			startRole.spaceBefore = aboveAfter
			startRole.spaceAfter = max(0, padding - hairlineLineHeight)
			startRole.keepWithNext = true
			box.insert(BodyParagraph(text: "", paragraphStyle: PagesStyleID.body, callout: startRole), at: 0)
			var endRole = BodyParagraph.CalloutRole(kind: first.kind, role: .end)
			endRole.spaceBefore = max(0, padding - hairlineLineHeight)
			endRole.spaceAfter = margin + halfLeading
			box.append(BodyParagraph(text: "", paragraphStyle: PagesStyleID.body, callout: endRole))
			output.append(contentsOf: box)
			index = end
		}
		return output
	}
}
