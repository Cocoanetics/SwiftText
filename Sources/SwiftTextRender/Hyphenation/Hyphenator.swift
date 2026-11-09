//  Hyphenator.swift
//  SwiftTextRender
//
//  Liang's hyphenation algorithm (as used by TeX): a table of small letter
//  patterns, each carrying a digit between and around its letters. Every
//  pattern that occurs in `.word.` votes with its digits; per position the
//  highest digit wins, and an odd winner marks a place where the word may be
//  split. Exceptions are whole words with their break points spelled out.
//  The pattern data lives in the per-language Hyphenation<XX>.swift files.

import Foundation

/// The raw pattern data of one language, in the TeX hyph-utf8 text format.
struct HyphenationPatterns {
	/// Fewest characters that must stay before the first break.
	let leftMin: Int
	/// Fewest characters that must stay after the last break.
	let rightMin: Int
	/// Whitespace-separated Liang patterns (`.ab3a`, `5erk`, …).
	let patterns: String
	/// Whitespace-separated words with their breaks marked by `-`.
	let exceptions: String
}

/// Finds the places where a word may be split with a hyphen.
final class Hyphenator: @unchecked Sendable {
	/// The hyphenator for a BCP 47 language tag (`de`, `de-AT`, `en_US`, …), or
	/// `nil` when no pattern set ships for its primary language.
	static func forLanguage(_ language: String?) -> Hyphenator? {
		guard let language else { return nil }
		let primary = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
		switch primary {
		case "de": return german
		case "en": return english
		case "fr": return french
		case "es": return spanish
		case "it": return italian
		case "nl": return dutch
		default: return nil
		}
	}

	private static let german = Hyphenator(.de)
	private static let english = Hyphenator(.en)
	private static let french = Hyphenator(.fr)
	private static let spanish = Hyphenator(.es)
	private static let italian = Hyphenator(.it)
	private static let dutch = Hyphenator(.nl)

	/// Words shorter than this (in letters) are never hyphenated, as in the
	/// initial value of CSS `hyphenate-limit-chars`.
	static let minimumWordLength = 5

	private let leftMin: Int
	private let rightMin: Int
	private var table: [String: [UInt8]] = [:]
	private var longestPattern = 0
	private var exceptions: [String: Set<Int>] = [:]
	private var cache: [String: Set<Int>] = [:]
	private let lock = NSLock()

	init(_ data: HyphenationPatterns) {
		leftMin = data.leftMin
		rightMin = data.rightMin
		for token in data.patterns.split(whereSeparator: \.isWhitespace) {
			var letters = ""
			var levels: [UInt8] = [0]
			for character in token {
				if let digit = character.wholeNumberValue, character.isASCII {
					levels[levels.count - 1] = UInt8(digit)
				} else {
					letters.append(character)
					levels.append(0)
				}
			}
			table[letters] = levels
			longestPattern = max(longestPattern, letters.count)
		}
		for entry in data.exceptions.split(whereSeparator: \.isWhitespace) {
			var word = ""
			var breaks = Set<Int>()
			for character in entry {
				if character == "-" { breaks.insert(word.count) } else { word.append(character) }
			}
			exceptions[word] = breaks
		}
	}

	/// Character offsets in `word` before which a hyphen may be inserted. Only
	/// runs of letters are considered, so trailing punctuation, digits and
	/// existing hyphens are left alone; each run must be at least
	/// ``minimumWordLength`` letters long.
	func breakOffsets(in word: String) -> Set<Int> {
		var result = Set<Int>()
		var run: [Character] = []
		var runStart = 0
		var offset = 0
		func flush() {
			if run.count >= Self.minimumWordLength {
				for position in breaks(inLetters: run) { result.insert(runStart + position) }
			}
			run.removeAll(keepingCapacity: true)
		}
		for character in word {
			if character.isLetter {
				if run.isEmpty { runStart = offset }
				run.append(character)
			} else {
				flush()
			}
			offset += 1
		}
		flush()
		return result
	}

	private func breaks(inLetters letters: [Character]) -> Set<Int> {
		let lowered = String(letters).lowercased()
		let key = Array(lowered)
		// Lowercasing that changes the length would shift every offset.
		guard key.count == letters.count else { return [] }
		lock.lock()
		defer { lock.unlock() }
		if let cached = cache[lowered] { return cached }
		let count = key.count
		var result = Set<Int>()
		if let known = exceptions[lowered] {
			result = known.filter { $0 > 0 && $0 < count }
		} else {
			let text: [Character] = ["."] + key + ["."]
			var levels = [UInt8](repeating: 0, count: text.count + 1)
			for start in 0 ..< text.count {
				var piece = ""
				for end in start ..< min(text.count, start + longestPattern) {
					piece.append(text[end])
					guard let pattern = table[piece] else { continue }
					for (index, level) in pattern.enumerated() where level > levels[start + index] {
						levels[start + index] = level
					}
				}
			}
			// A break before character `offset` sits between text[offset] and
			// text[offset + 1], which is levels[offset + 1].
			for offset in leftMin ... max(leftMin, count - rightMin) where offset < count && count - offset >= rightMin {
				if levels[offset + 1] % 2 == 1 { result.insert(offset) }
			}
		}
		cache[lowered] = result
		return result
	}
}
