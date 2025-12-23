import Foundation

/// Represents a parsed DOCX document and its paragraph content.
public struct DocxDocument {
	/// The paragraphs in document order.
	public internal(set) var paragraphs: [Paragraph] = []
	internal var styles = StyleCatalog()
	internal var numbering = NumberingCatalog()

	public init() {}

	/// Returns plain text for each paragraph with formatting removed.
	public func plainTextParagraphs() -> [String] {
		renderedParagraphs(style: .plainText).map(\.text)
	}

	/// Returns rendered paragraphs for Markdown output.
	public func markdownParagraphs() -> [RenderedParagraph] {
		renderedParagraphs(style: .markdown)
	}

	/// Returns rendered paragraphs using the requested style.
	public func renderedParagraphs(style: RenderStyle = .markdown) -> [RenderedParagraph] {
		var numberingState = NumberingState(numbering: numbering)
		return paragraphs.compactMap { paragraph in
			paragraph.rendered(using: self, numberingState: &numberingState, style: style)
		}
	}

	/// Returns the detected heading level for a paragraph style identifier.
	public func headingLevel(for styleIdentifier: String?) -> Int? {
		styles.style(for: styleIdentifier)?.headingLevel()
	}

	internal func headingPrefix(for styleIdentifier: String?) -> String? {
		guard let level = headingLevel(for: styleIdentifier) else {
			return nil
		}
		let clamped = max(1, min(level, 6))
		return String(repeating: "#", count: clamped) + " "
	}

	/// Controls how paragraph text is rendered.
	public enum RenderStyle {
		case plainText
		case markdown
	}

	/// Represents a DOCX paragraph consisting of styled text runs.
	public struct Paragraph {
		public private(set) var runs: [Run] = []
		public internal(set) var styleIdentifier: String?
		public internal(set) var numbering: NumberingReference?

		/// Returns the raw text for the paragraph without any formatting.
		public var text: String {
			runs.map(\.text).joined()
		}

		/// Indicates whether the paragraph belongs to a list.
		public var isListItem: Bool {
			numbering != nil
		}

		/// Returns the list indentation level when the paragraph is part of a list.
		public var listLevel: Int? {
			numbering?.level
		}

		/// Returns a normalized plain text version of the paragraph.
		public func plainText() -> String {
			DocxDocument.normalizedText(text)
		}

		internal mutating func append(text: String, formatting: FormatState) {
			guard !text.isEmpty else {
				return
			}
			let newRun = Run(text: text, bold: formatting.bold, italic: formatting.italic)
			if let last = runs.last, last.bold == newRun.bold, last.italic == newRun.italic {
				runs[runs.count - 1].text += newRun.text
			} else {
				runs.append(newRun)
			}
		}

		internal var isEmpty: Bool {
			runs.isEmpty
		}

		fileprivate func rendered(using document: DocxDocument, numberingState: inout NumberingState, style: RenderStyle) -> RenderedParagraph? {
			let joined: String
			switch style {
			case .plainText:
				joined = runs.map(\.text).joined()
			case .markdown:
				joined = runs.map { $0.markedUp() }.joined()
			}
			var result = DocxDocument.normalizedText(joined)
			guard !result.isEmpty else {
				return nil
			}

			let isListItem = numbering != nil
			if let numbering, let prefix = numberingState.prefix(for: numbering), style == .markdown {
				result = prefix + result
			}

			if style == .markdown, let headingPrefix = document.headingPrefix(for: styleIdentifier) {
				result = headingPrefix + result
			}

			return RenderedParagraph(text: result, isListItem: isListItem)
		}
	}

	/// Represents a styled text run within a paragraph.
	public struct Run {
		public var text: String
		public let bold: Bool
		public let italic: Bool

