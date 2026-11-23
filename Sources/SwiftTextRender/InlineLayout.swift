//  InlineLayout.swift
//  SwiftTextRender
//
//  Inline layout: the pass that turns a block's inline children into a stream
//  of tokens — words, spaces, breaks — and then packs that stream into line
//  boxes, applying `white-space`, font fallback, bidi reordering and text
//  decoration along the way. Split out of Layout.swift, which owns block and
//  table layout.

import Foundation
import SwiftTextCSS

extension LayoutEngine {

	/// One unit of inline content on its way to a line box. Block layout also
	/// measures a token stream to size a shrink-to-fit box, so this is visible to
	/// Layout.swift.
	enum InlineToken {
		case word(String, ComputedStyle, href: String?, decorations: TextDecorationRuns)
		case checkbox(isChecked: Bool, style: ComputedStyle)
		/// A replaced image, placed as one unbreakable box.
		case image(DecodedImage, ComputedStyle, href: String?)
		/// An inline-block, placed as one unbreakable box.
		case block(BlockBox, ComputedStyle)
		/// The left or right margin, border and padding of an inline box: an
		/// advance that stays with the text beside it.
		case spacer(InlineEdge)
		case space(ComputedStyle)
		case forcedBreak(ComputedStyle)
	}

	/// One side's margin, border and padding of an inline box. Percentages
	/// resolve against the containing block's width, known only at layout.
	struct InlineEdge {
		let margin: Length
		let padding: Length
		let border: Double
		/// The start edge, which moves to the next line with the content after it.
		let isLeading: Bool

		func width(percentageBasis: Double) -> Double {
			max(0, (margin.resolved(percentageBasis: percentageBasis) ?? 0)
				+ (padding.resolved(percentageBasis: percentageBasis) ?? 0) + border)
		}
	}

