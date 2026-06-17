//  ArabicShaper.swift
//  SwiftTextRender
//
//  Presentation-forms Arabic shaping. Arabic letters change shape depending on
//  their neighbours (isolated / initial / medial / final) and a few pairs fuse
//  into ligatures (lam + alef). The "real" engine for this is HarfBuzz's
//  GSUB/GPOS shaper, which WeasyPrint delegates to; this is the pragmatic
//  interim: map each letter to its Unicode Presentation Form (the U+FB50–FDFF
//  and U+FE70–FEFF blocks) using the cursive-joining rules, falling back to the
//  nominal letter when the embedded font lacks a form glyph.
//
//  It covers the system Arabic fonts (which carry the presentation-form glyphs)
//  including base-letter joining and lam-alef. What it does NOT do — contextual
//  ligatures beyond lam-alef, mark positioning (GPOS), required ligatures in
//  fonts that only expose them via GSUB — is the job of the staged full shaper.
//
//  Shaping runs in logical order, before bidi reordering: each output scalar is
//  one glyph, so the bidi pass can reverse the scalar run for visual order.

import Foundation

/// The cursive-joining class of a character (a coarse port of the Joining_Type
/// property from ArabicShaping.txt, derived from the presentation-form table).
enum ArabicJoining {
	/// Joins on both sides (most letters): has initial/medial/final/isolated.
	case dual
	/// Joins only to the preceding letter: has final/isolated (e.g. alef, dal).
	case right
	/// Joins only to the following letter (no standard Arabic letter is this).
	case left
	/// Forces a join without being a letter: tatweel (U+0640), ZWJ (U+200D).
	case causing
	/// Skipped when finding joining neighbours: combining marks / harakat.
	case transparent
	/// Breaks the cursive connection: spaces, digits, ZWNJ, punctuation.
	case nonJoining
}

/// Stateless Arabic presentation-forms shaper.
public enum ArabicShaper {

	/// Whether `word` contains any letter that needs joining-form selection.
	/// (Text already written in presentation forms is left untouched.)
	public static func needsShaping(_ word: String) -> Bool {
		word.unicodeScalars.contains { arabicPresentationForms[$0.value] != nil }
	}

	/// Shape a word into presentation forms, in logical order.
	/// - Parameter hasForm: reports whether the target font actually carries the
	///   glyph for a given scalar; forms it lacks are skipped so shaping degrades
	///   gracefully to a less-connected form and ultimately the nominal letter.
	public static func shape(_ word: String, hasForm: (Unicode.Scalar) -> Bool) -> String {
		let shaped = shape(Array(word.unicodeScalars), hasForm: hasForm)
		var view = String.UnicodeScalarView()
		view.append(contentsOf: shaped)
		return String(view)
	}

