//  PDFValue.swift
//  SwiftTextPDFWriter
//
//  A low-level PDF generator: a Swift port of pydyf
//  (https://github.com/CourtBouillon/pydyf, BSD-3-Clause).
//
//  This module is deliberately Foundation-only and free of any platform
//  framework so it can produce PDF bytes on every platform SwiftText targets
//  (macOS, iOS, Linux, Windows). It is the output substrate for the
//  cross-platform HTML/CSS rendering engine.

import Foundation

/// A value that can be serialized into a PDF byte stream.
///
/// Mirrors pydyf's `_to_bytes` polymorphism: integers, real numbers, raw byte
/// buffers, names/strings and the PDF object classes can all appear as
/// dictionary values, array elements or content-stream operands.
public protocol PDFValue {
	/// The raw bytes representing this value inside a PDF file.
	var pdfData: Data { get }
}

/// Format a real number the way pydyf does: integers print without a decimal
/// point; other values print with trailing zeros (and any trailing dot)
/// removed. Non-finite values degrade to `0` rather than emitting invalid
/// tokens.
public func formatPDFReal(_ value: Double) -> String {
	if value.isNaN || value.isInfinite {
		return "0"
	}
	if value.rounded() == value && abs(value) < 1e15 {
		return String(Int(value))
	}
	var string = String(format: "%.6f", value)
	while string.hasSuffix("0") {
		string.removeLast()
	}
	if string.hasSuffix(".") {
		string.removeLast()
	}
	return string
}

extension Int: PDFValue {
	public var pdfData: Data { Data(String(self).utf8) }
}

extension Double: PDFValue {
	public var pdfData: Data { Data(formatPDFReal(self).utf8) }
}

extension Float: PDFValue {
	public var pdfData: Data { Data(formatPDFReal(Double(self)).utf8) }
}

extension Data: PDFValue {
	public var pdfData: Data { self }
}

extension String: PDFValue {
	public var pdfData: Data { Data(utf8) }
}

/// A PDF name object such as `/Type` or `/Helvetica`.
///
/// Names are frequently written as plain `"/Foo"` strings (matching pydyf), but
/// `PDFName` exists for call sites that prefer to pass the bare identifier.
public struct PDFName: PDFValue {
	public var name: String

	public init(_ name: String) {
		self.name = name
	}

	public var pdfData: Data { Data("/\(name)".utf8) }
}