	/// Lay out the inline content of `box` into lines. Returns the content height.
	// swiftlint:disable:next function_body_length
	func layoutInline(_ box: BlockBox, contentWidth: Double, contentX: Double, contentTop: Double) -> Double {
		var tokens: [InlineToken] = []
		let source = ObjectIdentifier(box)
		let decorations = TextDecorationRuns(
			underline: box.style.underline ? TextDecorationRun(source: source, style: box.style) : nil,
			lineThrough: box.style.lineThrough ? TextDecorationRun(source: source, style: box.style) : nil)
		for child in box.children {
			collectInline(child, into: &tokens, href: box.linkHref, decorations: decorations)
		}

		// Resolve bidi levels over the whole inline content (per paragraph) so each
		// line can be reordered into visual order. Pure-LTR content skips this.
		var bidiScalars: [Unicode.Scalar] = []
		var tokenScalarStart: [Int] = []
		for token in tokens {
			tokenScalarStart.append(bidiScalars.count)
			switch token {
			case .word(let word, _, _, _): bidiScalars.append(contentsOf: word.unicodeScalars)
			case .checkbox, .image, .block: bidiScalars.append("\u{FFFC}")
			case .spacer: bidiScalars.append("\u{200B}")
			case .space: bidiScalars.append(" ")
			case .forcedBreak: bidiScalars.append("\n")
			}
		}
		let baseDirection: BidiDirection = box.style.direction == .rtl ? .rightToLeft : .leftToRight
		let bidiLevels = Bidi.levels(for: bidiScalars, baseDirection: baseDirection)
		let hasRTL = baseDirection == .rightToLeft || bidiLevels.contains { $0 % 2 == 1 }
		func wordLevel(_ tokenIndex: Int) -> UInt8 {
			guard !bidiLevels.isEmpty else { return baseDirection.baseLevel }
			return bidiLevels[min(tokenScalarStart[tokenIndex], bidiLevels.count - 1)]
		}

		var lines: [LineBox] = []
		var fragments: [TextFragment] = []
		var penX = box.style.textIndent // first line indentation (reset to 0 after)
		var pendingSpace: ComputedStyle?
		/// Leading inline edges advanced past since the last fragment. They belong
		/// to the content after them, so a break before that content carries them
		/// to the next line.
		var leadingEdges = 0.0
		/// Indices of fragments that follow a collapsed space: the line's justification
		/// opportunities, independent of how wide word-spacing left the gap.
		var spaceBoundaries = Set<Int>()
		var lineTop = contentTop

		func spaceWidth(_ style: ComputedStyle) -> Double {
			fonts.font(for: style).width(of: " ", size: style.fontSize) + style.wordSpacing
		}

		// Place a line's fragments in bidi visual order: reorder by level, reverse
		// RTL runs, and resolve start/end alignment against the base direction.
		//
		// The line builder placed the fragments in logical order with the gaps it
		// opened between them: a collapsed space, or none at all where two
		// fragments meet inside a word or preserved whitespace travels inside a
		// fragment. Each gap is reordered along with its neighbours, at their
		// level when they share one and otherwise at the lower of the two — the
		// level of the embedding that separates them.
		func placeBidiLine(_ line: LineBox, _ logical: [TextFragment], baselineFromTop: Double, isFirstLine: Bool) {
			var items: [(fragment: TextFragment?, width: Double)] = []
			var levels: [UInt8] = []
			for (index, fragment) in logical.enumerated() {
				if index > 0 {
					let previous = logical[index - 1]
					let gap = fragment.x - (previous.x + previous.width)
					if gap > 0.001 {
						items.append((nil, gap))
						levels.append(min(previous.bidiLevel, fragment.bidiLevel))
					}
				}
				var visualFragment = fragment
				if fragment.bidiLevel % 2 == 1 {
					visualFragment.text = String(String.UnicodeScalarView(fragment.text.unicodeScalars.reversed()))
				}
				items.append((visualFragment, fragment.width))
				levels.append(fragment.bidiLevel)
			}
			let ordered = Bidi.visualOrder(levels: levels).map { items[$0] }

			let total = ordered.reduce(0) { $0 + $1.width }
			let extra = max(0, contentWidth - total)
			let rtl = box.style.direction == .rtl
			let indent = isFirstLine ? box.style.textIndent : 0
			var x: Double
			switch box.style.textAlign {
			case .center, .webkitCenter: x = extra / 2
			case .left, .webkitLeft: x = indent
			case .right, .webkitRight: x = extra - indent
			case .start: x = rtl ? extra - indent : indent
			case .end: x = rtl ? indent : extra - indent
			case .justify: x = rtl ? extra - indent : indent // RTL justify → start for now
			}

			line.width = total
			for item in ordered {
				if var positioned = item.fragment {
					positioned.x = contentX + x
					positioned.y = lineTop
					positioned.baseline = lineTop + baselineFromTop
					line.fragments.append(positioned)
				}
				x += item.width
			}
		}

		func finishLine(isLast: Bool) {
			guard !fragments.isEmpty else { pendingSpace = nil; return }
			let (lineHeight, baselineFromTop) = lineMetrics(&fragments, strut: box.style)
			// Leading edges with no content after them yet start the next line.
			let carried = leadingEdges
			penX -= carried

			let line = LineBox()
			line.x = contentX
			line.y = lineTop
			line.height = lineHeight
			line.baseline = baselineFromTop

			if hasRTL {
				placeBidiLine(line, fragments, baselineFromTop: baselineFromTop, isFirstLine: lines.isEmpty)
			} else {
				// LTR fast path (unchanged): align and place in logical order.
				let extra = max(0, contentWidth - penX)
				// Justification opportunities: boundaries where the line builder opened a gap
				// (a collapsed space), or next to preserved spaces. Fragments that touch
				// (a style change mid-word, before punctuation) stay touching.
				func isSpaceRun(_ fragment: TextFragment) -> Bool {
					!fragment.text.isEmpty && fragment.text.allSatisfy { $0 == " " || $0 == "\t" }
				}
				var opportunities = Set<Int>()
				for index in fragments.indices.dropFirst() {
					let previous = fragments[index - 1]
					if spaceBoundaries.contains(index)
						|| fragments[index].x - (previous.x + previous.width) > 0.001
						|| isSpaceRun(previous) || isSpaceRun(fragments[index]) {
						opportunities.insert(index)
					}
				}
				let gaps = opportunities.count
				var offset = 0.0
				var perGap = 0.0
				switch box.style.textAlign {
				case .center, .webkitCenter: offset = extra / 2
				case .right, .end, .webkitRight: offset = extra
				case .justify: if !isLast, gaps > 0 { perGap = extra / Double(gaps) }
				default: break // start / left
				}
				line.width = penX + perGap * Double(gaps)
				var shift = 0.0
				line.fragments = fragments.enumerated().map { index, fragment in
					if opportunities.contains(index) { shift += perGap }
					var positioned = fragment
					positioned.x += contentX + offset + shift
					positioned.y = lineTop
					positioned.baseline = lineTop + baselineFromTop
					return positioned
				}
			}
			// An inline-block was laid out at the origin; move it to its place.
			for fragment in line.fragments {
				guard case .block(let block, _, let top) = fragment.inlineControl else { continue }
				translate(block, dx: fragment.x, dy: fragment.y + top)
			}
			lines.append(line)

			lineTop += lineHeight
			fragments = []
			spaceBoundaries = []
			penX = carried
			pendingSpace = nil
		}

		/// Place an unbreakable inline box — a checkbox or an image — moving to a
		/// new line first if it does not fit after the pending space.
		func placeAtomic(_ control: TextFragment.InlineControl, width: Double, style: ComputedStyle, href: String?, tokenIndex: Int) {
			let precedingSpaceWidth = pendingSpace.map(spaceWidth) ?? 0
			// The slack lets boxes whose percentage widths add up to the line
			// (two columns of 50%) share it despite rounding.
			if style.whiteSpace.wraps, penX + precedingSpaceWidth + width > contentWidth + 0.01, !fragments.isEmpty {
				finishLine(isLast: false)
			} else {
				penX += precedingSpaceWidth
				if pendingSpace != nil { spaceBoundaries.insert(fragments.count) }
				pendingSpace = nil
			}
			var fragment = TextFragment(text: "", style: style, x: penX, y: 0, width: width, baseline: 0, href: href,
			                            bidiLevel: wordLevel(tokenIndex), font: fonts.font(for: style))
			fragment.inlineControl = control
			fragments.append(fragment)
			leadingEdges = 0
			penX += width
		}

		for (tokenIndex, token) in tokens.enumerated() {
			switch token {
			case .space(let style):
				if !fragments.isEmpty { pendingSpace = style }
			case .forcedBreak(let style):
				if !fragments.isEmpty {
					finishLine(isLast: false)
				} else {
					// A break with nothing on the line still consumes a line's height.
					let height = style.resolvedLineHeight()
					let blank = LineBox()
					blank.x = contentX
					blank.y = lineTop
					blank.height = height
					blank.baseline = height
					lines.append(blank)
					lineTop += height
				}
				pendingSpace = nil
			case .checkbox(let isChecked, let style):
				let leadingMargin = style.margin.left.resolved(percentageBasis: contentWidth) ?? 0
				let trailingMargin = style.margin.right.resolved(percentageBasis: contentWidth) ?? 0
				placeAtomic(.checkbox(isChecked: isChecked, size: style.fontSize, leadingMargin: leadingMargin),
				            width: leadingMargin + style.fontSize + trailingMargin, style: style, href: nil, tokenIndex: tokenIndex)
			case .image(let image, let style, let href):
				let metrics = replacedBoxMetrics(of: image, style: style, containingWidth: contentWidth)
				// `finishLine` decides the vertical position.
				placeAtomic(.image(image, metrics, top: 0), width: metrics.width, style: style, href: href, tokenIndex: tokenIndex)
			case .block(let block, let style):
				let metrics = layoutAtomicBlock(block, containingWidth: contentWidth)
				// Whether it may move to the next line is the line's `white-space`.
				var lineStyle = style
				lineStyle.whiteSpace = box.style.whiteSpace
				placeAtomic(.block(block, metrics, top: 0), width: metrics.width, style: lineStyle, href: nil, tokenIndex: tokenIndex)
			case .spacer(let edge):
				let width = edge.width(percentageBasis: contentWidth)
				penX += width
				if edge.isLeading { leadingEdges += width }
			case .word(let sourceWord, let style, let href, let decorations):
				// Soft hyphens are break opportunities, not glyphs: they leave the
				// text and reappear as a visible hyphen where a line breaks at one.
				let (rawWord, softHyphenBreaks) = removingSoftHyphens(from: sourceWord, style: style)
				// Split the word into runs that share one font (font fallback), then
				// shape each Arabic run into presentation forms. Shaping stays in
				// logical order (one glyph per scalar) so the later bidi pass can
				// reverse the run for visual order; only embedded fonts carry the
				// presentation-form glyphs.
				struct Piece { let text: String; let font: Font; let width: Double }
				var pieces: [Piece] = []
				var wordWidth = 0.0
				for run in fonts.resolveRuns(rawWord, style: style) {
					var text = run.text
					if case .embedded(let embedded) = run.font, ArabicShaper.needsShaping(text) {
						text = ArabicShaper.shape(text, hasForm: { embedded.hasGlyph(for: $0) })
					}
					// letter-spacing adds after every character of the run.
					let width = run.font.width(of: text, size: style.fontSize)
						+ style.letterSpacing * Double(text.unicodeScalars.count)
					pieces.append(Piece(text: text, font: run.font, width: width))
					wordWidth += width
				}
				let level = wordLevel(tokenIndex)
				func append(_ pieces: [Piece]) {
					for piece in pieces {
						leadingEdges = 0
						if let last = fragments.indices.last,
						   fragments[last].inlineControl == nil,
						   !fragments[last].carriesPreservedWhitespace,
						   !spaceBoundaries.contains(fragments.count),
						   !piece.text.allSatisfy({ $0 == " " || $0 == "\t" }),
						   fragments[last].font?.key == piece.font.key,
						   fragments[last].style == style,
						   fragments[last].href == href,
						   fragments[last].decorations == decorations,
						   fragments[last].bidiLevel == level,
						   abs(fragments[last].x + fragments[last].width - penX) < 0.001 {
							fragments[last].text += piece.text
							fragments[last].width += piece.width
							penX += piece.width
							continue
						}
						var fragment = TextFragment(text: piece.text, style: style, x: penX, y: 0,
						                            width: piece.width, baseline: 0, href: href,
						                            bidiLevel: level, font: piece.font)
						fragment.decorations = decorations
						fragments.append(fragment)
						penX += piece.width
					}
				}
				func gap(_ spaceStyle: ComputedStyle) -> Double {
					// word-spacing adds to each inter-word space.
					fonts.font(for: spaceStyle).width(of: " ", size: spaceStyle.fontSize) + spaceStyle.wordSpacing
				}
				func appendWithBreaks(_ pieces: [Piece], preferringSoftBreaks: Bool, breakingAnywhere: Bool) {
					let units = pieces.flatMap { piece in
						piece.text.map { character in
							let text = String(character)
							let width = piece.font.width(of: text, size: style.fontSize)
								+ style.letterSpacing * Double(text.unicodeScalars.count)
							return Piece(text: text, font: piece.font, width: width)
						}
					}
					var preferredBreaks = Set<Int>()
					var hyphenBreaks = Set<Int>()
					if preferringSoftBreaks {
						let word = pieces.map(\.text).joined()
						let utf16BreakOffsets = preferredLineBreakOffsets(in: word)
						var utf16Offset = 0
						for (offset, unit) in units.enumerated() {
							utf16Offset += unit.text.utf16.count
							if utf16BreakOffsets.contains(utf16Offset) {
								preferredBreaks.insert(offset + 1)
							}
						}
						// Where a line may end with a hyphen added: soft hyphens, plus
						// the language's pattern break points under `hyphens: auto`.
						hyphenBreaks = softHyphenBreaks
						if style.hyphens == .auto, let hyphenator = Hyphenator.forLanguage(style.language) {
							hyphenBreaks.formUnion(hyphenator.breakOffsets(in: word))
						}
						hyphenBreaks.subtract(preferredBreaks)
						hyphenBreaks = hyphenBreaks.filter { $0 > 0 && $0 < units.count }
						preferredBreaks.formUnion(hyphenBreaks)
					}
					var chunkText = ""
					var chunkWidth = 0.0
					var chunkFont: Font?
					func flushChunk() {
						guard let font = chunkFont else { return }
						append([Piece(text: chunkText, font: font, width: chunkWidth)])
						chunkText = ""
						chunkWidth = 0
						chunkFont = nil
					}
					func appendUnits(_ units: ArraySlice<Piece>, breakingAnywhere: Bool) {
						for unit in units {
							if breakingAnywhere,
							   penX + chunkWidth + unit.width > contentWidth,
							   !chunkText.isEmpty || !fragments.isEmpty {
								flushChunk()
								finishLine(isLast: false)
							}
							if let font = chunkFont, font.key != unit.font.key {
								flushChunk()
							}
							chunkFont = unit.font
							chunkText += unit.text
							chunkWidth += unit.width
						}
						flushChunk()
					}
					let boundaries = preferredBreaks.sorted() + [units.count]
					let segmentStarts = [0] + boundaries.dropLast()
					let segmentWidths = zip(segmentStarts, boundaries).map { start, end in
						units[start ..< end].reduce(0) { $0 + $1.width }
					}
					// The inserted hyphen goes through font fallback like any other character.
					let hyphenFont = fonts.resolveRuns("-", style: style).first?.font ?? fonts.font(for: style)
					// Width of the hyphen a line needs when it ends after segment `index`.
					func hyphenWidth(after index: Int) -> Double {
						guard hyphenBreaks.contains(boundaries[index]) else { return 0 }
						return hyphenFont.width(of: "-", size: style.fontSize) + style.letterSpacing
					}
					var next = 0
					while next < boundaries.count {
						if next == 0, !fragments.isEmpty, let space = pendingSpace {
							let width = gap(space)
							let first = segmentWidths[0] + (boundaries.count > 1 ? hyphenWidth(after: 0) : 0)
							if penX + width + first > contentWidth {
								finishLine(isLast: false)
							} else {
								penX += width
								spaceBoundaries.insert(fragments.count)
								pendingSpace = nil
							}
						}
						// Take as many segments as fit on this line, leaving room for the
						// hyphen when the line then ends inside the word.
						var taken = next
						var width = 0.0
						while taken < boundaries.count {
							width += segmentWidths[taken]
							let tail = taken == boundaries.count - 1 ? 0 : hyphenWidth(after: taken)
							if penX + width + tail > contentWidth { break }
							taken += 1
						}
						if taken == next {
							if !fragments.isEmpty {
								if next > 0, hyphenBreaks.contains(boundaries[next - 1]) {
									append([Piece(text: "-", font: hyphenFont, width: hyphenWidth(after: next - 1))])
								}
								finishLine(isLast: false)
								continue
							}
							taken = next + 1 // too wide for a line of its own: let it overflow
						}
						appendUnits(units[segmentStarts[next] ..< boundaries[taken - 1]], breakingAnywhere: breakingAnywhere)
						next = taken
					}
				}
				let spaceWidth = pendingSpace.map(gap) ?? 0

				let wraps = style.whiteSpace.wraps
				let breaksAnywhere = style.overflowWrap != .normal || style.wordBreak == .breakWord
				if wraps && style.wordBreak == .breakAll {
					if !fragments.isEmpty, let space = pendingSpace {
						let width = gap(space)
						if penX + width > contentWidth {
							finishLine(isLast: false)
						} else {
							penX += width
							spaceBoundaries.insert(fragments.count)
							pendingSpace = nil
						}
					}
					if penX + wordWidth > contentWidth {
						appendWithBreaks(pieces, preferringSoftBreaks: false, breakingAnywhere: true)
					} else {
						append(pieces)
					}
				} else {
					if !wraps || penX + spaceWidth + wordWidth <= contentWidth + 0.001 {
						if !fragments.isEmpty, let space = pendingSpace {
							penX += gap(space)
							spaceBoundaries.insert(fragments.count)
							pendingSpace = nil
						}
						append(pieces)
					} else {
						appendWithBreaks(pieces, preferringSoftBreaks: true, breakingAnywhere: breaksAnywhere)
					}
				}
			}
		}
		finishLine(isLast: true)

		box.lines = lines
		return lineTop - contentTop
	}

