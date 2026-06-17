//  PDF.swift
//  SwiftTextPDFWriter
//
//  The PDF document container and serializer, ported from pydyf's `PDF`.
//  Implements the classic (uncompressed) cross-reference table format, which is
//  valid in every PDF version and requires no zlib. A compressed object-stream
//  writer can be layered on later for smaller output.

import Foundation

/// A PDF document under construction.
///
/// Build a document by creating ``PDFObject`` instances (streams, dictionaries),
/// adding them with ``addObject(_:)``, wiring up page dictionaries and adding
/// them with ``addPage(_:)``, then calling ``write(version:identifier:)`` to get
/// the final bytes.
public final class PDF {
	/// All objects in the document, indexed by object number.
	public private(set) var objects: [PDFObject] = []
	/// The `/Pages` tree root.
	public let pages: PDFDictionary
	/// The document information dictionary (metadata). Only written if non-empty.
	public let info: PDFDictionary
	/// The document catalog.
	public let catalog: PDFDictionary

	private var currentPosition = 0
	/// Byte offset of the cross-reference table after ``write(version:identifier:)``.
	public private(set) var xrefPosition = 0

	public init() {
		// Object 0 is always the head of the free list.
		let zero = PDFRawObject()
		zero.generation = 65535
		zero.isFree = true

		pages = PDFDictionary([
			("Type", "/Pages"),
			("Kids", PDFArray()),
			("Count", 0),
		])
		info = PDFDictionary()
		catalog = PDFDictionary([("Type", "/Catalog")])

		addObject(zero)
		addObject(pages)
		// The pages object now has a number, so it can be referenced.
		catalog["Pages"] = pages.reference
		addObject(catalog)
	}

	/// Register an object, assigning it the next object number.
	public func addObject(_ object: PDFObject) {
		object.number = objects.count
		objects.append(object)
	}

	/// Add a page dictionary to the document and link it into the page tree.
	public func addPage(_ page: PDFDictionary) {
		if let count = pages["Count"] as? Int {
			pages["Count"] = count + 1
		}
		addObject(page)
		if let kids = pages["Kids"] as? PDFArray, let number = page.number {
			// pydyf stores kids as a flat [number, 0, R, …] list.
			kids.elements.append(number)
			kids.elements.append(0)
			kids.elements.append("R")
		}
	}

	/// The list of page references, one per page.
	public var pageReferences: [Data] {
		guard let kids = pages["Kids"] as? PDFArray else { return [] }
		var references: [Data] = []
		var index = 0
		while index < kids.elements.count {
			if let number = kids.elements[index] as? Int {
				references.append(Data("\(number) 0 R".utf8))
			}
			index += 3
		}
		return references
	}

	/// Serialize the document to PDF bytes.
	///
	/// - Parameters:
	///   - version: The PDF version string written in the header.
	///   - identifier: Optional file identifier bytes written to the trailer's
	///     `/ID` array. Automatic identifier generation (MD5) is not yet
	///     implemented.
	@discardableResult
	public func write(version: String = "1.7", identifier: Data? = nil) -> Data {
		var output = Data()
		// Reset position state so re-serializing the same document (a second
		// write()/write(to:)) records correct offsets rather than accumulating.
		currentPosition = 0
		xrefPosition = 0

		func writeLine(_ content: Data) {
			currentPosition += content.count + 1
			output.append(content)
			output.append(0x0A) // newline
		}
		func writeLine(_ string: String) {
			writeLine(Data(string.utf8))
		}

		// Add the info dictionary if it carries metadata (only once).
		if !info.isEmpty && info.number == nil {
			addObject(info)
		}

		// Header. The binary comment marks the file as containing binary data.
		writeLine("%PDF-\(version)")
		writeLine(Data([0x25, 0xF0, 0x9F, 0x96, 0xA4]))

		// Body: every in-use object, recording its offset.
		for object in objects where !object.isFree {
			object.offset = currentPosition
			writeLine(object.indirect)
		}

		// Cross-reference table.
		xrefPosition = currentPosition
		writeLine("xref")
		writeLine("0 \(objects.count)")
		for object in objects {
			let offset = String(format: "%010d", object.offset)
			let generation = String(format: "%05d", object.generation)
			let marker = object.isFree ? "f" : "n"
			// Each entry is exactly 20 bytes including the trailing newline.
			writeLine("\(offset) \(generation) \(marker) ")
		}

		// Trailer.
		writeLine("trailer")
		writeLine("<<")
		writeLine("/Size \(objects.count)")
		var rootLine = Data("/Root ".utf8)
		rootLine.append(catalog.reference)
		writeLine(rootLine)
		if !info.isEmpty {
			var infoLine = Data("/Info ".utf8)
			infoLine.append(info.reference)
			writeLine(infoLine)
		}
		if let identifier {
			let literal = PDFString.literal(from: identifier)
			var idLine = Data("/ID [".utf8)
			idLine.append(literal)
			idLine.append(0x20)
			idLine.append(literal)
			idLine.append(contentsOf: "]".utf8)
			writeLine(idLine)
		}
		writeLine(">>")

		writeLine("startxref")
		writeLine("\(xrefPosition)")
		writeLine("%%EOF")

		return output
	}

	/// Serialize the document and write it to a file URL.
	public func write(to url: URL, version: String = "1.7", identifier: Data? = nil) throws {
		try write(version: version, identifier: identifier).write(to: url)
	}
}
