import Foundation

/// A light reader for the few stylesheet rules the writers that don't read CSS (Pages,
/// DOCX) take over: the top-level style rules of a stylesheet and the declarations in
/// their blocks. Shared by ``MarkdownAlertColors`` and ``MarkdownTextAlignment``.
enum MarkdownCSSRules {
	struct StyleRule {
		var selectors: [String]
		var declarations: String
	}

	struct Declaration {
		/// The property name, lowercased.
		var name: String
		/// The value, trimmed, without `!important`.
		var value: String
		var important: Bool
	}

	/// The top-level style rules, in order; comments and at-rules (with their blocks)
	/// are skipped.
	static func styleRules(in css: String) -> [StyleRule] {
		let text = css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
		var rules = [StyleRule]()
		var prelude = ""
		var block = ""
		var depth = 0
		for character in text {
			switch character {
			case "{":
				if depth > 0 { block.append(character) }
				depth += 1
			case "}":
				depth -= 1
				if depth > 0 {
					block.append(character)
				} else {
					depth = 0
					let selectors = prelude.trimmingCharacters(in: .whitespacesAndNewlines)
					if !selectors.hasPrefix("@") {
						rules.append(StyleRule(selectors: selectors.split(separator: ",").map(String.init), declarations: block))
					}
					prelude = ""
					block = ""
				}
			case ";" where depth == 0:
				prelude = ""                                  // e.g. `@import …;`
			default:
				if depth == 0 { prelude.append(character) } else { block.append(character) }
			}
		}
		return rules
	}

	/// The declarations in a rule's block, in order, with whether each is `!important`.
	static func declarations(in block: String) -> [Declaration] {
		var result = [Declaration]()
		for declaration in block.split(separator: ";") {
			guard let colon = declaration.firstIndex(of: ":") else { continue }
			let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			var value = String(declaration[declaration.index(after: colon)...])
			let importance = value.range(of: #"!\s*important\s*$"#, options: [.regularExpression, .caseInsensitive])
			if let importance { value.removeSubrange(importance) }
			value = value.trimmingCharacters(in: .whitespacesAndNewlines)
			result.append(Declaration(name: name, value: value, important: importance != nil))
		}
		return result
	}
}
