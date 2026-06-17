//  Painter.swift
//  SwiftTextRender
//
//  Paints a laid-out box tree into a PDF content stream: backgrounds, borders
//  and text. Layout is in CSS pixels with a y-down, top-left origin; a single
//  CTM (scale 0.75 = px→pt) is applied and each y is flipped into PDF's y-up
//  space, so glyphs stay upright.

import Foundation
import SwiftTextCSS
import SwiftTextPDFWriter

/// CSS pixels to PDF points: 1px = 1/96in, 1pt = 1/72in.
let pxToPt = 0.75

public final class Painter {
	public let stream = PDFStream()
	private let pageHeightPx: Double
	private let fonts: FontBook

	private var fontResourceNames: [String: String] = [:]
	private var fontOrder: [String] = []

	public init(pageHeightPx: Double, fonts: FontBook) {
		self.pageHeightPx = pageHeightPx
		self.fonts = fonts
		// Map CSS px (y-down) to PDF pt (y-up) for the whole page.
		stream.setMatrix(pxToPt, 0, 0, pxToPt, 0, 0)
	}

	/// Paint the box tree.
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

	private func yUp(top: Double, height: Double) -> Double {
		pageHeightPx - (top + height)
	}

	private func paintBackground(_ box: Box) {
		guard let color = box.style.backgroundColor, color.alpha > 0 else { return }
		stream.pushState()
		stream.setColorRGB(color.red, color.green, color.blue)
		stream.rectangle(box.x, yUp(top: box.y, height: box.height), box.width, box.height)
		stream.fill()
		stream.popState()
	}

	private func paintBorders(_ box: Box) {
		let border = box.usedBorder
		let style = box.style
		let bottomY = yUp(top: box.y, height: box.height)

		func fillEdge(_ rect: (x: Double, y: Double, w: Double, h: Double), _ color: RGBA) {
			guard rect.w > 0, rect.h > 0 else { return }
			stream.setColorRGB(color.red, color.green, color.blue)
			stream.rectangle(rect.x, rect.y, rect.w, rect.h)
			stream.fill()
		}

		guard border.top > 0 || border.right > 0 || border.bottom > 0 || border.left > 0 else { return }
		stream.pushState()
		if border.top > 0 {
			fillEdge((box.x, bottomY + box.height - border.top, box.width, border.top), style.borderColor.top)
		}
		if border.bottom > 0 {
			fillEdge((box.x, bottomY, box.width, border.bottom), style.borderColor.bottom)
		}
		if border.left > 0 {
			fillEdge((box.x, bottomY, border.left, box.height), style.borderColor.left)
		}
		if border.right > 0 {
			fillEdge((box.x + box.width - border.right, bottomY, border.right, box.height), style.borderColor.right)
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
		stream.moveTextTo(fragment.x, pageHeightPx - fragment.baseline)
		stream.showRawString(encodeWinAnsi(fragment.text))
		stream.endText()
	}

	private func encodeWinAnsi(_ text: String) -> Data {
		text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
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