		/// Returns the run text with Markdown bold/italic markers applied.
		public func markedUp() -> String {
			guard !text.isEmpty else {
				return ""
			}
			let components = splitWhitespace(from: text)
			guard !components.core.isEmpty else {
				return text
			}
			switch (bold, italic) {
			case (true, true):
				return components.leading + "***\(components.core)***" + components.trailing
			case (true, false):
				return components.leading + "**\(components.core)**" + components.trailing
			case (false, true):
				return components.leading + "*\(components.core)*" + components.trailing
			default:
				return text
			}
		}

		private func splitWhitespace(from value: String) -> (leading: String, core: String, trailing: String) {
			var startIndex = value.startIndex
			while startIndex < value.endIndex && value[startIndex].isWhitespace {
				startIndex = value.index(after: startIndex)
			}
			var endIndex = value.endIndex
			while endIndex > startIndex {
				let before = value.index(before: endIndex)
				if value[before].isWhitespace {
					endIndex = before
				} else {
					break
				}
			}
			let leading = String(value[..<startIndex])
			let trailing = String(value[endIndex...])
			let core = String(value[startIndex..<endIndex])
			return (leading, core, trailing)
		}
	}

	/// Represents a rendered paragraph, optionally marked as a list item.
	public struct RenderedParagraph {
		public let text: String
		public let isListItem: Bool
	}

	internal struct FormatState {
		var bold = false
		var italic = false
	}

	internal struct StyleCatalog {
		private var paragraphStyles: [String: ParagraphStyle] = [:]

		mutating func add(_ style: ParagraphStyle) {
			paragraphStyles[style.styleId] = style
		}

		func style(for identifier: String?) -> ParagraphStyle? {
			guard let identifier else {
				return nil
			}
			return paragraphStyles[identifier]
		}
	}

	internal struct ParagraphStyle {
		let styleId: String
		var name: String?
		var outlineLevel: Int?

		func headingLevel() -> Int? {
			let identifier = (name ?? styleId).lowercased()
			if identifier.contains("subtitle") {
				return 2
			}
			if identifier.contains("title") {
				return 1
			}
			if identifier.contains("subheading") {
				return 3
			}
			if let explicit = explicitHeadingLevel(in: identifier) {
				return explicit
			}
			if let outlineLevel, outlineLevel < 9 {
				return outlineLevel + 1
			}
			if identifier.contains("heading") {
				return 2
			}
			return nil
		}

		private func explicitHeadingLevel(in identifier: String) -> Int? {
			var digits = ""
			for character in identifier {
				if character.isNumber {
					digits.append(character)
				} else if !digits.isEmpty {
					break
				}
			}
			guard !digits.isEmpty, let value = Int(digits) else {
				return nil
			}
			return value
		}
	}

	internal struct NumberingCatalog {
		private var levelsByAbstractId: [Int: [Int: NumberingLevel]] = [:]
		private var abstractIdByNumId: [Int: Int] = [:]

		mutating func addLevel(_ level: NumberingLevel, to abstractId: Int) {
			var levels = levelsByAbstractId[abstractId] ?? [:]
			levels[level.level] = level
			levelsByAbstractId[abstractId] = levels
		}

		mutating func map(numId: Int, to abstractId: Int) {
			abstractIdByNumId[numId] = abstractId
		}

		func levels(for abstractId: Int) -> [Int: NumberingLevel]? {
			levelsByAbstractId[abstractId]
		}

		mutating func setLevels(_ levels: [Int: NumberingLevel], for abstractId: Int) {
			levelsByAbstractId[abstractId] = levels
		}

		func level(for reference: DocxDocument.NumberingReference) -> NumberingLevel? {
			guard
				let abstractId = abstractIdByNumId[reference.numId],
				let level = levelsByAbstractId[abstractId]?[reference.level]
			else {
				return nil
			}
			return level
		}

		struct NumberingLevel {
			let level: Int
			let start: Int
			let format: NumberingFormat
			let text: String?
		}
	}

