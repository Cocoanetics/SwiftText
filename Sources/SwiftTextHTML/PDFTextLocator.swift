#if canImport(PDFKit)
import Foundation
import PDFKit

/// Finds text in a finished PDF however the layout broke it into lines.
///
/// A heading that wraps has a line break in the PDF where the DOM text has a space,
/// and one that hyphenates gains a hyphen there, so PDFKit's `findString` does not
/// match it. The locator compares *compacted* text instead: every whitespace and
/// hyphen character removed and the rest lowercased (CSS `text-transform` prints a
/// case the DOM text doesn't have). Occurrences are counted on the same compacted
/// text on the DOM side, see ``occurrenceScript``.
package struct PDFTextLocator {
	/// Where a needle was found.
	package struct Match {
		/// The zero-based page the match starts on.
		package let pageIndex: Int
		/// The match's bounds on that page, in page space. Zero-sized if PDFKit has no selection for it.
		package let bounds: CGRect
	}

	private let document: PDFDocument
	/// The compacted text of the whole document, in UTF-16 units.
	private var units: [UInt16] = []
	/// For each unit, the page it came from and its offset in that page's `string`.
	private var pages: [Int32] = []
	private var offsets: [Int32] = []

	package init(document: PDFDocument) {
		self.document = document
		for pageIndex in 0 ..< document.pageCount {
			guard let text = document.page(at: pageIndex)?.string else { continue }
			var offset = 0
			for scalar in text.unicodeScalars {
				let width = scalar.utf16.count
				if !Self.isIgnored(scalar) {
					for unit in Character(scalar).lowercased().utf16 {
						units.append(unit)
						pages.append(Int32(pageIndex))
						offsets.append(Int32(offset))
					}
				}
				offset += width
			}
		}
	}

	private static func isIgnored(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		case 0x2D, 0xAD, 0x2010, 0x2011: return true
		default: return scalar.properties.isWhitespace
		}
	}

	/// `text` without whitespace and hyphens, lowercased: the form both sides are compared in.
	package static func compact(_ text: String) -> String {
		var result = ""
		for scalar in text.unicodeScalars where !isIgnored(scalar) { result += Character(scalar).lowercased() }
		return result
	}

	/// JavaScript for the DOM side. It defines `compact(string)` with the same rules as
	/// ``compact(_:)`` (case folded per character) and `occurrencesBefore(element, searchText)`, the number of earlier
	/// matches of `searchText` in the compacted text that precedes `element`.
	package static let occurrenceScript = """
	// Lowercased one character at a time: a whole-string toLowerCase() picks a final sigma by context, which the Swift side does not.
	const compact = s => Array.from(s.replace(/[\\s\\-\\u00AD\\u2010\\u2011]+/g, ''), c => c.toLowerCase()).join('');
	function occurrencesBefore(element, searchText) {
		const needle = compact(searchText);
		if (!needle) return 0;
		const range = document.createRange();
		range.setStart(document.body, 0);
		range.setEndBefore(element);
		const before = compact(range.toString());
		let count = 0, from = 0, hit;
		while ((hit = before.indexOf(needle, from)) !== -1) { count++; from = hit + 1; }
		return count;
	}
	"""

	/// The `occurrence`-th (zero-based) match of `searchText`, counting overlapping matches.
	package func locate(_ searchText: String, occurrence: Int) -> Match? {
		let needle = Array(Self.compact(searchText).utf16)
		guard let first = needle.first, occurrence >= 0, units.count >= needle.count else { return nil }
		var remaining = occurrence
		var start = 0
		let last = units.count - needle.count
		while start <= last {
			defer { start += 1 }
			guard units[start] == first, units[start ..< start + needle.count].elementsEqual(needle) else { continue }
			if remaining > 0 { remaining -= 1; continue }
			return match(from: start, count: needle.count)
		}
		return nil
	}

	private func match(from start: Int, count: Int) -> Match? {
		let pageIndex = Int(pages[start])
		guard let page = document.page(at: pageIndex) else { return nil }
		// A match that runs onto the next page is measured on its first page only.
		var end = start + count - 1
		while pages[end] != pages[start] { end -= 1 }
		let range = NSRange(location: Int(offsets[start]), length: Int(offsets[end]) - Int(offsets[start]) + 1)
		let bounds = page.selection(for: range)?.bounds(for: page) ?? .zero
		return Match(pageIndex: pageIndex, bounds: bounds)
	}
}
#endif
