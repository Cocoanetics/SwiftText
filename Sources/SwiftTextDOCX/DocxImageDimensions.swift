import Foundation

/// Dependency-free pixel-dimension reader for the raster formats the DOCX writer
/// embeds (PNG and JPEG). Parses the header only — no image decoding, no platform
/// imaging frameworks.
///
/// This mirrors `PagesImageBuilder.dimensions(of:)` in `SwiftTextPages`; the two are
/// kept as parallel copies so neither format writer depends on the other (DOCX must
/// not pull in the PAGES-trait-gated module). If a third writer needs it, promote it
/// to a shared module instead of adding a third copy.
enum DocxImageDimensions {

	/// Pixel dimensions of a PNG or JPEG, by parsing the header. Returns `nil` for
	/// anything else (the caller falls back to an alt-text placeholder).
	static func dimensions(of data: [UInt8]) -> (width: Int, height: Int)? {
		// PNG: 8-byte signature, then IHDR (width/height big-endian at offset 16).
		if data.count >= 24, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
			let w = Int(data[16]) << 24 | Int(data[17]) << 16 | Int(data[18]) << 8 | Int(data[19])
			let h = Int(data[20]) << 24 | Int(data[21]) << 16 | Int(data[22]) << 8 | Int(data[23])
			return (w, h)
		}
		// JPEG: scan segments for a Start-Of-Frame marker.
		if data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 {
			var i = 2
			while i + 9 < data.count {
				guard data[i] == 0xFF else { i += 1; continue }
				let marker = data[i + 1]
				// A marker may be preceded by any number of 0xFF fill bytes; step over
				// them one at a time so the length math below isn't applied to a fill byte.
				if marker == 0xFF { i += 1; continue }
				// Standalone markers carry no length payload: padding (0x00), TEM (0x01),
				// and restart/SOI/EOI markers (0xD0–0xD9). Skip just the 2 marker bytes.
				if marker == 0x00 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9) {
					i += 2
					continue
				}
				// SOF markers (0xC0–0xCF except DHT/JPG/DAC) carry the frame dimensions.
				if marker >= 0xC0, marker <= 0xCF, marker != 0xC4, marker != 0xC8, marker != 0xCC {
					let h = Int(data[i + 5]) << 8 | Int(data[i + 6])
					let w = Int(data[i + 7]) << 8 | Int(data[i + 8])
					return (w, h)
				}
				// Other markers (APPn, DQT, DHT, …) are followed by a 2-byte big-endian
				// segment length that includes those 2 length bytes.
				i += 2 + (Int(data[i + 2]) << 8 | Int(data[i + 3]))
			}
		}
		return nil
	}
}
