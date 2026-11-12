//  Painter.swift
//  SwiftTextRender
//
//  Paints a laid-out box tree onto one page of a paginated document. The box
//  tree is laid out once as a single tall column (CSS px, y-down); each page
//  maps a vertical slice of that column onto a fixed-size page, clipping to the
//  slice so neighbouring pages' content does not bleed in. A single CTM scales
//  CSS px to PDF pt and the y axis is flipped so glyphs stay upright.

import Foundation
import SwiftTextCSS
import SwiftTextPDFWriter

/// CSS pixels to PDF points: 1px = 1/96in, 1pt = 1/72in.
let pxToPt = 0.75

/// The four page margins, in CSS pixels.
public struct PageMargins: Equatable {
	public var top: Double
	public var right: Double
	public var bottom: Double
	public var left: Double

	public init(top: Double, right: Double, bottom: Double, left: Double) {
		self.top = top
		self.right = right
		self.bottom = bottom
		self.left = left
	}

	public init(_ all: Double) {
		self.init(top: all, right: all, bottom: all, left: all)
	}

	var horizontal: Double { left + right }
	var vertical: Double { top + bottom }

	/// Each side raised to at least `floor`.
	func floored(at floor: Double) -> PageMargins {
		PageMargins(top: max(top, floor), right: max(right, floor), bottom: max(bottom, floor), left: max(left, floor))
	}
}

/// Where a page sits within the laid-out column.
public struct PageGeometry {
	public let pageWidthPx: Double
	public let pageHeightPx: Double
	public let margins: PageMargins
	/// The column y-coordinate shown at the top of this page's content area.
	public let columnTop: Double
	/// The height of the column slice shown on this page.
	public let sliceHeightPx: Double
	/// Space reserved above the column slice for repeated table headers.
	public let contentOffsetPx: Double
	/// Horizontal shift of everything on the page, for mirrored binding margins:
	/// the column is laid out against the left margin, a left or right page moves it.
	public let offsetXPx: Double

	/// The top margin; equal to every side when the margins are uniform.
	public var marginPx: Double { margins.top }

	/// A page with the same margin on all four sides.
	public init(pageWidthPx: Double, pageHeightPx: Double, marginPx: Double,
	            columnTop: Double, sliceHeightPx: Double, contentOffsetPx: Double = 0, offsetXPx: Double = 0) {
		self.init(pageWidthPx: pageWidthPx, pageHeightPx: pageHeightPx, margins: PageMargins(marginPx),
		          columnTop: columnTop, sliceHeightPx: sliceHeightPx, contentOffsetPx: contentOffsetPx, offsetXPx: offsetXPx)
	}

	public init(pageWidthPx: Double, pageHeightPx: Double, margins: PageMargins,
	            columnTop: Double, sliceHeightPx: Double, contentOffsetPx: Double = 0, offsetXPx: Double = 0) {
		self.offsetXPx = offsetXPx
		self.pageWidthPx = pageWidthPx
		self.pageHeightPx = pageHeightPx
		self.margins = margins
		self.columnTop = columnTop
		self.sliceHeightPx = sliceHeightPx
		self.contentOffsetPx = contentOffsetPx
	}
}

public final class Painter {
	public let stream = PDFStream()
	private var geometry: PageGeometry
	private let fonts: FontBook

	private let builder: FontResourceBuilder
	private var linkAnnotations: [PDFDictionary] = []
	private let internalAnchors: Set<String>
	/// Annotations whose `href` names a known anchor. Their `/A` action is a
	/// `/URI` placeholder until the caller, who knows the page objects, swaps in
	/// a `/GoTo`.
	public private(set) var internalLinks: [(annotation: PDFDictionary, id: String)] = []
	private var paintOffsetY = 0.0
	private var paintingRepeatedHeader = false

