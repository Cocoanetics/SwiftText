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
		case space(ComputedStyle)
		case forcedBreak(ComputedStyle)
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
			collectInline(child, into: &tokens, href: nil, decorations: decorations)
		}

		// Resolve bidi levels over the whole inline content (per paragraph) so each
		// line can be reordered into visual order. Pure-LTR content skips this.
		var bidiScalars: [Unicode.Scalar] = []
		var tokenScalarStart: [Int] = []
		for token in tokens {
			tokenScalarStart.append(bidiScalars.count)
			switch token {
			case .word(let word, _, _, _): bidiScalars.append(contentsOf: word.unicodeScalars)
			case .checkbox, .image: bidiScalars.append("\u{FFFC}")
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
				let gaps = fragments.count - 1
				var offset = 0.0
				var perGap = 0.0
				switch box.style.textAlign {
				case .center, .webkitCenter: offset = extra / 2
				case .right, .end, .webkitRight: offset = extra
				case .justify: if !isLast, gaps > 0 { perGap = extra / Double(gaps) }
				default: break // start / left
				}
				line.width = penX + perGap * Double(gaps)
				line.fragments = fragments.enumerated().map { index, fragment in
					var positioned = fragment
					positioned.x += contentX + offset + perGap * Double(index)
					positioned.y = lineTop
					positioned.baseline = lineTop + baselineFromTop
					return positioned
				}
			}
			lines.append(line)

			lineTop += lineHeight
			fragments = []
			penX = 0
			pendingSpace = nil
		}

		/// Place an unbreakable inline box — a checkbox or an image — moving to a
		/// new line first if it does not fit after the pending space.
		func placeAtomic(_ control: TextFragment.InlineControl, width: Double, style: ComputedStyle, href: String?, tokenIndex: Int) {
			let precedingSpaceWidth = pendingSpace.map(spaceWidth) ?? 0
			if style.whiteSpace.wraps, penX + precedingSpaceWidth + width > contentWidth, !fragments.isEmpty {
				finishLine(isLast: false)
			} else {
				penX += precedingSpaceWidth
				pendingSpace = nil
			}
			var fragment = TextFragment(text: "", style: style, x: penX, y: 0, width: width, baseline: 0, href: href,
			                            bidiLevel: wordLevel(tokenIndex), font: fonts.font(for: style))
			fragment.inlineControl = control
			fragments.append(fragment)
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
						if let last = fragments.indices.last,
						   fragments[last].inlineControl == nil,
						   !fragments[last].carriesPreservedWhitespace,
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
					// Width of the hyphen a line needs when it ends after segment `index`.
					func hyphenWidth(after index: Int) -> Double {
						guard hyphenBreaks.contains(boundaries[index]) else { return 0 }
						let font = units[boundaries[index] - 1].font
						return font.width(of: "-", size: style.fontSize) + style.letterSpacing
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
									let font = units[boundaries[next - 1] - 1].font
									append([Piece(text: "-", font: font, width: hyphenWidth(after: next - 1))])
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
			for child in inline.children {
				collectInline(child, into: &tokens, href: childHref, decorations: childDecorations)
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

	/// Fit a line's images into it: grow the line until every image's margin
	/// box fits where its `vertical-align` puts it, then record how far below
	/// the line's top each one starts.
	private func placeReplacedFragments(_ fragments: inout [TextFragment], lineHeight: inout Double,
	                                    baselineFromTop: inout Double, textAscent: Double, textDescent: Double) {
		// `middle` centres an image on the baseline raised by half an x-height,
		// taken as the usual half an em.
		func middleLift(_ style: ComputedStyle) -> Double { style.fontSize * 0.25 }

		var above = baselineFromTop
		var below = lineHeight - baselineFromTop
		for fragment in fragments {
			guard case .image(_, let metrics, _) = fragment.inlineControl else { continue }
			switch fragment.style.verticalAlign {
			case .middle:
				above = max(above, metrics.height / 2 + middleLift(fragment.style))
				below = max(below, metrics.height / 2 - middleLift(fragment.style))
			case .textTop:
				below = max(below, metrics.height - textAscent)
			case .textBottom:
				above = max(above, metrics.height - textDescent)
			case .top, .bottom:
				break // aligned to the line's edges, once those are known
			case .baseline, .sub:
				above = max(above, metrics.height)
			}
		}
		for fragment in fragments {
			guard case .image(_, let metrics, _) = fragment.inlineControl else { continue }
			switch fragment.style.verticalAlign {
			case .top: below = max(below, metrics.height - above)
			case .bottom: above = max(above, metrics.height - below)
			default: break
			}
		}
		lineHeight = above + below
		baselineFromTop = above

		for index in fragments.indices {
			guard case .image(let image, let metrics, _) = fragments[index].inlineControl else { continue }
			let style = fragments[index].style
			let top: Double
			switch style.verticalAlign {
			case .middle: top = above - metrics.height / 2 - middleLift(style)
			case .textTop: top = above - textAscent
			case .textBottom: top = above + textDescent - metrics.height
			case .top: top = 0
			case .bottom: top = lineHeight - metrics.height
			case .baseline, .sub: top = above - metrics.height
			}
			fragments[index].inlineControl = .image(image, metrics, top: top)
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
