//  PDFStream.swift
//  SwiftTextPDFWriter
//
//  PDF stream objects and the content-stream operators used to paint pages.
//  Ported from pydyf's `Stream`. Compression is intentionally not implemented
//  yet (it would require a cross-platform zlib); streams are written verbatim.

import Foundation

/// A PDF stream object: a dictionary (`extra`) followed by a byte payload.
///
/// Content streams are built by appending operator tokens via the painting
/// methods below; other streams (fonts, images, XObjects) can be created by
/// passing raw bytes as the single stream element.
public final class PDFStream: PDFObject {
	/// The ordered tokens composing the stream body, joined by newlines.
	public var stream: [PDFValue]

	private var extraKeys: [String] = []
	private var extraStorage: [String: PDFValue] = [:]

	public init(stream: [PDFValue] = [], extra: [(String, PDFValue)] = []) {
		self.stream = stream
		super.init()
		for (key, value) in extra {
			setExtra(key, value)
		}
	}

	/// Set a key in the stream's leading dictionary, preserving insertion order.
	public func setExtra(_ key: String, _ value: PDFValue) {
		if extraStorage[key] == nil {
			extraKeys.append(key)
		}
		extraStorage[key] = value
	}

	public override var data: Data {
		var content = Data()
		for (index, item) in stream.enumerated() {
			if index > 0 {
				content.append(0x0A) // newline
			}
			content.append(item.pdfData)
		}

		let extra = PDFDictionary()
		for key in extraKeys {
			extra[key] = extraStorage[key]
		}
		extra["Length"] = content.count

		var result = extra.data
		result.append(contentsOf: "\nstream\n".utf8)
		result.append(content)
		result.append(contentsOf: "\nendstream".utf8)
		return result
	}

	// MARK: - Token helpers

	private func emit(_ token: String) {
		stream.append(Data(token.utf8))
	}

	private func emit(_ token: Data) {
		stream.append(token)
	}

	// MARK: - Graphics state

	/// Save the graphics state (`q`).
	public func pushState() { emit("q") }
	/// Restore the graphics state (`Q`).
	public func popState() { emit("Q") }
	/// Concatenate a matrix to the current transformation matrix (`cm`).
	public func setMatrix(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
		emit("\(formatPDFReal(a)) \(formatPDFReal(b)) \(formatPDFReal(c)) \(formatPDFReal(d)) \(formatPDFReal(e)) \(formatPDFReal(f)) cm")
	}
	/// Apply a named graphics state dictionary (`gs`).
	public func setState(_ name: String) { emit("/\(name) gs") }
	/// Set the line width (`w`).
	public func setLineWidth(_ width: Double) { emit("\(formatPDFReal(width)) w") }
	/// Set the line cap style (`J`).
	public func setLineCap(_ cap: Int) { emit("\(cap) J") }
	/// Set the line join style (`j`).
	public func setLineJoin(_ join: Int) { emit("\(join) j") }
	/// Set the miter limit (`M`).
	public func setMiterLimit(_ limit: Double) { emit("\(formatPDFReal(limit)) M") }
	/// Set the dash pattern (`d`).
	public func setDash(_ dashArray: [Double], phase: Double) {
		let array = PDFArray(dashArray.map { $0 as PDFValue })
		var token = array.data
		token.append(contentsOf: " \(formatPDFReal(phase)) d".utf8)
		emit(token)
	}

	// MARK: - Color

	/// Set the (non)stroking color in DeviceRGB (`rg` / `RG`).
	public func setColorRGB(_ red: Double, _ green: Double, _ blue: Double, stroke: Bool = false) {
		emit("\(formatPDFReal(red)) \(formatPDFReal(green)) \(formatPDFReal(blue)) \(stroke ? "RG" : "rg")")
	}
	/// Set the (non)stroking color space (`cs` / `CS`).
	public func setColorSpace(_ space: String, stroke: Bool = false) {
		emit("/\(space) \(stroke ? "CS" : "cs")")
	}

	// MARK: - Paths

