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

/// Where a page sits within the laid-out column.
public struct PageGeometry {
	public let pageWidthPx: Double
	public let pageHeightPx: Double
	public let marginPx: Double
	/// The column y-coordinate shown at the top of this page's content area.
	public let columnTop: Double
	/// The height of the column slice shown on this page.
	public let sliceHeightPx: Double

	public init(pageWidthPx: Double, pageHeightPx: Double, marginPx: Double, columnTop: Double, sliceHeightPx: Double) {
		self.pageWidthPx = pageWidthPx
		self.pageHeightPx = pageHeightPx
		self.marginPx = marginPx
		self.columnTop = columnTop
		self.sliceHeightPx = sliceHeightPx
	}
}

public final class Painter {
	public let stream = PDFStream()
	private let geometry: PageGeometry
	private let fonts: FontBook

	private let builder: FontResourceBuilder
	private var linkAnnotations: [PDFDictionary] = []

	public init(geometry: PageGeometry, fonts: FontBook, builder: FontResourceBuilder, compress: Bool = true) {
		self.geometry = geometry
		self.fonts = fonts
		self.builder = builder
		// Page content streams are glyph-drawing operators — highly repetitive
		// and several times larger uncompressed. Deflate them (/FlateDecode).
		stream.compressed = compress
		// Map CSS px (y-down) to PDF pt (y-up) for the whole page.
		stream.setMatrix(pxToPt, 0, 0, pxToPt, 0, 0)
		// Save this (unclipped) state so margin-box painting can later restore
		// it: the clip below must not apply there, since margin boxes live
		// outside the content slice, in the page's margin area.
		stream.pushState()
		// Clip to this page's content slice so other pages don't bleed in.
		let contentWidth = geometry.pageWidthPx - 2 * geometry.marginPx
		stream.rectangle(geometry.marginPx,
		                 geometry.pageHeightPx - geometry.marginPx - geometry.sliceHeightPx,
		                 contentWidth, geometry.sliceHeightPx)
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
		top + height >= sliceTop - 0.5 && top <= sliceBottom + 0.5
	}

	/// Whether a line whose top sits at column `top` belongs to this page.
	/// Pagination breaks at line boundaries, so each line has exactly one home
	/// page: the slice whose half-open `[top, bottom)` range contains its top.
	/// Keying on the top (rather than an inclusive overlap) avoids painting a
	/// boundary line as a clipped sliver on the preceding page too.
	private func lineOnThisPage(_ top: Double) -> Bool {
		top >= sliceTop - 0.5 && top < sliceBottom - 0.5
	}

