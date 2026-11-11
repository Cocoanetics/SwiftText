//  SVGXML.swift
//  SwiftTextRender
//
//  A small XML tokenizer, enough for SVG: elements, attributes, entities,
//  comments, CDATA, processing instructions and a DOCTYPE. It is in-house
//  because Foundation's XMLParser is not available on every platform CI
//  covers. Text content is dropped — the static SVG subset has no use for it.

import Foundation

/// An XML element with its attributes, namespace prefix removed from names.
final class SVGXMLElement {
	let name: String
	var attributes: [String: String]
	var children: [SVGXMLElement] = []

	init(name: String, attributes: [String: String] = [:]) {
		self.name = name
		self.attributes = attributes
	}
}

enum SVGXML {

	/// The deepest element nesting accepted; deeper input is treated as malformed.
	static let maxDepth = 128

	/// Parse a document and return its root element, or `nil` if it is malformed.
	static func parse(_ data: Data) -> SVGXMLElement? {
		var bytes = [UInt8](data)
		if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
		let document = SVGXMLElement(name: "")
		var stack = [document]
		var index = 0

		func starts(_ literal: String) -> Bool {
			let utf8 = Array(literal.utf8)
			return index + utf8.count <= bytes.count && Array(bytes[index ..< index + utf8.count]) == utf8
		}
		/// Move past the next occurrence of `literal`; `false` if there is none.
		func skip(past literal: String) -> Bool {
			let utf8 = Array(literal.utf8)
			var cursor = index
			while cursor + utf8.count <= bytes.count {
				if bytes[cursor] == utf8[0], Array(bytes[cursor ..< cursor + utf8.count]) == utf8 {
					index = cursor + utf8.count
					return true
				}
				cursor += 1
			}
			return false
		}
		func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
		func skipSpaces() { while index < bytes.count, isSpace(bytes[index]) { index += 1 } }
		func readName() -> String {
			let start = index
			while index < bytes.count, !isSpace(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3E, bytes[index] != 0x3D {
				index += 1
			}
			var name = String(decoding: bytes[start ..< index], as: UTF8.self)
			if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
			return name
		}

		while index < bytes.count {
			guard bytes[index] == 0x3C else { index += 1; continue } // text is ignored
			if starts("<!--") {
				index += 4
				guard skip(past: "-->") else { return nil }
			} else if starts("<![CDATA[") {
				guard skip(past: "]]>") else { return nil }
			} else if starts("<?") {
				guard skip(past: "?>") else { return nil }
			} else if starts("<!") {
				// DOCTYPE: may carry an internal subset in brackets.
				var depth = 0
				while index < bytes.count {
					let byte = bytes[index]
					index += 1
					if byte == 0x5B { depth += 1 } else if byte == 0x5D { depth -= 1 } else if byte == 0x3E, depth <= 0 { break }
				}
			} else if starts("</") {
				guard stack.count > 1 else { return nil }
				guard skip(past: ">") else { return nil }
				stack.removeLast()
			} else {
				index += 1
				let name = readName()
				guard !name.isEmpty else { return nil }
				let element = SVGXMLElement(name: name)
				var selfClosing = false
				var closed = false
				while index < bytes.count {
					skipSpaces()
					guard index < bytes.count else { return nil }
					if bytes[index] == 0x2F {
						selfClosing = true
						index += 1
					} else if bytes[index] == 0x3E {
						index += 1
						closed = true
						break
					} else {
						let key = readName()
						guard !key.isEmpty else { return nil }
						skipSpaces()
						guard index < bytes.count, bytes[index] == 0x3D else { return nil }
						index += 1
						skipSpaces()
						guard index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 else { return nil }
						let quote = bytes[index]
						index += 1
						let start = index
						while index < bytes.count, bytes[index] != quote { index += 1 }
						guard index < bytes.count else { return nil }
						let raw = String(decoding: bytes[start ..< index], as: UTF8.self)
						index += 1
						element.attributes[key] = decodeEntities(raw)
					}
				}
				guard closed else { return nil }
				stack.last!.children.append(element)
				if !selfClosing {
					stack.append(element)
					guard stack.count <= maxDepth else { return nil }
				}
			}
		}
		guard stack.count == 1, let root = document.children.first else { return nil }
		return root
	}

	/// Replace the predefined and numeric character references.
	static func decodeEntities(_ text: String) -> String {
		guard text.contains("&") else { return text }
		var result = ""
		var rest = Substring(text)
		while let amp = rest.firstIndex(of: "&") {
			result += rest[rest.startIndex ..< amp]
			let afterAmp = rest.index(after: amp)
			guard let semi = rest[afterAmp...].firstIndex(of: ";"), rest.distance(from: afterAmp, to: semi) <= 10 else {
				result += "&"
				rest = rest[afterAmp...]
				continue
			}
			let entity = rest[afterAmp ..< semi]
			var replacement: String?
			switch entity {
			case "lt": replacement = "<"
			case "gt": replacement = ">"
			case "amp": replacement = "&"
			case "quot": replacement = "\""
			case "apos": replacement = "'"
			default:
				if entity.hasPrefix("#") {
					let digits = entity.dropFirst()
					let code = digits.hasPrefix("x") || digits.hasPrefix("X")
						? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
					if let code, let scalar = Unicode.Scalar(code) { replacement = String(Character(scalar)) }
				}
			}
			if let replacement {
				result += replacement
				rest = rest[rest.index(after: semi)...]
			} else {
				result += "&"
				rest = rest[afterAmp...]
			}
		}
		return result + rest
	}
}
