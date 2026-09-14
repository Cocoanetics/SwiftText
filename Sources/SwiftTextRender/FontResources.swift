//  FontResources.swift
//  SwiftTextRender
//
//  Builds the PDF font objects shared by every page of a render. Base-14 fonts
//  become inline Type1 dictionaries; registered OpenType fonts are embedded as
//  CIDFontType2 (Type0 / Identity-H) with a FontFile2 program, a W width array
//  for the glyphs actually used, and a ToUnicode CMap so text stays
//  searchable/extractable.

import Foundation
import SwiftTextPDFWriter

public final class FontResourceBuilder {
	private let pdf: PDF
	/// Whether embedded font programs and CMaps are deflated with `/FlateDecode`.
	private let compress: Bool
	/// The shared `/Resources` dictionary referenced by every page.
	private let resourcesDict: PDFDictionary
	private let fontSubdictionary = PDFDictionary()
	private let xobjectSubdictionary = PDFDictionary()

	private var resourceNames: [String: String] = [:]          // font key → /F#
	private var standardFonts: [String: StandardFont] = [:]
	private var embeddedFonts: [String: EmbeddedFont] = [:]
	private var usedGlyphs: [String: [Int: Unicode.Scalar]] = [:] // key → glyph → a scalar
	private var imageNames: [ObjectIdentifier: String] = [:]   // image stream → /Im#

	init(pdf: PDF, compress: Bool = true) {
		self.pdf = pdf
		self.compress = compress
		resourcesDict = PDFDictionary([("Font", fontSubdictionary), ("XObject", xobjectSubdictionary)])
		pdf.addObject(resourcesDict)
	}

	/// The resource name for an image XObject, embedding it on first use.
	func imageResourceName(for stream: PDFStream) -> String {
		let identity = ObjectIdentifier(stream)
		if let name = imageNames[identity] { return name }
		let name = "Im\(imageNames.count + 1)"
		imageNames[identity] = name
		if stream.number == nil { pdf.addObject(stream) }
		xobjectSubdictionary[name] = stream.reference
		return name
	}

	/// A reference to the shared `/Resources` dictionary.
	var resourcesReference: Data { resourcesDict.reference }

	/// The resource name for a font, assigning one on first use.
	func resourceName(for font: Font) -> String {
		if let name = resourceNames[font.key] { return name }
		let name = "F\(resourceNames.count + 1)"
		resourceNames[font.key] = name
		switch font {
		case .standard(let standard): standardFonts[font.key] = standard
		case .embedded(let embedded):
			embeddedFonts[font.key] = embedded
			usedGlyphs[font.key] = [:]
		}
		return name
	}

	/// Record that `glyph` (produced by `scalar`) is used by an embedded font.
	func recordGlyph(_ glyph: Int, scalar: Unicode.Scalar, fontKey: String) {
		usedGlyphs[fontKey, default: [:]][glyph] = scalar
	}

	/// Create the PDF font objects. Call once after all pages are painted.
	func finalize() {
		for (key, font) in standardFonts {
			fontSubdictionary[resourceNames[key]!] = PDFDictionary([
				("Type", "/Font"),
				("Subtype", "/Type1"),
				("BaseFont", "/\(font.baseFontName)"),
				("Encoding", "/WinAnsiEncoding")
			])
		}
		for (key, font) in embeddedFonts {
			fontSubdictionary[resourceNames[key]!] = buildType0Font(font, glyphs: usedGlyphs[key] ?? [:]).reference
		}
	}

	// MARK: - CIDFontType2 embedding

