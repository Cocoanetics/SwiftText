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
/// Whether the marker was painted into the text at all is not certain — a PDF
/// can leave it out of its text layer — and an item may legitimately begin with
/// something marker-shaped: `A. Smith`, `1.5 Millionen`. So recognition is
/// narrowed by what the segmenter reported. `reportedMarker`, the marker it saw
/// for this item, can be missing or spelled differently from what was painted,
/// so it matches exactly first and otherwise names the family a marker may come
/// from. When the item reported none, `listMarker` — the kind of list — names
/// the family instead: a bullet list's item keeps its `A.`, and only a lettered
/// list loses one.
///
/// Within a family an ordinal counts only when its `.` or `)` is followed by a
/// space, which keeps `1.5 Millionen` and `2026 war das Jahr` intact. With no
/// family known, only a bullet glyph — which no content begins with — goes.
func strippingListMarker(
	_ text: String,
	reportedMarker: String,
	listMarker: DocumentBlock.List.Marker
) -> String {
	let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !trimmed.isEmpty else { return trimmed }
	if let stripped = strippingReportedMarker(trimmed, reportedMarker: reportedMarker) {
		return stripped
	}

	let reported = reportedMarker.trimmingCharacters(in: .whitespacesAndNewlines)
	let family = MarkerFamily(reported: reported) ?? MarkerFamily(listMarker)
	for pattern in family?.patterns ?? [bulletGlyphPattern] {
		if let stripped = trimmed.removingPrefix(matching: pattern) { return stripped }
	}
	return trimmed
}

/// `text` without the marker the segmenter reported for it, or nil when the
/// text does not begin with that marker.
///
/// This is the one marker known to be a marker, so it is all that is removed
/// where the text itself came from the segmenter — whose item content still
/// begins with the marker it reports separately (`• Punkt eins`, marker `• `).
func strippingReportedMarker(_ text: String, reportedMarker: String) -> String? {
	let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
	let reported = reportedMarker.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !trimmed.isEmpty, !reported.isEmpty else { return nil }

	let escaped = NSRegularExpression.escapedPattern(for: reported)
	let pattern: String
	if reported.unicodeScalars.allSatisfy(bulletGlyphScalars.contains) {
		pattern = "^\(escaped)\\s*"
	} else if reported.last == "." || reported.last == ")"
		|| reported.unicodeScalars.allSatisfy(bulletScalars.contains) {
		pattern = "^\(escaped)\\s+"
	} else {
		// A reported bare ordinal (for example "1") may omit its painted
		// punctuation, but that punctuation is a marker only with whitespace
		// after it. This prevents an inaccurate report from eating "1." in
		// decimal content such as "1.5 Millionen".
		pattern = "^\(escaped)(?:[.)]\\s+|\\s+)"
	}
	return trimmed.removingPrefix(matching: pattern)
}

/// The kinds of marker a list uses, each recognised by its own patterns.
private enum MarkerFamily {
	case bullet
	case numeric
	/// Lettered; `uppercase` is nil when the case is not known.
	case latin(uppercase: Bool?)

	init?(reported: String) {
		guard !reported.isEmpty else { return nil }
		if reported.unicodeScalars.allSatisfy(bulletScalars.contains) {
			self = .bullet
		} else if reported.contains(where: \.isNumber), !reported.contains(where: \.isLetter) {
			self = .numeric
		} else if reported.contains(where: \.isLetter), !reported.contains(where: \.isNumber) {
			let letters = reported.filter(\.isLetter)
			if letters.allSatisfy(\.isUppercase) {
				self = .latin(uppercase: true)
			} else if letters.allSatisfy(\.isLowercase) {
				self = .latin(uppercase: false)
			} else {
				self = .latin(uppercase: nil)
			}
		} else {
			return nil
		}
	}

	init?(_ marker: DocumentBlock.List.Marker) {
		switch marker {
		case .bullet, .hyphen:
			self = .bullet
		case .decimal, .decorativeDecimal, .compositeDecimal:
			self = .numeric
		case .lowercaseLatin:
			self = .latin(uppercase: false)
		case .uppercaseLatin:
			self = .latin(uppercase: true)
		case .custom(let string):
			self.init(reported: string.trimmingCharacters(in: .whitespacesAndNewlines))
		}
	}

	/// A bullet glyph is unambiguous, so it needs no trailing space. The
	/// characters that double as punctuation — a hyphen, a dash, an asterisk, a
	/// digit, a letter — do, otherwise `E-Mail schreiben` and `1.5 Millionen`
	/// would lose their opening.
	var patterns: [String] {
		switch self {
		case .bullet:
			return [bulletGlyphPattern, "^[-\u{2013}\u{2014}*+]\\s+"]
		case .numeric:
			return ["^\\(?[0-9]+(?:\\.[0-9]+)+[.)]\\s+", "^\\(?[0-9]+[.)]\\s+"]
		case .latin(let uppercase):
			let letters = uppercase.map { $0 ? "A-Z" : "a-z" } ?? "A-Za-z"
			return ["^\\(?[\(letters)][.)]\\s+"]
		}
	}
}

private let bulletGlyphs = "\u{2022}\u{2023}\u{25AA}\u{25AB}\u{25CF}\u{25CB}\u{25E6}\u{2219}\u{00B7}"
private let bulletGlyphPattern = "^[\(bulletGlyphs)]\\s*"
private let bulletGlyphScalars = Set(bulletGlyphs.unicodeScalars)
private let bulletScalars = bulletGlyphScalars.union("-\u{2013}\u{2014}*+".unicodeScalars)

private extension String {
	/// Self without a leading match for `pattern`, or nil when it does not match.
	func removingPrefix(matching pattern: String) -> String? {
		guard let range = self.range(of: pattern, options: .regularExpression) else { return nil }
		return replacingCharacters(in: range, with: "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