	/// Begin a new subpath at `(x, y)` (`m`).
	public func moveTo(_ x: Double, _ y: Double) { emit("\(formatPDFReal(x)) \(formatPDFReal(y)) m") }
	/// Append a straight line to `(x, y)` (`l`).
	public func lineTo(_ x: Double, _ y: Double) { emit("\(formatPDFReal(x)) \(formatPDFReal(y)) l") }
	/// Append a cubic Bézier curve (`c`).
	public func curveTo(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) {
		emit("\(formatPDFReal(x1)) \(formatPDFReal(y1)) \(formatPDFReal(x2)) \(formatPDFReal(y2)) \(formatPDFReal(x3)) \(formatPDFReal(y3)) c")
	}
	/// Append a rectangle as a complete subpath (`re`). `(x, y)` is lower-left.
	public func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
		emit("\(formatPDFReal(x)) \(formatPDFReal(y)) \(formatPDFReal(width)) \(formatPDFReal(height)) re")
	}
	/// Close the current subpath (`h`).
	public func close() { emit("h") }
	/// Fill the current path (`f` / `f*`).
	public func fill(evenOdd: Bool = false) { emit(evenOdd ? "f*" : "f") }
	/// Stroke the current path (`S`).
	public func stroke() { emit("S") }
	/// Fill and stroke the current path (`B` / `B*`).
	public func fillAndStroke(evenOdd: Bool = false) { emit(evenOdd ? "B*" : "B") }
	/// Intersect the clipping path with the current path (`W` / `W*`).
	public func clip(evenOdd: Bool = false) { emit(evenOdd ? "W*" : "W") }
	/// End the path with no fill or stroke (`n`).
	public func endPath() { emit("n") }

	// MARK: - Text

	/// Begin a text object (`BT`).
	public func beginText() { emit("BT") }
	/// End a text object (`ET`).
	public func endText() { emit("ET") }
	/// Select a font resource and size (`Tf`).
	public func setFontSize(_ font: String, _ size: Double) { emit("/\(font) \(formatPDFReal(size)) Tf") }
	/// Move to the start of the next line, offset by `(x, y)` (`Td`).
	public func moveTextTo(_ x: Double, _ y: Double) { emit("\(formatPDFReal(x)) \(formatPDFReal(y)) Td") }
	/// Set the text matrix (`Tm`).
	public func setTextMatrix(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
		emit("\(formatPDFReal(a)) \(formatPDFReal(b)) \(formatPDFReal(c)) \(formatPDFReal(d)) \(formatPDFReal(e)) \(formatPDFReal(f)) Tm")
	}
	/// Set the text rise (`Ts`).
	public func setTextRise(_ rise: Double) { emit("\(formatPDFReal(rise)) Ts") }
	/// Set character spacing — extra space after each glyph (`Tc`).
	public func setCharacterSpacing(_ spacing: Double) { emit("\(formatPDFReal(spacing)) Tc") }
	/// Set word spacing — extra space after each space character (`Tw`).
	public func setWordSpacing(_ spacing: Double) { emit("\(formatPDFReal(spacing)) Tw") }
	/// Set the text rendering mode (`Tr`).
	public func setTextRendering(_ mode: Int) { emit("\(mode) Tr") }
	/// Show a single literal string (`Tj`).
	public func showTextString(_ text: String) {
		var token = PDFString(text).data
		token.append(contentsOf: " Tj".utf8)
		emit(token)
	}
	/// Show a pre-encoded byte string (e.g. WinAnsi bytes) with `Tj`.
	public func showRawString(_ bytes: Data) {
		var token = PDFString.literal(from: bytes)
		token.append(contentsOf: " Tj".utf8)
		emit(token)
	}
	/// Show a hex-encoded byte string with `Tj`. Used for embedded fonts whose
	/// codes are raw 2-byte glyph identifiers (Identity-H).
	public func showHexString(_ bytes: Data) {
		var token = Data([0x3C]) // <
		token.append(Data(bytes.map { String(format: "%02x", $0) }.joined().utf8))
		token.append(contentsOf: "> Tj".utf8)
		emit(token)
	}
	/// Show pre-built positioned glyph runs (`TJ`). `text` is the already
	/// serialized contents of the TJ array (strings interleaved with numeric
	/// adjustments).
	public func showText(_ text: Data) {
		var token = Data([0x5B]) // [
		token.append(text)
		token.append(contentsOf: "] TJ".utf8)
		emit(token)
	}

	// MARK: - XObjects, shadings and marked content

	/// Paint an external object by resource name (`Do`).
	public func drawXObject(_ name: String) { emit("/\(name) Do") }
	/// Paint a shading by resource name (`sh`).
	public func paintShading(_ name: String) { emit("/\(name) sh") }
	/// Begin a marked-content sequence (`BMC`).
	public func beginMarkedContent(_ tag: String) { emit("/\(tag) BMC") }
	/// End a marked-content sequence (`EMC`).
	public func endMarkedContent() { emit("EMC") }
}