	private func buildType0Font(_ font: EmbeddedFont, glyphs: [Int: Unicode.Scalar]) -> PDFObject {
		let scale = 1000.0 / font.unitsPerEm

		// TrueType (`glyf`) outlines embed as FontFile2 + CIDFontType2; CFF
		// (PostScript) outlines as FontFile3 (Subtype OpenType) + CIDFontType0.
		// Encoding a FontFile2 stream that is actually CFF produces invalid text.
		let cff = font.hasCFFOutlines
		let subset = cff ? nil : try? font.otf.subsetTrueType(glyphs: glyphs)
		let fontData = subset?.data ?? font.data
		let name = subset == nil ? font.postScriptName : subsetName(for: font.postScriptName, glyphs: glyphs.keys)
		let fontFile = PDFStream(stream: [fontData])
		// Deflate the embedded font program. `/Length1` stays the *decoded* size,
		// so it is still correct once the stream carries a `/FlateDecode` filter.
		fontFile.compressed = compress
		if cff {
			fontFile.setExtra("Subtype", PDFName("OpenType"))
		} else {
			fontFile.setExtra("Length1", fontData.count)
		}
		pdf.addObject(fontFile)

		let bbox = font.boundingBox
		let descriptor = PDFDictionary([
			("Type", "/FontDescriptor"),
			("FontName", "/\(name)"),
			("Flags", 4), // Symbolic: the font uses its own (Identity) encoding
			("FontBBox", PDFArray([
				Int((Double(bbox.xMin) * scale).rounded()),
				Int((Double(bbox.yMin) * scale).rounded()),
				Int((Double(bbox.xMax) * scale).rounded()),
				Int((Double(bbox.yMax) * scale).rounded())
			])),
			("ItalicAngle", 0),
			("Ascent", Int((Double(font.ascentUnits) * scale).rounded())),
			("Descent", Int((Double(font.descentUnits) * scale).rounded())),
			("CapHeight", Int((Double(font.ascentUnits) * scale).rounded())),
			("StemV", 80),
			(cff ? "FontFile3" : "FontFile2", fontFile.reference)
		])
		pdf.addObject(descriptor)

		let widths = PDFArray()
		for glyph in glyphs.keys.sorted() {
			let width = Int((Double(font.advanceWidth(glyph: glyph)) * scale).rounded())
			widths.elements.append(glyph)
			widths.elements.append(PDFArray([width]))
		}

		// CIDFontType0 (CFF) addresses glyphs by GID via Identity-H. A subset
		// TrueType font has dense new GIDs, so map the original CIDs emitted into
		// page streams to their corresponding subset GIDs.
		var cidEntries: [(String, PDFValue)] = [
			("Type", "/Font"),
			("Subtype", cff ? "/CIDFontType0" : "/CIDFontType2"),
			("BaseFont", "/\(name)"),
			("CIDSystemInfo", PDFDictionary([
				("Registry", PDFString("Adobe")),
				("Ordering", PDFString("Identity")),
				("Supplement", 0)
			])),
			("FontDescriptor", descriptor.reference),
			("DW", 1000),
			("W", widths)
		]
		if !cff {
			if let mapping = subset?.glyphMapping {
				let cidToGID = buildCIDToGIDMap(mapping: mapping, usedGlyphs: glyphs.keys)
				pdf.addObject(cidToGID)
				cidEntries.insert(("CIDToGIDMap", cidToGID.reference), at: 5)
			} else {
				cidEntries.insert(("CIDToGIDMap", "/Identity"), at: 5)
			}
		}
		let cidFont = PDFDictionary(cidEntries)
		pdf.addObject(cidFont)

		let toUnicode = buildToUnicode(glyphs: glyphs)
		pdf.addObject(toUnicode)

		let type0 = PDFDictionary([
			("Type", "/Font"),
			("Subtype", "/Type0"),
			("BaseFont", "/\(name)"),
			("Encoding", "/Identity-H"),
			("DescendantFonts", PDFArray([cidFont.reference])),
			("ToUnicode", toUnicode.reference)
		])
		pdf.addObject(type0)
		return type0
	}

	private func buildCIDToGIDMap(mapping: [Int: Int], usedGlyphs: Dictionary<Int, Unicode.Scalar>.Keys) -> PDFStream {
		let maximumCID = usedGlyphs.max() ?? 0
		var bytes = [UInt8](repeating: 0, count: (maximumCID + 1) * 2)
		for cid in usedGlyphs {
			guard let glyph = mapping[cid] else { continue }
			bytes[cid * 2] = UInt8((glyph >> 8) & 0xFF)
			bytes[cid * 2 + 1] = UInt8(glyph & 0xFF)
		}
		let stream = PDFStream(stream: [Data(bytes)])
		stream.compressed = compress
		return stream
	}

	private func subsetName(for postScriptName: String, glyphs: Dictionary<Int, Unicode.Scalar>.Keys) -> String {
		var value: UInt32 = 2_166_136_261
		for byte in postScriptName.utf8 {
			value = (value ^ UInt32(byte)) &* 16_777_619
		}
		for glyph in glyphs.sorted() {
			value = (value ^ UInt32(glyph)) &* 16_777_619
		}
		var prefix = ""
		for _ in 0 ..< 6 {
			prefix.append(Character(Unicode.Scalar(65 + value % 26)!))
			value = value / 26 &+ 1
		}
		return prefix + "+" + postScriptName
	}

	private func buildToUnicode(glyphs: [Int: Unicode.Scalar]) -> PDFStream {
		var body = """
		/CIDInit /ProcSet findresource begin
		12 dict begin
		begincmap
		/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def
		/CMapName /Adobe-Identity-UCS def
		/CMapType 2 def
		1 begincodespacerange
		<0000> <FFFF>
		endcodespacerange
		"""
		let entries = glyphs.sorted { $0.key < $1.key }
		var index = 0
		while index < entries.count {
			let chunk = entries[index ..< min(index + 100, entries.count)]
			body += "\n\(chunk.count) beginbfchar\n"
			for (glyph, scalar) in chunk {
				let unicode = String(scalar).utf16.map { String(format: "%04X", $0) }.joined()
				body += String(format: "<%04X> <%@>\n", glyph, unicode)
			}
			body += "endbfchar"
			index += 100
		}
		body += "\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend"
		let stream = PDFStream(stream: [Data(body.utf8)])
		stream.compressed = compress // a repetitive PostScript CMap; compresses well
		return stream
	}
}