	/// Strips U+00AD from a word and reports the character offsets it marked.
/// Under `hyphens: none` the soft hyphens are dropped without marking
/// anything, since they must not break the word.
private func removingSoftHyphens(from word: String, style: ComputedStyle) -> (word: String, breaks: Set<Int>) {
	guard word.unicodeScalars.contains("\u{00AD}") else { return (word, []) }
	var cleaned = ""
	var breaks = Set<Int>()
	var count = 0
	for character in word {
		if character == "\u{00AD}" {
			if style.hyphens != .none, count > 0 { breaks.insert(count) }
		} else {
			cleaned.append(character)
			count += 1
		}
	}
	return (cleaned, breaks)
}

func collectInline(_ box: Box, into tokens: inout [InlineToken], href: String?, decorations: TextDecorationRuns) {
		if let text = box as? TextBox {
			let style = text.style
			if style.whiteSpace == .pre || style.whiteSpace == .preWrap {
				// Spaces and tabs are preserved verbatim and newlines break the line.
				// They must travel inside word tokens: a `.space` token is a
				// *collapsible* separator, of which a line keeps at most one.
				//
				// `pre` never wraps, so each segment between newlines is one
				// fragment. `pre-wrap` does, so its segments are split at every
				// transition between spaces and non-spaces, giving the line builder
				// somewhere to break without discarding the spaces' width.
				let splitsRuns = style.whiteSpace.wraps
				var segment = ""
				var segmentIsSpace = false
				func flush() {
					guard !segment.isEmpty else { return }
					tokens.append(.word(segment, style, href: href, decorations: decorations))
					segment = ""
				}
				for character in text.text {
					if character == "\n" {
						flush()
						tokens.append(.forcedBreak(style))
					} else if character != "\r" {
						let isSpace = character == " " || character == "\t"
						if splitsRuns, isSpace != segmentIsSpace { flush() }
						segmentIsSpace = isSpace
						segment.append(character)
					}
				}
				flush()
				return
			}
			let content = style.whiteSpace.collapsesWhitespace ? collapseWhitespace(text.text) : text.text
			var word = ""
			func flushWord() {
				if !word.isEmpty { tokens.append(.word(word, style, href: href, decorations: decorations)); word = "" }
			}
			for character in content {
				if character == "\n" && !style.whiteSpace.collapsesWhitespace {
					// Preserved newline (white-space: pre/pre-wrap/pre-line).
					flushWord()
					tokens.append(.forcedBreak(style))
				} else if character == " " || character == "\t" || character == "\n" {
					flushWord()
					tokens.append(.space(style))
				} else {
					word.append(character)
				}
			}
			flushWord()
		} else if let inline = box as? InlineBox {
			if let image = inline.image {
				tokens.append(.image(image, inline.style, href: href))
				return
			}
			if let content = inline.atomicBlock {
				// Inside a link, the block's text and images link there too.
				if let href { BoxTreeBuilder.inheritLink(href, into: content) }
				tokens.append(.block(content, inline.style))
				return
			}
			// A <br> forces a line break.
			if inline.element?.localName == "br" {
				tokens.append(.forcedBreak(inline.style))
				return
			}
			// Checkboxes are replaced inline content: reserve a one-em square and
			// paint it directly rather than relying on a font's symbol coverage.
			if inline.element?.localName == "input",
			   inline.element?.attributeValue("type")?.lowercased() == "checkbox" {
				tokens.append(.checkbox(
					isChecked: inline.element?.attributeValue("checked") != nil,
					style: inline.style))
				return
			}
			// An <a href> establishes a link for its descendant text.
			let childHref: String?
			if inline.element?.localName == "a", let linkURL = inline.element?.attributeValue("href") {
				childHref = linkURL
			} else {
				childHref = href
			}
			let source = ObjectIdentifier(inline)
			let childDecorations = TextDecorationRuns(
				underline: inline.style.underline
					? decorations.underline ?? TextDecorationRun(source: source, style: inline.style)
					: nil,
				lineThrough: inline.style.lineThrough
					? decorations.lineThrough ?? TextDecorationRun(source: source, style: inline.style)
					: nil)
			// The box's own margin, border and padding take up room on the line
			// either side of its content. (They are not painted: an inline box
			// has no background or border here.)
			let style = inline.style
			func isZero(_ length: Length) -> Bool {
				switch length {
				case .px(let value), .percent(let value): return value == 0
				case .auto: return true
				}
			}
			func isEmpty(_ edge: InlineEdge) -> Bool {
				isZero(edge.margin) && isZero(edge.padding) && edge.border == 0
			}
			let left = InlineEdge(margin: style.margin.left, padding: style.padding.left,
			                      border: style.usedBorderWidth(\.left, style: \.left), isLeading: true)
			let right = InlineEdge(margin: style.margin.right, padding: style.padding.right,
			                       border: style.usedBorderWidth(\.right, style: \.right), isLeading: false)
			if !isEmpty(left) { tokens.append(.spacer(left)) }
			for child in inline.children {
				collectInline(child, into: &tokens, href: childHref, decorations: childDecorations)
			}
			if !isEmpty(right) { tokens.append(.spacer(right)) }
		}
	}