	public init(geometry: PageGeometry, fonts: FontBook, builder: FontResourceBuilder, compress: Bool = true,
	            internalAnchors: Set<String> = []) {
		self.internalAnchors = internalAnchors
		self.geometry = geometry
		self.fonts = fonts
		self.builder = builder
		// Page content streams are glyph-drawing operators — highly repetitive
		// and several times larger uncompressed. Deflate them (/FlateDecode).
		stream.compressed = compress
		// Map CSS px (y-down) to PDF pt (y-up) for the whole page.
		stream.setMatrix(pxToPt, 0, 0, pxToPt, geometry.offsetXPx * pxToPt, 0)
		// Save this (unclipped) state so margin-box painting can later restore
		// it: the clip below must not apply there, since margin boxes live
		// outside the content slice, in the page's margin area.
		stream.pushState()
		// Clip to this page's content slice so other pages don't bleed in.
		let contentWidth = geometry.pageWidthPx - geometry.margins.horizontal
		let paintedHeight = min(geometry.pageHeightPx - geometry.margins.vertical,
		                        geometry.contentOffsetPx + geometry.sliceHeightPx)
		stream.rectangle(geometry.margins.left,
		                 geometry.pageHeightPx - geometry.margins.top - paintedHeight,
		                 contentWidth, paintedHeight)
		stream.clip()
		stream.endPath()
	}

	/// The column-coordinate range this page shows (y-down).
	private var sliceTop: Double { geometry.columnTop }
	private var sliceBottom: Double { geometry.columnTop + geometry.sliceHeightPx }

	/// Whether a box occupying column rows `[top, top + height]` is at least
	/// partly on this page — used to prune whole subtrees (and their draw
	/// operators) that fall outside the slice. Without this, every page's content
	/// stream would carry the entire document's drawing, making a paginated
	/// render O(pages × document) in both time and output size.
	private func blockIntersectsSlice(top: Double, height: Double) -> Bool {
		if paintingRepeatedHeader { return true }
		return top + height >= sliceTop - 0.5 && top <= sliceBottom + 0.5
	}

	/// Whether a box overlaps this page by more than rounding slack, rather than
	/// merely touching its top or bottom edge. Pagination moves a block image to
	/// the next page whole, so one that only touches the edge belongs to the
	/// neighbouring page: painting it here, clipped, would leave a sliver.
	private func boxOverlapsSlice(top: Double, height: Double) -> Bool {
		if paintingRepeatedHeader { return true }
		return top + height > sliceTop + 0.5 && top < sliceBottom - 0.5
	}

	/// Whether a line whose top sits at column `top` belongs to this page.
	/// Pagination breaks at line boundaries, so each line has exactly one home
	/// page: the slice whose half-open `[top, bottom)` range contains its top.
	/// Keying on the top (rather than an inclusive overlap) avoids painting a
	/// boundary line as a clipped sliver on the preceding page too.
	private func lineOnThisPage(_ top: Double) -> Bool {
		if paintingRepeatedHeader { return true }
		return top >= sliceTop - 0.5 && top < sliceBottom - 0.5
	}

	/// Page y (from page top) for a column y-coordinate.
	private func pageY(_ columnY: Double) -> Double {
		geometry.margins.top + geometry.contentOffsetPx + (columnY - geometry.columnTop) + paintOffsetY
	}

	/// Lower-left y (PDF y-up) for a box whose column top and height are given.
	private func yUp(columnTop: Double, height: Double) -> Double {
		geometry.pageHeightPx - (pageY(columnTop) + height)
	}

	/// Paint the box tree onto this page.
	public func paint(_ box: Box) {
		if let block = box as? BlockBox {
			// Skip boxes (and their subtrees) that lie entirely off this page. In
			// normal flow a child's extent is contained by its parent's, so pruning
			// a non-intersecting block can't drop visible descendants.
			guard blockIntersectsSlice(top: block.y, height: block.height) else { return }
			if block.image != nil, !boxOverlapsSlice(top: block.y, height: block.height) { return }
			paintBackground(block)
			paintBorders(block)
			if let image = block.image {
				paintImage(block, image: image)
			} else if block.establishesInlineContext {
				for line in block.lines where lineOnThisPage(line.y) {
					for fragment in line.fragments {
						if let control = fragment.inlineControl {
							paintInlineControl(control, fragment: fragment)
						} else {
							paintText(fragment)
						}
					}
					paintDecorations(in: line.fragments)
				}
			} else {
				for child in block.children {
					paint(child)
				}
			}
		}
		// Inline and text boxes are painted through their block's line fragments.
	}

	// MARK: - Inline controls

