//  PDFObjects.swift
//  SwiftTextPDFWriter
//
//  The core PDF object model ported from pydyf: indirect objects, dictionaries,
//  arrays and strings. These are reference types because their object number
//  and byte offset are assigned lazily while the document is written.

import Foundation

/// Base class for indirect PDF objects.
///
/// Concrete subclasses override ``data`` to provide their serialized body. The
/// object number, generation and file offset are filled in by ``PDF`` during
/// writing.
public class PDFObject: PDFValue {
	/// Number of the object, assigned when added to a ``PDF``.
	public var number: Int?
	/// Byte position of the object in the written file.
	public var offset: Int = 0
	/// Generation number, non-negative. Almost always `0`.
	public var generation: Int = 0
	/// Whether the object is free (deleted) rather than in use.
	public var isFree: Bool = false

	public init() {}

	/// The serialized body of the object. Abstract; overridden by subclasses.
	public var data: Data {
		fatalError("PDFObject.data must be overridden")
	}

	public var pdfData: Data { data }

	/// The indirect representation: `"<n> <g> obj"`, body, `"endobj"`.
	public var indirect: Data {
		var result = Data("\(number ?? 0) \(generation) obj\n".utf8)
		result.append(data)
		result.append(contentsOf: "\nendobj".utf8)
		return result
	}

	/// The reference used to point at this object: `"<n> <g> R"`.
	public var reference: Data {
		Data("\(number ?? 0) \(generation) R".utf8)
	}

	/// Whether the object may live inside a compressed object stream.
	public var compressible: Bool {
		generation == 0 && !(self is PDFStream)
	}
}

/// An object whose body is a fixed byte buffer. Used for the free head object
/// and any pre-serialized content.
public final class PDFRawObject: PDFObject {
	public var raw: Data

	public init(_ raw: Data = Data()) {
		self.raw = raw
		super.init()
	}

	public override var data: Data { raw }
}

/// A PDF dictionary that preserves key insertion order so output is
/// deterministic (matching Python's ordered `dict`).
public final class PDFDictionary: PDFObject {
	public private(set) var keys: [String] = []
	private var storage: [String: PDFValue] = [:]

	public init(_ pairs: [(String, PDFValue)] = []) {
		super.init()
		for (key, value) in pairs {
			self[key] = value
		}
	}

	public subscript(key: String) -> PDFValue? {
		get { storage[key] }
		set {
			if let newValue {
				if storage[key] == nil {
					keys.append(key)
				}
				storage[key] = newValue
			} else if storage[key] != nil {
				storage[key] = nil
				keys.removeAll { $0 == key }
			}
		}
	}

	public var isEmpty: Bool { keys.isEmpty }

	public override var data: Data {
		var result = Data("<<".utf8)
		for key in keys {
			result.append(contentsOf: "/\(key) ".utf8)
			result.append(storage[key]!.pdfData)
		}
		result.append(contentsOf: ">>".utf8)
		return result
	}
}

/// A PDF array. Elements are written space-separated inside brackets.
public final class PDFArray: PDFObject {
	public var elements: [PDFValue]

	public init(_ elements: [PDFValue] = []) {
		self.elements = elements
		super.init()
	}

	public override var data: Data {
		var result = Data([0x5B]) // [
		for (index, element) in elements.enumerated() {
			if index > 0 {
				result.append(0x20) // space
			}
			result.append(element.pdfData)
		}
		result.append(0x5D) // ]
		return result
	}
}

/// A PDF string object.
///
/// ASCII-representable strings are written as escaped literal strings,
/// `(like this)`. Anything else is written as a UTF-16BE hex string with a
/// byte-order mark, `<feff…>`, matching pydyf's fallback.
public final class PDFString: PDFObject {
	public var string: String

	public init(_ string: String = "") {
		self.string = string
		super.init()
	}

	public override var data: Data {
		if let ascii = string.data(using: .ascii) {
			return PDFString.literal(from: ascii)
		}
		var bytes: [UInt8] = [0xFE, 0xFF]
		for unit in string.utf16 {
			bytes.append(UInt8(unit >> 8))
			bytes.append(UInt8(unit & 0xFF))
		}
		let hex = bytes.map { String(format: "%02x", $0) }.joined()
		return Data("<\(hex)>".utf8)
	}

	/// Wrap arbitrary bytes as an escaped PDF literal string.
	static func literal(from bytes: Data) -> Data {
		var result = Data([0x28]) // (
		result.reserveCapacity(bytes.count + 2)
		for byte in bytes {
			if byte == 0x5C || byte == 0x28 || byte == 0x29 { // \ ( )
				result.append(0x5C)
			}
			result.append(byte)
		}
		result.append(0x29) // )
		return result
	}
}