	/// Page y (from page top) for a column y-coordinate.
	private func pageY(_ columnY: Double) -> Double {
		geometry.marginPx + (columnY - geometry.columnTop)
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
			paintBackground(block)
			paintBorders(block)
			if let image = block.image {
				paintImage(block, image: image)
			} else if block.establishesInlineContext {
				for line in block.lines where lineOnThisPage(line.y) {
					for fragment in line.fragments {
						paintText(fragment)
					}
				}
			} else {
				for child in block.children {
					paint(child)
				}
			}
		}
		// Inline and text boxes are painted through their block's line fragments.
	}

	// MARK: - Backgrounds and borders

	private func paintBackground(_ box: Box) {
		guard let color = box.style.backgroundColor, color.alpha > 0 else { return }
		stream.pushState()
		stream.setColorRGB(color.red, color.green, color.blue)
		stream.rectangle(box.x, yUp(columnTop: box.y, height: box.height), box.width, box.height)
		stream.fill()
		stream.popState()
	}

	private func paintBorders(_ box: Box) {
		let border = box.usedBorder
		guard border.top > 0 || border.right > 0 || border.bottom > 0 || border.left > 0 else { return }
		let style = box.style
		let bottomY = yUp(columnTop: box.y, height: box.height)

		func fillEdge(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: RGBA) {
			guard w > 0, h > 0 else { return }
			stream.setColorRGB(color.red, color.green, color.blue)
			stream.rectangle(x, y, w, h)
			stream.fill()
		}

		stream.pushState()
		if border.top > 0 {
			fillEdge(box.x, bottomY + box.height - border.top, box.width, border.top, style.borderColor.top)
		}
		if border.bottom > 0 {
			fillEdge(box.x, bottomY, box.width, border.bottom, style.borderColor.bottom)
		}
		if border.left > 0 {
			fillEdge(box.x, bottomY, border.left, box.height, style.borderColor.left)
		}
		if border.right > 0 {
			fillEdge(box.x + box.width - border.right, bottomY, border.right, box.height, style.borderColor.right)
		}
		stream.popState()
	}

	// MARK: - Images

	private func paintImage(_ box: BlockBox, image: DecodedImage) {
		let border = box.usedBorder
		let x = box.x + border.left
		let topColumn = box.y + border.top
		let width = box.width - border.left - border.right
		let height = box.height - border.top - border.bottom
		guard width > 0, height > 0 else { return }
		let yUpBottom = geometry.pageHeightPx - pageY(topColumn) - height

		stream.pushState()
		if let imageStream = image.pdfStream {
			// The image is mapped onto the unit square by the CTM.
			let name = builder.imageResourceName(for: imageStream)
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

	// MARK: - @page margin boxes

	/// Paint resolved `@page` margin-box content (running headers/footers,
	/// page-number counters) directly in page space, independent of the
	/// column-to-slice mapping used for body content: margin boxes sit in the
	/// fixed page-margin strip, not on the scrolling column.
	func paintMarginBoxes(_ boxes: [ResolvedMarginBox]) {
		guard !boxes.isEmpty else { return }
		// Restore the state saved in `init`, before the content-slice clip.
		stream.popState()
		for box in boxes {
			let font = fonts.font(for: box.style)
			let resource = builder.resourceName(for: font)
			let textWidth = font.width(of: box.text, size: box.style.fontSize)
			let ascent = font.ascent(size: box.style.fontSize)
			let descent = font.descent(size: box.style.fontSize)

			let contentWidth = geometry.pageWidthPx - 2 * geometry.marginPx
			let extra = max(0, contentWidth - textWidth)
			let rtl = box.style.direction == .rtl
			let x: Double
			switch box.style.textAlign {
			case .center: x = geometry.marginPx + extra / 2
			case .right: x = geometry.marginPx + extra
			case .left: x = geometry.marginPx
			case .end: x = geometry.marginPx + (rtl ? 0 : extra)
			case .start: x = geometry.marginPx + (rtl ? extra : 0)
			case .justify: x = geometry.marginPx
			}

			// Center the text vertically within its margin strip (top strip is
			// [0, marginPx]; bottom strip is [pageHeightPx - marginPx, pageHeightPx]).
			let stripTop = box.area.isTop ? 0 : geometry.pageHeightPx - geometry.marginPx
			let baselineY = stripTop + (geometry.marginPx + ascent - descent) / 2

			stream.beginText()
			stream.setColorRGB(box.style.color.red, box.style.color.green, box.style.color.blue)
			stream.setFontSize(resource, box.style.fontSize)
			stream.moveTextTo(x, geometry.pageHeightPx - baselineY)
			switch font {
			case .standard:
				stream.showRawString(encodeWinAnsi(box.text))
			case .embedded(let embedded):
				stream.showHexString(encodeGlyphs(box.text, font: embedded, fontKey: font.key))
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

		if fragment.style.underline || fragment.style.lineThrough {
			paintDecorations(fragment, font: font)
		}
		if let href = fragment.href {
			addLinkAnnotation(for: fragment, font: font, href: href)
		}
	}

	/// Draw underline and/or line-through bars for a fragment.
	private func paintDecorations(_ fragment: TextFragment, font: Font) {
		let size = fragment.style.fontSize
		let thickness = max(0.5, size / 16)
		let color = fragment.style.color
		stream.pushState()
		stream.setColorRGB(color.red, color.green, color.blue)
		func bar(atColumnY columnY: Double) {
			let bottom = geometry.pageHeightPx - pageY(columnY + thickness / 2)
			stream.rectangle(fragment.x, bottom, fragment.width, thickness)
			stream.fill()
		}
		if fragment.style.underline {
			bar(atColumnY: fragment.baseline + size * 0.12)
		}
		if fragment.style.lineThrough {
			bar(atColumnY: fragment.baseline - font.ascent(size: size) * 0.30)
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
		guard fragment.baseline >= geometry.columnTop,
		      fragment.baseline <= geometry.columnTop + geometry.sliceHeightPx else { return }
		let ascent = font.ascent(size: fragment.style.fontSize)
		let descent = font.descent(size: fragment.style.fontSize)
		let topPageY = pageY(fragment.baseline) - ascent
		let bottomPageY = pageY(fragment.baseline) + descent
		// Annotation rectangles are in default (unscaled, y-up) user space.
		let x0 = fragment.x * pxToPt
		let x1 = (fragment.x + fragment.width) * pxToPt
		let yTop = (geometry.pageHeightPx - topPageY) * pxToPt
		let yBottom = (geometry.pageHeightPx - bottomPageY) * pxToPt
		linkAnnotations.append(PDFDictionary([
			("Type", "/Annot"),
			("Subtype", "/Link"),
			("Rect", PDFArray([x0, yBottom, x1, yTop])),
			("Border", PDFArray([0, 0, 0])),
			("A", PDFDictionary([("S", "/URI"), ("URI", PDFString(href))]))
		]))
	}

	/// The link annotations collected while painting this page.
	public func annotations() -> [PDFDictionary] { linkAnnotations }

	private func encodeWinAnsi(_ text: String) -> Data {
		// The font declares WinAnsiEncoding (Windows CP1252), which — unlike
		// ISO Latin-1 — includes the em/en dashes, smart quotes and bullet.
		text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()
	}
}
