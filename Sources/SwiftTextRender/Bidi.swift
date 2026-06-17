//  Bidi.swift
//  SwiftTextRender
//
//  A pure-Swift implementation of the Unicode Bidirectional Algorithm (UAX #9),
//  the piece WeasyPrint gets from Pango/fribidi. It resolves an embedding level
//  per character and produces the visual (display) order for a line.
//
//  Scope: a single embedding level from the base direction (explicit
//  embeddings/overrides/isolates — the X rules — and paired-bracket resolution
//  N0 are not modeled). This is sufficient for Hebrew and mixed LTR/RTL text
//  with European/Arabic numbers, which is the current target. Arabic cursive
//  shaping is a separate (font-level) concern.

import Foundation

/// Base paragraph direction.
public enum BidiDirection: Sendable {
	case leftToRight
	case rightToLeft

	var baseLevel: UInt8 { self == .leftToRight ? 0 : 1 }
}

/// The bidi character classes used by the resolution rules.
enum BidiClass {
	case l, r, al          // strong
	case en, es, et, an, cs // weak
	case nsm, bn           // weak (marks / boundary-neutral)
	case b, s, ws, on      // neutral / separators
}

public enum Bidi {

	/// The resolved embedding level of each scalar.
	public static func levels(for scalars: [Unicode.Scalar], baseDirection: BidiDirection) -> [UInt8] {
		resolveLevels(scalars.map(bidiClass), baseLevel: baseDirection.baseLevel)
	}

	/// The visual (left-to-right display) order of scalar indices for a line,
	/// from their resolved levels (rule L2).
	public static func visualOrder(levels: [UInt8]) -> [Int] {
		let count = levels.count
		var order = Array(0 ..< count)
		guard count > 0 else { return order }

		let maxLevel = Int(levels.max() ?? 0)
		var minOdd = Int.max
		for level in levels where level % 2 == 1 { minOdd = min(minOdd, Int(level)) }
		guard minOdd != Int.max else { return order } // nothing to reverse

		var level = maxLevel
		while level >= minOdd {
			var i = 0
			while i < count {
				if Int(levels[i]) >= level {
					var j = i
					while j < count, Int(levels[j]) >= level { j += 1 }
					order[i ..< j].reverse()
					i = j
				} else {
					i += 1
				}
			}
			level -= 1
		}
		return order
	}

	/// Whether a scalar is right-to-left (Hebrew/Arabic strong).
	public static func isRTLScalar(_ scalar: Unicode.Scalar) -> Bool {
		switch bidiClass(scalar) {
		case .r, .al: return true
		default: return false
		}
	}

	/// The direction of the first strong (L or R/AL) character, for `dir=auto`.
	public static func firstStrongDirection<S: Sequence>(of scalars: S) -> BidiDirection? where S.Element == Unicode.Scalar {
		for scalar in scalars {
			switch bidiClass(scalar) {
			case .l: return .leftToRight
			case .r, .al: return .rightToLeft
			default: continue
			}
		}
		return nil
	}
}

// MARK: - Resolution (W, N, I rules)