	/// Lay out an inline-block at the origin and measure its margin box. With
	/// no width of its own it shrinks to fit its content, up to the line's width.
	func layoutAtomicBlock(_ block: BlockBox, containingWidth: Double) -> AtomicBlockMetrics {
		let style = block.style
		let marginTop = style.margin.top.resolved(percentageBasis: containingWidth) ?? 0
		let marginBottom = style.margin.bottom.resolved(percentageBasis: containingWidth) ?? 0
		let marginLeft = style.margin.left.resolved(percentageBasis: containingWidth) ?? 0
		let marginRight = style.margin.right.resolved(percentageBasis: containingWidth) ?? 0
		var available = containingWidth
		if style.width == .auto, block.image == nil, style.display != .table {
			// Shrink-to-fit (CSS 2.1 §10.3.9), measured over the margin box.
			available = min(max(minContentWidth(of: block), containingWidth), maxContentWidth(of: block))
		}
		let height = layoutBlock(block, containingWidth: available, marginX: 0, borderBoxTop: marginTop)
		// An auto margin is zero on an inline-block: undo any centring.
		let offset = marginLeft - block.x
		if abs(offset) > 0.001 { translate(block, dx: offset, dy: 0) }
		let marginBoxHeight = marginTop + height + marginBottom
		return AtomicBlockMetrics(
			width: marginLeft + block.width + marginRight, height: marginBoxHeight,
			baseline: lastBaseline(in: block) ?? marginBoxHeight)
	}