	private func paintInlineControl(_ control: TextFragment.InlineControl, fragment: TextFragment) {
		switch control {
		case .checkbox(let isChecked, let size, let leadingMargin):
			let x = fragment.x + leadingMargin
			let lineHeight = fragment.style.resolvedLineHeight()
			let top = fragment.y + max(0, (lineHeight - size) / 2)
			let bottom = geometry.pageHeightPx - pageY(top) - size
			let color = fragment.style.color
			let outlineWidth = max(1, size / 16)

			stream.pushState()
			stream.setColorRGB(color.red, color.green, color.blue, stroke: true)
			stream.setLineWidth(outlineWidth)
			let inset = outlineWidth / 2
			stream.rectangle(x + inset, bottom + inset, size - outlineWidth, size - outlineWidth)
			stream.stroke()

			if isChecked {
				stream.setLineWidth(max(1.5, size / 9))
				stream.setLineCap(1)
				stream.setLineJoin(1)
				stream.moveTo(x + size * 0.20, bottom + size * 0.52)
				stream.lineTo(x + size * 0.42, bottom + size * 0.28)
				stream.lineTo(x + size * 0.82, bottom + size * 0.74)
				stream.stroke()
			}
			stream.popState()
		case .image(let image, let metrics, let top):
			let marginTop = fragment.y + top
			let borderX = fragment.x + metrics.borderX
			let borderTop = marginTop + metrics.borderY
			paintBackground(fragment.style.backgroundColor, x: borderX, top: borderTop,
			                width: metrics.borderWidth, height: metrics.borderHeight)
			paintBorders(metrics.border, colors: fragment.style.borderColor, x: borderX, top: borderTop,
			             width: metrics.borderWidth, height: metrics.borderHeight)
			drawImage(image, x: fragment.x + metrics.contentX, top: marginTop + metrics.contentY,
			          width: metrics.contentWidth, height: metrics.contentHeight)
			if let href = fragment.href {
				addLinkAnnotation(x: fragment.x, width: metrics.width, top: marginTop,
				                  bottom: marginTop + metrics.height, anchor: fragment.baseline, href: href)
			}
		}
	}

	/// Paint a table header group at the top of a continuation page. Its original
	/// column position is left intact in the laid-out tree; only this paint pass is
	/// translated, so the same header can be reused by every page fragment.
	func paintRepeatedTableHeader(_ header: BlockBox) {
		paintingRepeatedHeader = true
		paintOffsetY = geometry.columnTop - header.y - geometry.contentOffsetPx
		paint(header)
		paintOffsetY = 0
		paintingRepeatedHeader = false
	}

	// MARK: - Backgrounds and borders

	private func paintBackground(_ box: Box) {
		paintBackground(box.style.backgroundColor, x: box.x, top: box.y, width: box.width, height: box.height)
	}

	/// Fill a border box, given in column coordinates, with its background.
	private func paintBackground(_ color: RGBA?, x: Double, top: Double, width: Double, height: Double) {
		guard let color, color.alpha > 0 else { return }
		stream.pushState()
		stream.setColorRGB(color.red, color.green, color.blue)
		stream.rectangle(x, yUp(columnTop: top, height: height), width, height)
		stream.fill()
		stream.popState()
	}

	private func paintBorders(_ box: Box) {
		let style = box.style
		let colors = box.resolvedCollapsedBorders.map {
			Edges(
				top: $0.top?.color ?? style.borderColor.top,
				right: $0.right?.color ?? style.borderColor.right,
				bottom: $0.bottom?.color ?? style.borderColor.bottom,
				left: $0.left?.color ?? style.borderColor.left)
		} ?? style.borderColor
		paintBorders(box.usedBorder, colors: colors, x: box.x, top: box.y, width: box.width, height: box.height)
	}

	/// Draw the edges of a border box given in column coordinates.
	private func paintBorders(_ border: Edges<Double>, colors: Edges<RGBA>,
	                          x: Double, top: Double, width: Double, height: Double) {
		guard border.top > 0 || border.right > 0 || border.bottom > 0 || border.left > 0 else { return }
		let bottomY = yUp(columnTop: top, height: height)

		func fillEdge(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: RGBA) {
			guard w > 0, h > 0 else { return }
			stream.setColorRGB(color.red, color.green, color.blue)
			stream.rectangle(x, y, w, h)
			stream.fill()
		}

		stream.pushState()
		if border.top > 0 {
			fillEdge(x, bottomY + height - border.top, width, border.top, colors.top)
		}
		if border.bottom > 0 {
			fillEdge(x, bottomY, width, border.bottom, colors.bottom)
		}
		if border.left > 0 {
			fillEdge(x, bottomY, border.left, height, colors.left)
		}
		if border.right > 0 {
			fillEdge(x + width - border.right, bottomY, border.right, height, colors.right)
		}
		stream.popState()
	}

	// MARK: - Images

