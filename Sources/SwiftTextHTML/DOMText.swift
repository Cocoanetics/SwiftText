import Foundation

final class DOMText: DOMNode, @unchecked Sendable {
	let name: String
	let textValue: String
	let preserveWhitespace: Bool

	init(text: String, preserveWhitespace: Bool = false) {
		self.name = "#text"
		self.textValue = text
		self.preserveWhitespace = preserveWhitespace
	}

	func markdown() -> String {
		if preserveWhitespace {
			return textValue
		}

		let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
		let leadingSpace = textValue.hasPrefix(" ") ? " " : ""
		let trailingSpace = textValue.hasSuffix(" ") ? " " : ""
		let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
		return leadingSpace + collapsed + trailingSpace
	}

	func markdown(imageResolver: ((String) -> String?)?) -> String {
		markdown()
	}

	var sourceText: String { textValue }

	func text() -> String {
		if preserveWhitespace {
			return textValue
		}

		// Every run of whitespace becomes one space, including a run at either
		// end: a newline or tab closing a text node separates words just as a
		// space does, and the node boundary is the one place that separator
		// cannot be recovered later. ``DOMElement/text()`` trims each block, so
		// the edges of a block do not keep the space this leaves behind.
		return textValue.replacingOccurrences(
			of: "\\s+", with: " ", options: .regularExpression)
	}
}
