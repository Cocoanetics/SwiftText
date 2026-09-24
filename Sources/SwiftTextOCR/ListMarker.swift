//
//  ListMarker.swift
//  SwiftTextOCR
//
//  Removing a list item's visual marker from its text.
//

import Foundation

/// A list item's text with the marker that introduces it removed.
///
/// Markdown writes the marker itself — `-`, `1.` — so a marker left in the
/// item's text is written twice: `- • Punkt eins`. The marker survives whenever
/// the text is read back from a page rather than from the segmenter: in a PDF's
/// text layer a bullet is a painted glyph like any other character.
///
/// `reportedMarker` is what the segmenter said the marker was. It can be
/// missing, or spelled differently from what was painted, so a marker is also
/// recognised on its own. Recognition is deliberately narrow, because a list
/// item may legitimately begin with something marker-shaped: an ordinal counts
/// only when its `.` or `)` is followed by a space, which keeps `1.5 Millionen`
/// and `2026 war das Jahr` intact.
func strippingListMarker(_ text: String, reportedMarker: String) -> String {
	let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !trimmed.isEmpty else { return trimmed }

	let reported = reportedMarker.trimmingCharacters(in: .whitespacesAndNewlines)
	if !reported.isEmpty {
		let escaped = NSRegularExpression.escapedPattern(for: reported)
		let pattern: String
		if reported.unicodeScalars.allSatisfy(reportedBulletScalars.contains) {
			pattern = "^\(escaped)\\s*"
		} else if reported.last == "." || reported.last == ")" {
			pattern = "^\(escaped)\\s+"
		} else {
			// A reported bare ordinal (for example "1") may omit its painted
			// punctuation, but that punctuation is a marker only with whitespace
			// after it. This prevents an inaccurate report from eating "1." in
			// decimal content such as "1.5 Millionen".
			pattern = "^\(escaped)(?:[.)]\\s+|\\s+)"
		}
		if let stripped = trimmed.removingPrefix(matching: pattern) { return stripped }
	}

	for pattern in markerPatterns {
		if let stripped = trimmed.removingPrefix(matching: pattern) { return stripped }
	}
	return trimmed
}

/// Markers recognised without the segmenter naming one.
///
/// A bullet glyph is unambiguous, so it needs no trailing space. The characters
/// that double as punctuation — a hyphen, a dash, an asterisk, a digit — do,
/// otherwise `E-Mail schreiben` and `1.5 Millionen` would lose their opening.
private let markerPatterns = [
	"^[\u{2022}\u{2023}\u{25AA}\u{25AB}\u{25CF}\u{25CB}\u{25E6}\u{2219}\u{00B7}]\\s*",
	"^[-\u{2013}\u{2014}*+]\\s+",
	"^\\(?[0-9]+(?:\\.[0-9]+)+[.)]\\s+",
	"^\\(?[0-9]+[.)]\\s+",
	"^\\(?[A-Za-z][.)]\\s+"
]

private let reportedBulletScalars = Set("\u{2022}\u{2023}\u{25AA}\u{25AB}\u{25CF}\u{25CB}\u{25E6}\u{2219}\u{00B7}".unicodeScalars)

private extension String {
	/// Self without a leading match for `pattern`, or nil when it does not match.
	func removingPrefix(matching pattern: String) -> String? {
		guard let range = self.range(of: pattern, options: .regularExpression) else { return nil }
		return replacingCharacters(in: range, with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