	private func paintImage(_ box: BlockBox, image: DecodedImage) {
		let border = box.usedBorder
		let style = box.style
		let paddingLeft = style.padding.left.resolved(percentageBasis: 0) ?? 0
		let paddingTop = style.padding.top.resolved(percentageBasis: 0) ?? 0
		let paddingRight = style.padding.right.resolved(percentageBasis: 0) ?? 0
		let paddingBottom = style.padding.bottom.resolved(percentageBasis: 0) ?? 0
		drawImage(image,
		          x: box.x + border.left + paddingLeft,
		          top: box.y + border.top + paddingTop,
		          width: box.width - border.left - border.right - paddingLeft - paddingRight,
		          height: box.height - border.top - border.bottom - paddingTop - paddingBottom)
		// `<a href="…"><img style="display: block"></a>`: the image is the link.
		if let href = box.linkHref {
			addLinkAnnotation(x: box.x, width: box.width, top: box.y, bottom: box.y + box.height,
			                  anchor: box.y, href: href)
		}
	}

	/// Draw an image (or its placeholder) into a content box given in column
	/// coordinates.
	private func drawImage(_ image: DecodedImage, x: Double, top: Double, width: Double, height: Double) {
		guard width > 0, height > 0 else { return }
		let yUpBottom = geometry.pageHeightPx - pageY(top) - height

		stream.pushState()
		if let imageStream = image.pdfStream {
			// The image is mapped onto the unit square by the CTM.
			let name = builder.imageResourceName(for: imageStream, softMask: image.softMask,
			                                 dependencies: image.dependencies, link: image.link)
			stream.setMatrix(width, 0, 0, height, x, yUpBottom)
			stream.drawXObject(name)
		} else {
			// Placeholder box for formats not embeddable yet.
			stream.setColorRGB(0.9, 0.9, 0.9)
			stream.rectangle(x, yUpBottom, width, height)
			stream.fill()
		}
		stream.popState()
	}

	// MARK: - Footnotes

	/// Paint the notes at the foot of the page, below a short rule: each chunk is the
	/// part `from ..< to` of a note laid out in its own column. Call before the
	/// margin boxes, which restore the state saved in `init`.
	func paintFootnotes(_ chunks: [(box: BlockBox, from: Double, to: Double)], ruleColor: RGBA) {
		guard !chunks.isEmpty else { return }
		let own = geometry
		defer { geometry = own }
		let height = FootnoteSet.separatorHeight + chunks.reduce(0) { $0 + ($1.to - $1.from) }
		let areaTop = own.pageHeightPx - own.margins.bottom - height
		// The body's clip does not apply down here: give the notes their own.
		stream.popState()
		stream.pushState()
		stream.rectangle(own.margins.left, own.margins.bottom, own.pageWidthPx - own.margins.horizontal, height)
		stream.clip()
		stream.endPath()
		func place(columnTop: Double, sliceHeight: Double, pageTop: Double) {
			geometry = PageGeometry(pageWidthPx: own.pageWidthPx, pageHeightPx: own.pageHeightPx, margins: own.margins,
			                        columnTop: columnTop, sliceHeightPx: sliceHeight,
			                        contentOffsetPx: pageTop - own.margins.top, offsetXPx: own.offsetXPx)
		}
		let contentWidth = own.pageWidthPx - own.margins.horizontal
		place(columnTop: 0, sliceHeight: height, pageTop: areaTop)
		paintBackground(ruleColor, x: own.margins.left, top: FootnoteSet.ruleOffset, width: contentWidth / 3, height: 1)
		var pageTop = areaTop + FootnoteSet.separatorHeight
		for chunk in chunks {
			place(columnTop: chunk.from, sliceHeight: chunk.to - chunk.from, pageTop: pageTop)
			paint(chunk.box)
			pageTop += chunk.to - chunk.from
		}
	}

	// MARK: - @page margin boxes

