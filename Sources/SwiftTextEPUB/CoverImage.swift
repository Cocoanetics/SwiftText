//  CoverImage.swift
//  SwiftTextEPUB
//
//  Sniffs a cover image's format from its bytes so the OPF manifest can declare
//  the right media-type and the cover page can size its SVG wrapper to the
//  image's pixel dimensions (the technique Apple Books and other reading systems
//  want for a full-bleed cover).

import Foundation
import SwiftTextCore

/// A resolved cover image ready to embed: its bytes, in-package path, declared
/// media-type, and pixel dimensions when they can be read from the header.
struct CoverImage {
	let data: Data
	/// Path inside the container, e.g. `images/cover.jpg`.
	let path: String
	let mediaType: String
	let width: Int?
	let height: Int?

	/// Resolves a cover from raw bytes, sniffing the format (falling back to the
	/// original filename's extension, then JPEG). Returns `nil` for empty data.
	init?(data: Data, originalFilename: String?) {
		guard !data.isEmpty else { return nil }
		self.data = data

		let bytes = [UInt8](data.prefix(16))
		let (mediaType, ext) = Self.format(bytes: bytes, filename: originalFilename)
		self.mediaType = mediaType
		self.path = "images/cover.\(ext)"

		if let size = ImageDimensions.dimensions(of: [UInt8](data)) {
			self.width = size.width
			self.height = size.height
		} else {
			self.width = nil
			self.height = nil
		}
	}

	/// Maps magic bytes (then a filename extension) to an EPUB core media-type.
	private static func format(bytes: [UInt8], filename: String?) -> (mediaType: String, ext: String) {
		if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
			return ("image/jpeg", "jpg")
		}
		if bytes.count >= 8, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
			return ("image/png", "png")
		}
		if bytes.count >= 6, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { // "GIF"
			return ("image/gif", "gif")
		}
		if bytes.count >= 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46, // RIFF
		   bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {                  // WEBP
			return ("image/webp", "webp")
		}
		// SVG is text; look for a leading '<' after any BOM/whitespace.
		if let first = bytes.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0xEF && $0 != 0xBB && $0 != 0xBF }),
		   first == 0x3C {
			return ("image/svg+xml", "svg")
		}

		switch (filename as NSString?)?.pathExtension.lowercased() {
		case "png": return ("image/png", "png")
		case "gif": return ("image/gif", "gif")
		case "webp": return ("image/webp", "webp")
		case "svg": return ("image/svg+xml", "svg")
		default: return ("image/jpeg", "jpg")
		}
	}
}