private func resolveLevels(_ classes: [BidiClass], baseLevel: UInt8) -> [UInt8] {
	let n = classes.count
	guard n > 0 else { return [] }
	var t = classes
	let even = baseLevel % 2 == 0
	let sor: BidiClass = even ? .l : .r

	// W1: NSM takes the class of the previous character (sor at the start).
	var previous = sor
	for i in 0 ..< n {
		if t[i] == .nsm { t[i] = previous }
		previous = t[i]
	}
	// W2: EN becomes AN if the last strong class was AL.
	var lastStrong = sor
	for i in 0 ..< n {
		switch t[i] {
		case .r, .l, .al: lastStrong = t[i]
		case .en where lastStrong == .al: t[i] = .an
		default: break
		}
	}
	// W3: AL becomes R.
	for i in 0 ..< n where t[i] == .al { t[i] = .r }
	// W4: a single ES between EN/EN, or CS between EN/EN or AN/AN, joins them.
	if n >= 3 {
		for i in 1 ..< (n - 1) {
			if t[i] == .es, t[i - 1] == .en, t[i + 1] == .en { t[i] = .en }
			else if t[i] == .cs, t[i - 1] == .en, t[i + 1] == .en { t[i] = .en }
			else if t[i] == .cs, t[i - 1] == .an, t[i + 1] == .an { t[i] = .an }
		}
	}
	// W5: a run of ET adjacent to EN becomes EN.
	var i = 0
	while i < n {
		if t[i] == .et {
			var j = i
			while j < n, t[j] == .et { j += 1 }
			if (i > 0 && t[i - 1] == .en) || (j < n && t[j] == .en) {
				for k in i ..< j { t[k] = .en }
			}
			i = j
		} else {
			i += 1
		}
	}
	// W6: remaining ES/ET/CS become ON.
	for i in 0 ..< n where t[i] == .es || t[i] == .et || t[i] == .cs { t[i] = .on }
	// W7: EN becomes L if the last strong class was L.
	lastStrong = sor
	for i in 0 ..< n {
		switch t[i] {
		case .r, .l: lastStrong = t[i]
		case .en where lastStrong == .l: t[i] = .l
		default: break
		}
	}

	// N1/N2: resolve neutral runs.
	func isNeutral(_ c: BidiClass) -> Bool { c == .b || c == .s || c == .ws || c == .on || c == .bn }
	func neutralContext(_ c: BidiClass) -> BidiClass { // EN/AN count as R for neutrals
		switch c {
		case .l: return .l
		case .r, .en, .an: return .r
		default: return sor
		}
	}
	i = 0
	while i < n {
		if isNeutral(t[i]) {
			var j = i
			while j < n, isNeutral(t[j]) { j += 1 }
			let before = i > 0 ? neutralContext(t[i - 1]) : sor
			let after = j < n ? neutralContext(t[j]) : sor
			let resolved: BidiClass = (before == after) ? before : (even ? .l : .r)
			for k in i ..< j { t[k] = resolved }
			i = j
		} else {
			i += 1
		}
	}

	// I1/I2: implicit levels.
	var levels = [UInt8](repeating: baseLevel, count: n)
	for i in 0 ..< n {
		if even {
			switch t[i] {
			case .r: levels[i] = baseLevel + 1
			case .an, .en: levels[i] = baseLevel + 2
			default: levels[i] = baseLevel
			}
		} else {
			switch t[i] {
			case .l, .en, .an: levels[i] = baseLevel + 1
			default: levels[i] = baseLevel
			}
		}
	}
	return levels
}

// MARK: - Character classification

private func bidiClass(_ scalar: Unicode.Scalar) -> BidiClass {
	let v = scalar.value
	switch v {
	case 0x0A, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2029: return .b
	case 0x09, 0x0B, 0x1F: return .s
	case 0x0C, 0x20, 0x1680, 0x2028, 0x205F, 0x3000: return .ws
	case 0x2000 ... 0x200A: return .ws
	case 0x200B: return .bn
	default: break
	}
	switch v {
	case 0x30 ... 0x39, 0xB2, 0xB3, 0xB9: return .en
	case 0x2B, 0x2D: return .es
	case 0x23, 0x24, 0x25, 0xA2, 0xA3, 0xA4, 0xA5, 0xB0, 0xB1: return .et
	case 0x2C, 0x2E, 0x2F, 0x3A, 0xA0: return .cs
	default: break
	}
	// Combining marks (NSM) — checked before the Hebrew/Arabic letter blocks.
	if (0x0300 ... 0x036F).contains(v) || (0x0483 ... 0x0489).contains(v)
		|| (0x0591 ... 0x05BD).contains(v) || v == 0x05BF || (0x05C1 ... 0x05C2).contains(v)
		|| (0x05C4 ... 0x05C5).contains(v) || v == 0x05C7
		|| (0x0610 ... 0x061A).contains(v) || (0x064B ... 0x065F).contains(v) || v == 0x0670
		|| (0x06D6 ... 0x06DC).contains(v) || (0x06DF ... 0x06E4).contains(v)
		|| (0x06E7 ... 0x06E8).contains(v) || (0x06EA ... 0x06ED).contains(v) {
		return .nsm
	}
	// Arabic-Indic digits (AN); Extended Arabic-Indic (Persian) digits are EN.
	if (0x06F0 ... 0x06F9).contains(v) { return .en }
	if (0x0660 ... 0x0669).contains(v) || v == 0x066B || v == 0x066C { return .an }
	// Hebrew → R.
	if (0x0590 ... 0x05FF).contains(v) || (0xFB1D ... 0xFB4F).contains(v) { return .r }
	// Arabic → AL (with the Arabic comma as a common separator).
	if (0x0600 ... 0x06FF).contains(v) || (0x0750 ... 0x077F).contains(v) || (0x08A0 ... 0x08FF).contains(v)
		|| (0xFB50 ... 0xFDFF).contains(v) || (0xFE70 ... 0xFEFF).contains(v) {
		return v == 0x060C ? .cs : .al
	}
	// ASCII punctuation/symbols are neutral; letters are strong L.
	if (0x21 ... 0x7E).contains(v) {
		let isLetter = (0x41 ... 0x5A).contains(v) || (0x61 ... 0x7A).contains(v)
		return isLetter ? .l : .on
	}
	return .l
}