	/// Paint resolved `@page` margin-box content (running headers/footers,
	/// page-number counters) directly in page space, independent of the
	/// column-to-slice mapping used for body content: margin boxes sit in the
	/// fixed page-margin strip, not on the scrolling column.
	func paintMarginBoxes(_ boxes: [ResolvedMarginBox]) {
		guard !boxes.isEmpty else { return }
		// Restore the state saved in `init`, before the content-slice clip.
		stream.popState()
		let contentWidth = geometry.pageWidthPx - geometry.margins.horizontal
		for box in boxes {
			let font = fonts.font(for: box.style)
			let resource = builder.resourceName(for: font)
			// Boxes sharing an edge each get their own region, so long text is
			// truncated instead of running into its neighbour.
			let neighbours = boxes.filter { $0.area.isTop == box.area.isTop && $0.area != box.area }
			let maxWidth: Double
			switch box.area {
			case .topCenter, .bottomCenter: maxWidth = neighbours.isEmpty ? contentWidth : contentWidth / 3
			default: maxWidth = !neighbours.isEmpty ? contentWidth / 2 - 6 : contentWidth
			}
			var text = box.text
			if font.width(of: text, size: box.style.fontSize) > maxWidth {
				while !text.isEmpty && font.width(of: text + "…", size: box.style.fontSize) > maxWidth { text.removeLast() }
				text += "…"
			}
			let textWidth = font.width(of: text, size: box.style.fontSize)
			let ascent = font.ascent(size: box.style.fontSize)
			let descent = font.descent(size: box.style.fontSize)

			let extra = max(0, contentWidth - textWidth)
			let rtl = box.style.direction == .rtl
			let x: Double
			switch box.style.textAlign {
			case .center, .webkitCenter: x = geometry.margins.left + extra / 2
			case .right, .webkitRight: x = geometry.margins.left + extra
			case .left, .webkitLeft: x = geometry.margins.left
			case .end: x = geometry.margins.left + (rtl ? 0 : extra)
			case .start: x = geometry.margins.left + (rtl ? extra : 0)
			case .justify: x = geometry.margins.left
			}

			// Center the text vertically within its margin strip (top strip is
			// [0, top margin]; bottom strip is [pageHeightPx - bottom margin, pageHeightPx]).
			let stripHeight = box.area.isTop ? geometry.margins.top : geometry.margins.bottom
			let stripTop = box.area.isTop ? 0 : geometry.pageHeightPx - stripHeight
			let baselineY = stripTop + (stripHeight + ascent - descent) / 2

			stream.beginText()
			stream.setColorRGB(box.style.color.red, box.style.color.green, box.style.color.blue)
			stream.setFontSize(resource, box.style.fontSize)
			stream.moveTextTo(x, geometry.pageHeightPx - baselineY)
			switch font {
			case .standard:
				stream.showRawString(encodeWinAnsi(text))
			case .embedded(let embedded):
				stream.showHexString(encodeGlyphs(text, font: embedded, fontKey: font.key))
			}
			stream.endText()
		}
	}

	// MARK: - Text

	private func paintText(_ fragment: TextFragment) {
		// Use the run's resolved font (set by fallback); else resolve from style.
		let font = fragment.font ?? fonts.font(for: fragment.style)
		let resource = builder.resourceName(for: font)
		let color = fragment.style.color

		let letterSpacing = fragment.style.letterSpacing
		stream.beginText()
		stream.setColorRGB(color.red, color.green, color.blue)
		stream.setFontSize(resource, fragment.style.fontSize)
		if letterSpacing != 0 { stream.setCharacterSpacing(letterSpacing) }
		stream.moveTextTo(fragment.x, geometry.pageHeightPx - pageY(fragment.baseline))
		switch font {
		case .standard:
			stream.showRawString(encodeWinAnsi(fragment.text))
		case .embedded(let embedded):
			stream.showHexString(encodeGlyphs(fragment.text, font: embedded, fontKey: font.key))
		}
		stream.endText()
		if letterSpacing != 0 { stream.setCharacterSpacing(0) } // reset for following text

		if let href = fragment.href {
			addLinkAnnotation(for: fragment, font: font, href: href)
		}
	}

	private enum DecorationKind {
		case underline
		case lineThrough
	}

	/// Draw one continuous bar for each decorated inline run on this line.
	private func paintDecorations(in fragments: [TextFragment]) {
		paintDecorationRuns(in: fragments, kind: .underline)
		paintDecorationRuns(in: fragments, kind: .lineThrough)
	}

