//  FontBytes.swift
//  SwiftTextOpenType
//
//  A pure-Swift OpenType / TrueType (sfnt) reader. It exists so the
//  cross-platform rendering engine can measure and embed real fonts without
//  linking HarfBuzz, FreeType or fontconfig — only Foundation.
//
//  FontBytes is a small bounds-checked big-endian accessor over a font's bytes.

import Foundation

/// Errors raised while parsing an sfnt font.
public enum OpenTypeError: Error, Equatable {
	/// A read ran past the end of the data.
	case truncated(offset: Int)
	/// The file is not a recognized sfnt (TrueType/OpenType/collection).
	case notSFNT(tag: String)
	/// A required table is absent.
	case missingTable(String)
	/// A font collection index was out of range.
	case fontIndexOutOfRange(Int)
}

/// Bounds-checked, big-endian random access over a font's raw bytes.
///
/// All multi-byte integers in sfnt files are big-endian. Accessors return `Int`
/// for ergonomics; on 64-bit platforms `UInt32` values fit without loss.
struct FontBytes {
	let bytes: [UInt8]

	init(_ data: Data) {
		bytes = [UInt8](data)
	}

	init(_ bytes: [UInt8]) {
		self.bytes = bytes
	}

	var count: Int { bytes.count }

	/// Unsigned 8-bit value at `offset`.
	func u8(_ offset: Int) throws -> Int {
		guard offset >= 0, offset < bytes.count else {
			throw OpenTypeError.truncated(offset: offset)
		}
		return Int(bytes[offset])
	}

	/// Unsigned 16-bit value at `offset`.
	func u16(_ offset: Int) throws -> Int {
		guard offset >= 0, offset + 2 <= bytes.count else {
			throw OpenTypeError.truncated(offset: offset)
		}
		return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
	}

	/// Signed 16-bit value at `offset`.
	func i16(_ offset: Int) throws -> Int {
		let value = try u16(offset)
		return value >= 0x8000 ? value - 0x10000 : value
	}

	/// Unsigned 32-bit value at `offset`.
	func u32(_ offset: Int) throws -> Int {
		guard offset >= 0, offset + 4 <= bytes.count else {
			throw OpenTypeError.truncated(offset: offset)
		}
		return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
			| Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
	}

	/// Signed 32-bit value at `offset`.
	func i32(_ offset: Int) throws -> Int {
		let value = try u32(offset)
		return value >= 0x8000_0000 ? value - 0x1_0000_0000 : value
	}

	/// A four-character table tag at `offset`.
	func tag(_ offset: Int) throws -> String {
		guard offset >= 0, offset + 4 <= bytes.count else {
			throw OpenTypeError.truncated(offset: offset)
		}
		return String(bytes: bytes[offset ..< offset + 4], encoding: .ascii) ?? ""
	}
}