	internal enum NumberingFormat: Equatable {
		case bullet
		case decimal
		case lowerLetter
		case upperLetter
		case lowerRoman
		case upperRoman
		case ordinal
		case cardinalText
		case ordinalText
		case decimalZero
		case other(String)

		init(rawValue: String) {
			switch rawValue {
			case "bullet":
				self = .bullet
			case "decimal":
				self = .decimal
			case "lowerLetter":
				self = .lowerLetter
			case "upperLetter":
				self = .upperLetter
			case "lowerRoman":
				self = .lowerRoman
			case "upperRoman":
				self = .upperRoman
			case "ordinal":
				self = .ordinal
			case "cardinalText":
				self = .cardinalText
			case "ordinalText":
				self = .ordinalText
			case "decimalZero":
				self = .decimalZero
			default:
				self = .other(rawValue)
			}
		}

		var isBullet: Bool {
			if case .bullet = self {
				return true
			}
			return false
		}

		func formattedValue(for number: Int) -> String {
			let value = max(number, 1)
			switch self {
			case .decimal, .decimalZero, .ordinal, .ordinalText, .cardinalText, .other:
				return "\(value)."
			case .lowerLetter:
				return "\(alphabeticLabel(for: value, uppercase: false))."
			case .upperLetter:
				return "\(alphabeticLabel(for: value, uppercase: true))."
			case .lowerRoman:
				return "\(romanNumeral(for: value, uppercase: false))."
			case .upperRoman:
				return "\(romanNumeral(for: value, uppercase: true))."
			case .bullet:
				return "-"
			}
		}

		private func alphabeticLabel(for value: Int, uppercase: Bool) -> String {
			guard value > 0 else {
				return "a"
			}
			var index = value
			var result = ""
			let baseScalarValue = Character("a").unicodeScalars.first!.value
			while index > 0 {
				index -= 1
				let scalarValue = Int(baseScalarValue) + (index % 26)
				if let scalar = UnicodeScalar(scalarValue) {
					result = String(Character(scalar)) + result
				}
				index /= 26
			}
			return uppercase ? result.uppercased() : result
		}

		private func romanNumeral(for value: Int, uppercase: Bool) -> String {
			guard value > 0 else {
				return "\(value)"
			}
			let symbols: [(Int, String)] = [
				(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
				(100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
				(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")
			]
			var remaining = value
			var result = ""
			for (arabic, roman) in symbols {
				while remaining >= arabic {
					result += roman
					remaining -= arabic
				}
			}
			return uppercase ? result : result.lowercased()
		}
	}

	/// References the numbering definition for a list item.
	public struct NumberingReference: Hashable {
		public let numId: Int
		public let level: Int
	}

	internal struct NumberingState {
		let numbering: NumberingCatalog
		private var counters: [CounterKey: Int] = [:]

		init(numbering: NumberingCatalog) {
			self.numbering = numbering
		}

		mutating func prefix(for reference: NumberingReference) -> String? {
			guard let level = numbering.level(for: reference) else {
				return nil
			}
			let indent = String(repeating: "  ", count: max(reference.level, 0))
			if level.format.isBullet {
				return indent + "- "
			}
			let nextValue = nextValue(for: reference, start: level.start)
			let formatted = level.format.formattedValue(for: nextValue)
			return indent + "\(formatted) "
		}

		private mutating func nextValue(for reference: NumberingReference, start: Int) -> Int {
			let key = CounterKey(numId: reference.numId, level: reference.level)
			let next: Int
			if let current = counters[key] {
				next = current + 1
			} else {
				next = max(start, 1)
			}
			counters[key] = next
			counters = counters.filter { pair in
				guard pair.key.numId == reference.numId else { return true }
				return pair.key.level <= reference.level
			}
			return next
		}

		private struct CounterKey: Hashable {
			let numId: Int
			let level: Int
		}
	}

	private static func normalizedText(_ value: String) -> String {
		value
			.replacingOccurrences(of: "\t", with: "    ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
