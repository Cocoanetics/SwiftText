//  SystemFonts.swift
//  SwiftTextRender
//
//  Resolves an installed font family through the platform font service, so a
//  `font-family` that no `@font-face` names still gets its real regular, bold
//  and italic faces. CoreText only; elsewhere nothing is found and the bundled
//  faces apply.

import Foundation
#if canImport(CoreText)
import CoreText
#endif

extension FontBook {
	/// The faces of `family` installed on the system, one per bold/italic combination.
	static func systemFaces(family: String, prefix: String) -> [(bold: Bool, italic: Bool, font: EmbeddedFont)] {
		#if canImport(CoreText)
		let attributes = [kCTFontFamilyNameAttribute: family] as CFDictionary
		let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
		let mandatory = Set([kCTFontFamilyNameAttribute]) as CFSet
		guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory) as? [CTFontDescriptor] else { return [] }
		var urls: [URL] = []
		for match in matches {
			if let url = CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute) as? URL, !urls.contains(url) { urls.append(url) }
		}
		// A file may hold other families too (a collection): keep this family's faces.
		var faces: [(bold: Bool, italic: Bool, font: EmbeddedFont)] = []
		for url in urls {
			guard let data = try? Data(contentsOf: url),
			      let found = try? collectionFaces(data: data, namePrefix: prefix, family: family) else { continue }
			// Skip fonts whose licence forbids embedding (restricted, bitmap-only) or subsetting.
			for face in found where face.font.otf.fsType & 0x0302 == 0 && !faces.contains(where: { $0.bold == face.bold && $0.italic == face.italic }) {
				faces.append(face)
			}
		}
		return faces
		#else
		return []
		#endif
	}
}
