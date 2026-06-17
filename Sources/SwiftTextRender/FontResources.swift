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
	/// The shared `/Resources` dictionary referenced by every page.
	private let resourcesDict: PDFDictionary
	private let fontSubdictionary = PDFDictionary()
	private let xobjectSubdictionary = PDFDictionary()

	private var resourceNames: [String: String] = [:]          // font key → /F#
	private var standardFonts: [String: StandardFont] = [:]
	private var embeddedFonts: [String: EmbeddedFont] = [:]
	private var usedGlyphs: [String: [Int: Unicode.Scalar]] = [:] // key → glyph → a scalar
	private var imageNames: [ObjectIdentifier: String] = [:]   // image stream → /Im#

	init(pdf: PDF) {
		self.pdf = pdf
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
				("Encoding", "/WinAnsiEncoding"),
			])
		}
		for (key, font) in embeddedFonts {
			fontSubdictionary[resourceNames[key]!] = buildType0Font(font, glyphs: usedGlyphs[key] ?? [:]).reference
		}
	}

	// MARK: - CIDFontType2 embedding

	private func buildType0Font(_ font: EmbeddedFont, glyphs: [Int: Unicode.Scalar]) -> PDFObject {
		let scale = 1000.0 / font.unitsPerEm
		let name = font.postScriptName

		let fontFile = PDFStream(stream: [font.data])
		fontFile.setExtra("Length1", font.data.count)
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
				Int((Double(bbox.yMax) * scale).rounded()),
			])),
			("ItalicAngle", 0),
			("Ascent", Int((Double(font.ascentUnits) * scale).rounded())),
			("Descent", Int((Double(font.descentUnits) * scale).rounded())),
			("CapHeight", Int((Double(font.ascentUnits) * scale).rounded())),
			("StemV", 80),
			("FontFile2", fontFile.reference),
		])
		pdf.addObject(descriptor)

		let widths = PDFArray()
		for glyph in glyphs.keys.sorted() {
			let width = Int((Double(font.advanceWidth(glyph: glyph)) * scale).rounded())
			widths.elements.append(glyph)
			widths.elements.append(PDFArray([width]))
		}

		let cidFont = PDFDictionary([
			("Type", "/Font"),
			("Subtype", "/CIDFontType2"),
			("BaseFont", "/\(name)"),
			("CIDSystemInfo", PDFDictionary([
				("Registry", PDFString("Adobe")),
				("Ordering", PDFString("Identity")),
				("Supplement", 0),
			])),
			("FontDescriptor", descriptor.reference),
			("CIDToGIDMap", "/Identity"),
			("DW", 1000),
			("W", widths),
		])
		pdf.addObject(cidFont)

		let toUnicode = buildToUnicode(glyphs: glyphs)
		pdf.addObject(toUnicode)

		let type0 = PDFDictionary([
			("Type", "/Font"),
			("Subtype", "/Type0"),
			("BaseFont", "/\(name)"),
			("Encoding", "/Identity-H"),
			("DescendantFonts", PDFArray([cidFont.reference])),
			("ToUnicode", toUnicode.reference),
		])
		pdf.addObject(type0)
		return type0
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
		return PDFStream(stream: [Data(body.utf8)])
	}
}