	/// The baseline of the last line in a laid-out block, in its coordinates.
	private func lastBaseline(in block: BlockBox) -> Double? {
		if block.establishesInlineContext {
			return block.lines.last.map { $0.y + $0.baseline }
		}
		for child in block.children.reversed() {
			if let childBlock = child as? BlockBox, childBlock.image == nil, let baseline = lastBaseline(in: childBlock) {
				return baseline
			}
		}
		return nil
	}

	/// Move a laid-out block and everything in it.
	func translate(_ block: BlockBox, dx: Double, dy: Double) {
		block.x += dx
		block.y += dy
		for line in block.lines {
			line.x += dx
			line.y += dy
			for index in line.fragments.indices {
				line.fragments[index].x += dx
				line.fragments[index].y += dy
				line.fragments[index].baseline += dy
				if case .block(let inner, _, _) = line.fragments[index].inlineControl {
					translate(inner, dx: dx, dy: dy)
				}
			}
		}
		if !block.establishesInlineContext {
			for child in block.children {
				if let childBlock = child as? BlockBox { translate(childBlock, dx: dx, dy: dy) }
			}
		}
	}

	/// A finished line's height and the distance from its top to the baseline.
	/// Text sets them: the tallest line-height, with the text box centred in it
	/// (half-leading). A line of nothing but images still has the block's own
	/// text metrics — its `strut` — as browsers give it, and the images then
	/// stretch it to fit.
	private func lineMetrics(_ fragments: inout [TextFragment], strut: ComputedStyle) -> (height: Double, baselineFromTop: Double) {
		let textStyles = fragments.filter { !$0.isReplaced }.map(\.style)
		let metricStyles = textStyles.isEmpty ? [strut] : textStyles
		var lineHeight = metricStyles.map { $0.resolvedLineHeight() }.max() ?? 0
		let ascent = metricStyles.map { fonts.font(for: $0).ascent(size: $0.fontSize) }.max() ?? 0
		let descent = metricStyles.map { fonts.font(for: $0).descent(size: $0.fontSize) }.max() ?? 0
		var baselineFromTop = ascent + (lineHeight - ascent - descent) / 2
		if fragments.contains(where: \.isReplaced) {
			placeReplacedFragments(&fragments, lineHeight: &lineHeight, baselineFromTop: &baselineFromTop,
			                       textAscent: ascent, textDescent: descent)
		}
		return (lineHeight, baselineFromTop)
	}

