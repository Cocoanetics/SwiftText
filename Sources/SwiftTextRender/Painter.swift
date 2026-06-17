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

	private var fontResourceNames: [String: String] = [:]
	private var fontOrder: [String] = []
	private var linkAnnotations: [PDFDictionary] = []

	public init(geometry: PageGeometry, fonts: FontBook) {
		self.geometry = geometry
		self.fonts = fonts
		// Map CSS px (y-down) to PDF pt (y-up) for the whole page.
		stream.setMatrix(pxToPt, 0, 0, pxToPt, 0, 0)
		// Clip to this page's content slice so other pages don't bleed in.
		let contentWidth = geometry.pageWidthPx - 2 * geometry.marginPx
		stream.rectangle(geometry.marginPx,
		                 geometry.pageHeightPx - geometry.marginPx - geometry.sliceHeightPx,
		                 contentWidth, geometry.sliceHeightPx)
		stream.clip()
		stream.endPath()
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
			paintBackground(block)
			paintBorders(block)
			if block.establishesInlineContext {
				for line in block.lines {
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

	// MARK: - Text

	private func paintText(_ fragment: TextFragment) {
		let font = fonts.font(for: fragment.style)
		let resource = resourceName(for: font.baseFontName)
		let color = fragment.style.color

		stream.beginText()
		stream.setColorRGB(color.red, color.green, color.blue)
		stream.setFontSize(resource, fragment.style.fontSize)
		stream.moveTextTo(fragment.x, geometry.pageHeightPx - pageY(fragment.baseline))
		stream.showRawString(encodeWinAnsi(fragment.text))
		stream.endText()

		if let href = fragment.href {
			addLinkAnnotation(for: fragment, font: font, href: href)
		}
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
			("A", PDFDictionary([("S", "/URI"), ("URI", PDFString(href))])),
		]))
	}

	/// The link annotations collected while painting this page.
	public func annotations() -> [PDFDictionary] { linkAnnotations }

	private func encodeWinAnsi(_ text: String) -> Data {
		// The font declares WinAnsiEncoding (Windows CP1252), which — unlike
		// ISO Latin-1 — includes the em/en dashes, smart quotes and bullet.
		text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()
	}

	// MARK: - Font resources

	private func resourceName(for baseFontName: String) -> String {
		if let existing = fontResourceNames[baseFontName] { return existing }
		let name = "F\(fontOrder.count + 1)"
		fontResourceNames[baseFontName] = name
		fontOrder.append(baseFontName)
		return name
	}

	/// Build the `/Resources` dictionary for the painted page.
	public func resources() -> PDFDictionary {
		let fontDict = PDFDictionary()
		for baseFontName in fontOrder {
			let resource = fontResourceNames[baseFontName]!
			fontDict[resource] = PDFDictionary([
				("Type", "/Font"),
				("Subtype", "/Type1"),
				("BaseFont", "/\(baseFontName)"),
				("Encoding", "/WinAnsiEncoding"),
			])
		}
		return PDFDictionary([("Font", fontDict)])
	}
}
