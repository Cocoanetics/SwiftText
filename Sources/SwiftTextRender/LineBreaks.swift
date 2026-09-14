//  LineBreaks.swift
//  SwiftTextRender

import Foundation
#if canImport(Darwin)
import CoreFoundation
#endif

func preferredLineBreakOffsets(in word: String) -> Set<Int> {
	#if canImport(Darwin)
	let string = word as CFString
	let length = CFStringGetLength(string)
	let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: length),
	                                        kCFStringTokenizerUnitLineBreak, nil)
	var offsets = Set<Int>()
	while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
		let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
		let offset = range.location + range.length
		if offset < length { offsets.insert(offset) }
	}
	return offsets
	#else
	// Core Foundation's line-break tokenizer is Darwin-only. Keep the
	// portable engines consistent for the common UAX #14 HY/SY cases.
	let breakAfter: Set<UInt32> = [
		0x002D, // HYPHEN-MINUS (HY)
		0x002F, // SOLIDUS (SY)
		0x058A, 0x05BE, 0x1400, 0x2010, 0x2012, 0x2013, 0x2014, 0x2E17, 0x2E40
	]
	let length = word.utf16.count
	var utf16Offset = 0
	var offsets = Set<Int>()
	for character in word {
		utf16Offset += character.utf16.count
		if utf16Offset < length,
		   character.unicodeScalars.count == 1,
		   let scalar = character.unicodeScalars.first,
		   breakAfter.contains(scalar.value) {
			offsets.insert(utf16Offset)
		}
	}
	return offsets
	#endif
}