	/// Scalar-level shaping. Returns presentation-form scalars in logical order;
	/// a lam-alef pair collapses to a single ligature scalar.
	static func shape(_ scalars: [Unicode.Scalar], hasForm: (Unicode.Scalar) -> Bool) -> [Unicode.Scalar] {
		let types = scalars.map(joiningType)

		// Nearest non-transparent neighbour in each direction (marks don't break
		// the cursive connection between the letters around them).
		func prevNonTransparent(_ i: Int) -> Int? {
			var j = i - 1
			while j >= 0 { if types[j] != .transparent { return j }; j -= 1 }
			return nil
		}
		func nextNonTransparent(_ i: Int) -> Int? {
			var j = i + 1
			while j < scalars.count { if types[j] != .transparent { return j }; j += 1 }
			return nil
		}

		var out: [Unicode.Scalar] = []
		out.reserveCapacity(scalars.count)
		var consumed = Set<Int>() // indices folded into a preceding ligature
		var i = 0
		while i < scalars.count {
			if consumed.contains(i) { i += 1; continue }
			let scalar = scalars[i]
			let type = types[i]

			// Non-letters (marks, tatweel, ZWJ, spaces, digits…) pass through. They
			// still influence the joining of letters around them via `joiningType`.
			guard type == .dual || type == .right || type == .left,
			      let forms = arabicPresentationForms[scalar.value] else {
				out.append(scalar)
				i += 1
				continue
			}

			let prevIndex = prevNonTransparent(i)
			let joinsPrev = canJoinPrevious(type) && (prevIndex.map { canJoinNext(types[$0]) } ?? false)

			// Lam (U+0644) + a following alef variant fuse into one ligature glyph.
			if scalar.value == 0x0644, let nextIndex = nextNonTransparent(i),
			   let ligature = arabicLamAlef[scalars[nextIndex].value] {
				let code = joinsPrev ? ligature.final : ligature.isolated
				if let glyph = Unicode.Scalar(code), hasForm(glyph) {
					out.append(glyph)
					// Keep any harakat that sat between the lam and the alef.
					if nextIndex > i + 1 {
						for k in (i + 1)..<nextIndex where types[k] == .transparent { out.append(scalars[k]) }
					}
					consumed.insert(nextIndex)
					i += 1
					continue
				}
				// Font lacks the ligature: fall through and shape the lam normally.
			}

			let nextIndex = nextNonTransparent(i)
			let joinsNext = canJoinNext(type) && (nextIndex.map { canJoinPrevious(types[$0]) } ?? false)

			out.append(form(for: scalar, forms: forms, joinsPrevious: joinsPrev, joinsNext: joinsNext, hasForm: hasForm))
			i += 1
		}
		return out
	}

	// MARK: - Form selection

	/// Pick the best available presentation form for a letter given its joins,
	/// degrading through less-connected forms (and finally to the nominal letter)
	/// when the chosen form is undefined or absent from the font.
	private static func form(for scalar: Unicode.Scalar,
	                         forms: (isolated: UInt32, final: UInt32, initial: UInt32, medial: UInt32),
	                         joinsPrevious: Bool, joinsNext: Bool,
	                         hasForm: (Unicode.Scalar) -> Bool) -> Unicode.Scalar {
		let chain: [UInt32]
		switch (joinsPrevious, joinsNext) {
		case (true, true):   chain = [forms.medial, forms.final, forms.initial, forms.isolated]
		case (true, false):  chain = [forms.final, forms.isolated]
		case (false, true):  chain = [forms.initial, forms.isolated]
		case (false, false): chain = [forms.isolated]
		}
		for code in chain where code != 0 {
			if let glyph = Unicode.Scalar(code), hasForm(glyph) { return glyph }
		}
		return scalar // nominal letter
	}

	// MARK: - Joining classification

	/// Can this class connect to the *preceding* letter (has a final/medial form)?
	private static func canJoinPrevious(_ type: ArabicJoining) -> Bool {
		type == .dual || type == .right || type == .causing
	}

	/// Can this class connect to the *following* letter (has an initial/medial form)?
	private static func canJoinNext(_ type: ArabicJoining) -> Bool {
		type == .dual || type == .left || type == .causing
	}

	/// Derive a character's joining class. Letters' dual-vs-right is read from the
	/// presentation-form table (an initial form ⇒ dual-joining).
	static func joiningType(_ scalar: Unicode.Scalar) -> ArabicJoining {
		let value = scalar.value
		if value == 0x0640 || value == 0x200D { return .causing }    // tatweel, ZWJ
		if isTransparent(scalar) { return .transparent }
		if let forms = arabicPresentationForms[value] {
			return forms.initial != 0 ? .dual : .right
		}
		return .nonJoining
	}

	/// Combining marks / harakat that are transparent to cursive joining.
	static func isTransparent(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar.value {
		case 0x0300...0x036F,   // combining diacritical marks
		     0x0610...0x061A,   // Arabic signs / honorifics
		     0x064B...0x065F,   // harakat (fathatan … low wavy hamza)
		     0x0670,            // superscript alef
		     0x06D6...0x06DC,   // small high marks
		     0x06DF...0x06E4,   // small high marks / madda
		     0x06E7...0x06E8,   // small high yeh / noon
		     0x06EA...0x06ED,   // small low marks
		     0x08E3...0x08FF:   // Arabic Extended-A marks
			return true
		default:
			return false
		}
	}
}
