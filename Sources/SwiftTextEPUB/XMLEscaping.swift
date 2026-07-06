//  XMLEscaping.swift
//  SwiftTextEPUB
//
//  Escaping for the XML the package builder emits by string interpolation
//  (OPF, nav, NCX, container, XHTML wrappers). Chapter *bodies* come pre-escaped
//  from the Markdown renderer's XHTML mode; these helpers cover the metadata and
//  attribute values the builder injects around them.

import Foundation

enum XML {
	/// Escapes text content: `&`, `<`, `>`.
	static func escapeText(_ string: String) -> String {
		var result = ""
		result.reserveCapacity(string.count)
		for character in string {
			switch character {
			case "&": result += "&amp;"
			case "<": result += "&lt;"
			case ">": result += "&gt;"
			default: result.append(character)
			}
		}
		return result
	}

	/// Escapes an attribute value: text plus `"`.
	static func escapeAttribute(_ string: String) -> String {
		var result = ""
		result.reserveCapacity(string.count)
		for character in string {
			switch character {
			case "&": result += "&amp;"
			case "<": result += "&lt;"
			case ">": result += "&gt;"
			case "\"": result += "&quot;"
			default: result.append(character)
			}
		}
		return result
	}
}