	/// Fit a line's images and inline-blocks into it: grow the line until every
	/// one's margin box fits where its `vertical-align` puts it, then record
	/// how far below the line's top each one starts.
	private func placeReplacedFragments(_ fragments: inout [TextFragment], lineHeight: inout Double,
	                                    baselineFromTop: inout Double, textAscent: Double, textDescent: Double) {
		// `middle` centres a box on the baseline raised by half an x-height,
		// taken as the usual half an em.
		func middleLift(_ style: ComputedStyle) -> Double { style.fontSize * 0.25 }
		/// The margin-box height of an atomic fragment and how much of it lies
		/// above its baseline: all of an image, down to its last line for a block.
		func size(of fragment: TextFragment) -> (height: Double, ascent: Double)? {
			switch fragment.inlineControl {
			case .image(_, let metrics, _): return (metrics.height, metrics.height)
			case .block(_, let metrics, _): return (metrics.height, metrics.baseline)
			case .checkbox, nil: return nil
			}
		}

		var above = baselineFromTop
		var below = lineHeight - baselineFromTop
		for fragment in fragments {
			guard let (height, ascent) = size(of: fragment) else { continue }
			switch fragment.style.verticalAlign {
			case .middle:
				above = max(above, height / 2 + middleLift(fragment.style))
				below = max(below, height / 2 - middleLift(fragment.style))
			case .textTop:
				below = max(below, height - textAscent)
			case .textBottom:
				above = max(above, height - textDescent)
			case .top, .bottom:
				break // aligned to the line's edges, once those are known
			case .baseline, .sub:
				above = max(above, ascent)
				below = max(below, height - ascent)
			}
		}
		for fragment in fragments {
			guard let (height, _) = size(of: fragment) else { continue }
			switch fragment.style.verticalAlign {
			case .top: below = max(below, height - above)
			case .bottom: above = max(above, height - below)
			default: break
			}
		}
		lineHeight = above + below
		baselineFromTop = above

		for index in fragments.indices {
			guard let (height, ascent) = size(of: fragments[index]) else { continue }
			let style = fragments[index].style
			let top: Double
			switch style.verticalAlign {
			case .middle: top = above - height / 2 - middleLift(style)
			case .textTop: top = above - textAscent
			case .textBottom: top = above + textDescent - height
			case .top: top = 0
			case .bottom: top = lineHeight - height
			case .baseline, .sub: top = above - ascent
			}
			switch fragments[index].inlineControl {
			case .image(let image, let metrics, _): fragments[index].inlineControl = .image(image, metrics, top: top)
			case .block(let block, let metrics, _): fragments[index].inlineControl = .block(block, metrics, top: top)
			case .checkbox, nil: break
			}
		}
	}

	private func collapseWhitespace(_ text: String) -> String {
		var result = ""
		var previousWasSpace = false
		for character in text {
			let isSpace = character == " " || character == "\t" || character == "\n" || character == "\r"
			if isSpace {
				if !previousWasSpace { result.append(" ") }
				previousWasSpace = true
			} else {
				result.append(character)
				previousWasSpace = false
			}
		}
		return result
	}
}

private extension TextFragment {
	var carriesPreservedWhitespace: Bool {
		guard style.whiteSpace == .pre || style.whiteSpace == .preWrap else { return false }
		return text.first == " " || text.first == "\t" || text.last == " " || text.last == "\t"
	}
}
