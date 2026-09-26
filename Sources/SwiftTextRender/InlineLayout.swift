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
		case space(ComputedStyle)
		case forcedBreak(ComputedStyle)
	}

	/// Lay out the inline content of `box` into lines. Returns the content height.
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
			case .checkbox: bidiScalars.append("\u{FFFC}")
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
		func placeBidiLine(_ line: LineBox, _ logical: [TextFragment], baselineFromTop: Double, isFirstLine: Bool) {
			let levels = logical.map { $0.bidiLevel }
			let visual = Bidi.visualOrder(levels: levels)
			var ordered: [TextFragment] = []
			ordered.reserveCapacity(visual.count)
			for index in visual {
				var fragment = logical[index]
				if levels[index] % 2 == 1 {
					fragment.text = String(String.UnicodeScalarView(fragment.text.unicodeScalars.reversed()))
				}
				ordered.append(fragment)
			}

			var total = 0.0
			for (k, fragment) in ordered.enumerated() {
				if k > 0, !ordered[k - 1].carriesPreservedWhitespace,
				   !fragment.carriesPreservedWhitespace {
					total += spaceWidth(ordered[k - 1].style)
				}
				total += fragment.width
			}
			let extra = max(0, contentWidth - total)
			let rtl = box.style.direction == .rtl
			let indent = isFirstLine ? box.style.textIndent : 0
			var x: Double
			switch box.style.textAlign {
			case .center: x = extra / 2
			case .left: x = indent
			case .right: x = extra - indent
			case .start: x = rtl ? extra - indent : indent
			case .end: x = rtl ? indent : extra - indent
			case .justify: x = rtl ? extra - indent : indent // RTL justify → start for now
			}

			line.width = total
			for (k, fragment) in ordered.enumerated() {
				if k > 0, !ordered[k - 1].carriesPreservedWhitespace,
				   !fragment.carriesPreservedWhitespace {
					x += spaceWidth(ordered[k - 1].style)
				}
				var positioned = fragment
				positioned.x = contentX + x
				positioned.y = lineTop
				positioned.baseline = lineTop + baselineFromTop
				line.fragments.append(positioned)
				x += fragment.width
			}
		}

		func finishLine(isLast: Bool) {
			guard !fragments.isEmpty else { pendingSpace = nil; return }
			let lineHeight = fragments.map { $0.style.resolvedLineHeight() }.max() ?? 0
			let ascent = fragments.map { fonts.font(for: $0.style).ascent(size: $0.style.fontSize) }.max() ?? 0
			let descent = fragments.map { fonts.font(for: $0.style).descent(size: $0.style.fontSize) }.max() ?? 0
			// Center the text box within the line height (half-leading).
			let baselineFromTop = ascent + (lineHeight - ascent - descent) / 2

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
				case .center: offset = extra / 2
				case .right, .end: offset = extra
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
				let size = style.fontSize
				let width = leadingMargin + size + trailingMargin
				let precedingSpaceWidth = pendingSpace.map(spaceWidth) ?? 0
				if style.whiteSpace.wraps, penX + precedingSpaceWidth + width > contentWidth, !fragments.isEmpty {
					finishLine(isLast: false)
				} else {
					penX += precedingSpaceWidth
					pendingSpace = nil
				}

				var fragment = TextFragment(
					text: "", style: style, x: penX, y: 0, width: width, baseline: 0,
					bidiLevel: wordLevel(tokenIndex), font: fonts.font(for: style))
				fragment.inlineControl = .checkbox(
					isChecked: isChecked, size: size, leadingMargin: leadingMargin)
				fragments.append(fragment)
				penX += width
			case .word(let rawWord, let style, let href, let decorations):
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
					var segmentStart = 0
					for segmentEnd in preferredBreaks.sorted() + [units.count] {
						let segment = units[segmentStart ..< segmentEnd]
						let segmentWidth = segment.reduce(0) { $0 + $1.width }
						if segmentStart == 0, !fragments.isEmpty, let space = pendingSpace {
							let width = gap(space)
							if penX + width + segmentWidth > contentWidth {
								finishLine(isLast: false)
							} else {
								penX += width
								pendingSpace = nil
							}
						}
						if penX + segmentWidth > contentWidth, !fragments.isEmpty {
							finishLine(isLast: false)
						}
						appendUnits(segment, breakingAnywhere: breakingAnywhere)
						segmentStart = segmentEnd
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