	private func paintDecorationRuns(in fragments: [TextFragment], kind: DecorationKind) {
		var active: (run: TextDecorationRun, x: Double, endX: Double, baseline: Double)?

		func flush() {
			guard let active else { return }
			paintDecoration(kind, style: active.run.style, x: active.x,
			                width: active.endX - active.x, baseline: active.baseline)
		}

		for fragment in fragments {
			let run = kind == .underline ? fragment.decorations.underline : fragment.decorations.lineThrough
			guard fragment.inlineControl == nil else {
				flush()
				active = nil
				continue
			}
			guard let run else {
				flush()
				active = nil
				let isDecorated = kind == .underline ? fragment.style.underline : fragment.style.lineThrough
				if isDecorated {
					paintDecoration(kind, style: fragment.style, x: fragment.x,
					                width: fragment.width, baseline: fragment.baseline)
				}
				continue
			}

			if let current = active, current.run.source == run.source {
				active?.endX = max(current.endX, fragment.x + fragment.width)
			} else {
				flush()
				active = (run, fragment.x, fragment.x + fragment.width, fragment.baseline)
			}
		}
		flush()
	}

	private func paintDecoration(_ kind: DecorationKind, style: ComputedStyle,
	                             x: Double, width: Double, baseline: Double) {
		let size = style.fontSize
		let thickness = max(0.5, size / 16)
		let color = style.color
		let font = fonts.font(for: style)
		stream.pushState()
		stream.setColorRGB(color.red, color.green, color.blue)
		func bar(atColumnY columnY: Double) {
			let bottom = geometry.pageHeightPx - pageY(columnY + thickness / 2)
			stream.rectangle(x, bottom, width, thickness)
			stream.fill()
		}
		switch kind {
		case .underline:
			bar(atColumnY: baseline + size * 0.12)
		case .lineThrough:
			bar(atColumnY: baseline - font.ascent(size: size) * 0.30)
		}
		stream.popState()
	}

	/// Encode text as 2-byte glyph identifiers (Identity-H) and record the glyphs
	/// so the embedded font's width array and ToUnicode map can be built.
	private func encodeGlyphs(_ text: String, font: EmbeddedFont, fontKey: String) -> Data {
		var bytes = Data()
		for scalar in text.unicodeScalars {
			let glyph = font.glyphID(for: scalar)
			builder.recordGlyph(glyph, scalar: scalar, fontKey: fontKey)
			bytes.append(UInt8((glyph >> 8) & 0xFF))
			bytes.append(UInt8(glyph & 0xFF))
		}
		return bytes
	}

	/// A `/Link` annotation covering a fragment, if it falls on this page slice.
	private func addLinkAnnotation(for fragment: TextFragment, font: Font, href: String) {
		let ascent = font.ascent(size: fragment.style.fontSize)
		let descent = font.descent(size: fragment.style.fontSize)
		addLinkAnnotation(x: fragment.x, width: fragment.width, top: fragment.baseline - ascent,
		                  bottom: fragment.baseline + descent, anchor: fragment.baseline, href: href)
	}

	/// A `/Link` annotation over a rectangle in column coordinates, if the line
	/// it belongs to — identified by its baseline, `anchor` — is on this page.
	private func addLinkAnnotation(x: Double, width: Double, top: Double, bottom: Double, anchor: Double, href: String) {
		guard paintingRepeatedHeader || (anchor >= geometry.columnTop
		      && anchor <= geometry.columnTop + geometry.sliceHeightPx) else { return }
		let topPageY = pageY(top)
		let bottomPageY = pageY(bottom)
		// Annotation rectangles are in default (unscaled, y-up) user space.
		let x0 = (x + geometry.offsetXPx) * pxToPt
		let x1 = (x + width + geometry.offsetXPx) * pxToPt
		let yTop = (geometry.pageHeightPx - topPageY) * pxToPt
		let yBottom = (geometry.pageHeightPx - bottomPageY) * pxToPt
		let annotation = PDFDictionary([
			("Type", "/Annot"),
			("Subtype", "/Link"),
			("Rect", PDFArray([x0, yBottom, x1, yTop])),
			("Border", PDFArray([0, 0, 0])),
			("A", PDFDictionary([("S", "/URI"), ("URI", PDFString(href))]))
		])
		linkAnnotations.append(annotation)
		if href.hasPrefix("#") {
			let fragment = String(href.dropFirst())
			let id = internalAnchors.contains(fragment) ? fragment : fragment.removingPercentEncoding
			if let id, internalAnchors.contains(id) { internalLinks.append((annotation, id)) }
		}
	}

	/// The link annotations collected while painting this page.
	public func annotations() -> [PDFDictionary] { linkAnnotations }

	private func encodeWinAnsi(_ text: String) -> Data {
		// The font declares WinAnsiEncoding (Windows CP1252), which — unlike
		// ISO Latin-1 — includes the em/en dashes, smart quotes and bullet.
		text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()
	}
}
