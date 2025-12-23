import Foundation

final class DOMText: DOMNode
{
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

	func text() -> String {
		if preserveWhitespace {
			return textValue
		}

		let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
		let leadingSpace = textValue.hasPrefix(" ") ? " " : ""
		let trailingSpace = textValue.hasSuffix(" ") ? " " : ""
		let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
		return leadingSpace + collapsed + trailingSpace
	}
}
