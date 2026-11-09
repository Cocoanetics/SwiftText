import Foundation

/// Reads the page size an author stylesheet asks for with `@page { size: … }`.
///
/// WebKit's print pipeline ignores that descriptor, so the paper size has to be
/// taken from the CSS up front and handed to the paginator.
package enum PageSizeRule {
	/// Named page sizes in millimetres, portrait.
	private static let named: [String: (width: Double, height: Double)] = [
		"a3": (297, 420), "a4": (210, 297), "a5": (148, 210), "b5": (176, 250),
		"letter": (215.9, 279.4), "legal": (215.9, 355.6)
	]

	private static let pointsPerUnit: [String: Double] = [
		"mm": 72 / 25.4, "cm": 72 / 2.54, "in": 72, "pt": 1, "pc": 12, "px": 0.75
	]

	/// One `@page` rule: its selector text (`wide`, `:first`, empty for a bare rule) and
	/// its top-level declarations, in order. Margin boxes nested in the rule are skipped.
	private struct Rule {
		let prelude: String
		let declarations: [(name: String, value: String)]
	}

	private static func rules(in css: String) -> [Rule] {
		var result: [Rule] = []
		let source = stripComments(css)
		var search = source.startIndex..<source.endIndex
		while let at = source.range(of: "@page", options: .caseInsensitive, range: search),
		      let open = source[at.upperBound...].firstIndex(of: "{") {
			// Margin boxes nest braces inside the rule; only top-level declarations count.
			var depth = 0
			var top = ""
			var close = source.endIndex
			for index in source[open...].indices {
				let character = source[index]
				if character == "{" {
					depth += 1
					if depth > 1 { top.append(";") }
				} else if character == "}" {
					depth -= 1
					if depth == 0 { close = index; break }
				} else if depth == 1 {
					top.append(character)
				}
			}
			var declarations: [(name: String, value: String)] = []
			for declaration in top.split(separator: ";") {
				let parts = declaration.split(separator: ":", maxSplits: 1)
				guard parts.count == 2 else { continue }
				declarations.append((parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
				                     parts[1].trimmingCharacters(in: .whitespacesAndNewlines)))
			}
			result.append(Rule(prelude: source[at.upperBound..<open].trimmingCharacters(in: .whitespacesAndNewlines), declarations: declarations))
			if close == source.endIndex { break }
			search = close..<source.endIndex
		}
		return result
	}

	/// The page size in points from the last bare `@page { size }` declaration in `css`,
	/// or nil when there is none (or it can't be understood). A value with only an
	/// orientation (`landscape`, `portrait`) applies to `fallback`, the portrait paper.
	/// Named (`@page wide`) and pseudo-class (`@page :first`) rules never set the
	/// document's size.
	package static func pointSize(in css: String, fallback: (width: Double, height: Double)? = nil) -> (width: Double, height: Double)? {
		var result: (width: Double, height: Double)?
		for rule in rules(in: css) where rule.prelude.isEmpty {
			for declaration in rule.declarations where declaration.name == "size" {
				if let size = parse(declaration.value, fallback: fallback) { result = size }
			}
		}
		return result
	}

	/// A page name an author stylesheet gives a size and margins with `@page <name>`.
	package struct NamedPage: Equatable {
		package let name: String
		/// The paper size in points, when the rule has a `size` (an orientation alone applies to `fallback`).
		package let size: (width: Double, height: Double)?
		/// The rule's `margin` and `margin-*` declarations, as written.
		package let margins: [(name: String, value: String)]

		package static func == (lhs: NamedPage, rhs: NamedPage) -> Bool {
			lhs.name == rhs.name && lhs.size?.width == rhs.size?.width && lhs.size?.height == rhs.size?.height
				&& lhs.margins.map { "\($0.name):\($0.value)" } == rhs.margins.map { "\($0.name):\($0.value)" }
		}
	}

	/// The `@page <name>` rules in `css` (a name with no pseudo-class), merged per name in source order.
	package static func namedPages(in css: String, fallback: (width: Double, height: Double)? = nil) -> [NamedPage] {
		var order: [String] = []
		var sizes: [String: (width: Double, height: Double)] = [:]
		var margins: [String: [(name: String, value: String)]] = [:]
		for rule in rules(in: css) {
			let name = rule.prelude
			guard let first = name.unicodeScalars.first, !name.contains(":"), !name.contains(where: \.isWhitespace),
			      first != "." else { continue }
			if !order.contains(name) { order.append(name) }
			for declaration in rule.declarations {
				if declaration.name == "size", let size = parse(declaration.value, fallback: fallback) {
					sizes[name] = size
				} else if declaration.name == "margin" || declaration.name.hasPrefix("margin-") {
					margins[name, default: []].append(declaration)
				}
			}
		}
		return order.map { NamedPage(name: $0, size: sizes[$0], margins: margins[$0] ?? []) }
	}

	/// The selectors of the style rules in `css` that declare `page: <name>`, with the name.
	/// `page: auto` is kept (it resets an inherited name); the cascade is left to the
	/// browser. Only rule groups that apply when printing are searched.
	package static func pageAssignments(in css: String) -> [(selector: String, name: String, important: Bool)] {
		var result: [(selector: String, name: String, important: Bool)] = []
		let source = stripComments(css)
		var index = source.startIndex
		while let open = source[index...].firstIndex(of: "{") {
			var depth = 0
			var close = source.endIndex
			for position in source[open...].indices {
				if source[position] == "{" { depth += 1 } else if source[position] == "}" {
					depth -= 1
					if depth == 0 { close = position; break }
				}
			}
			// Statement at-rules (`@import …;`, `@charset …;`) have no block and end at their `;`.
			let head = source[index..<open]
			let prelude = (head.lastIndex(of: ";").map { head[head.index(after: $0)...] } ?? head).trimmingCharacters(in: .whitespacesAndNewlines)
			if close == source.endIndex { break }
			let body = String(source[source.index(after: open)..<close])
			if prelude.hasPrefix("@") {
				// A grouping rule (`@media print { … }`) holds style rules of its own.
				if appliesWhenPrinting(prelude) { result += pageAssignments(in: body) }
			} else if !prelude.isEmpty {
				for declaration in body.split(separator: ";") {
					let parts = declaration.split(separator: ":", maxSplits: 1)
					guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "page" else { continue }
					var words = parts[1].split(whereSeparator: \.isWhitespace).map(String.init)
					let important = words.last?.lowercased() == "!important"
					if important { words.removeLast() }
					if words.count == 1, let name = words.first, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
						result.append((prelude, name.lowercased() == "auto" ? "auto" : name, important))
					}
				}
			}
			index = source.index(after: close)
		}
		return result
	}

	/// Whether the rules inside an at-rule group are in force when printing: `@media`
	/// for print or all media, and `@supports`; other at-rules hold no style rules.
	private static func appliesWhenPrinting(_ prelude: String) -> Bool {
		let lower = prelude.lowercased()
		if lower.hasPrefix("@supports") { return true }
		guard lower.hasPrefix("@media") else { return false }
		let queries = lower.dropFirst("@media".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
		return queries.contains { query in
			guard !query.hasPrefix("not ") else { return false }
			let type = query.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init) ?? ""
			return type == "print" || type == "all" || query.hasPrefix("(")
		}
	}

	/// The left and right page margins of the unnamed `@page` rules, with their
	/// `:first`, `:left` and `:right` variants (for example 22 mm inside, 17 mm outside).
	///
	/// WebKit's print pipeline lays every page out against one set of margins, so the
	/// paginator is given the recto's and the other pages are shifted sideways afterwards.
	package struct PageSideMargins {
		struct Entry {
			let first: Bool
			let side: String?
			let left: Double?
			let right: Double?
			var specificity: Int { (first ? 10 : 0) + (side == nil ? 0 : 1) }
		}

		let entries: [Entry]

		/// The margins of the page at `pageIndex`, in points; page 1 (index 0) is a right-hand page.
		package func margins(pageIndex: Int) -> (left: Double, right: Double) {
			var left = 2 * 72 / 2.54, right = left // the print stylesheet's own `@page { margin: 2cm }`
			let isRight = pageIndex.isMultiple(of: 2)
			let matching = entries.enumerated().filter { _, entry in
				(!entry.first || pageIndex == 0) && (entry.side == nil || (entry.side == "right") == isRight)
			}.sorted { ($0.element.specificity, $0.offset) < ($1.element.specificity, $1.offset) }
			for (_, entry) in matching {
				if let value = entry.left { left = value }
				if let value = entry.right { right = value }
			}
			return (left, right)
		}

		/// The margins every page is laid out with: those of a right-hand page that is not the first.
		package var layoutMargins: (left: Double, right: Double) { margins(pageIndex: 2) }

		/// How far page `pageIndex`'s content moves to the right to sit at its own left margin.
		package func shift(pageIndex: Int) -> Double {
			margins(pageIndex: pageIndex).left - layoutMargins.left
		}
	}

	/// The side margins `css` gives its `@page`, :first, :left and :right rules, or nil
	/// when none of the pseudo-class rules sets a left or right margin.
	package static func sideMargins(in css: String) -> PageSideMargins? {
		var entries: [PageSideMargins.Entry] = []
		var sawPseudo = false
		for rule in rules(in: css) {
			var first = false
			var side: String?
			var supported = true
			if !rule.prelude.isEmpty {
				let parts = rule.prelude.split(separator: ":", omittingEmptySubsequences: false)
				guard parts.first.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) == true else { continue } // a named page
				for part in parts.dropFirst() {
					switch part.trimmingCharacters(in: .whitespaces).lowercased() {
					case "first": first = true
					case "left", "right": side = part.trimmingCharacters(in: .whitespaces).lowercased()
					default: supported = false
					}
				}
			}
			guard supported else { continue }
			var left: Double?
			var right: Double?
			for declaration in rule.declarations {
				let values = declaration.value.split(whereSeparator: \.isWhitespace).map { length($0.lowercased()) }
				switch declaration.name {
				case "margin-left": if values.count == 1, let value = values[0] { left = value }
				case "margin-right": if values.count == 1, let value = values[0] { right = value }
				case "margin":
					guard (1...4).contains(values.count), values.allSatisfy({ $0 != nil }) else { continue }
					let lengths = values.compactMap { $0 }
					right = lengths.count == 1 ? lengths[0] : lengths[1]
					left = lengths.count == 4 ? lengths[3] : right
				default: break
				}
			}
			guard left != nil || right != nil else { continue }
			if first || side != nil { sawPseudo = true }
			entries.append(.init(first: first, side: side, left: left, right: right))
		}
		return sawPseudo ? PageSideMargins(entries: entries) : nil
	}

	private static func parse(_ value: String, fallback: (width: Double, height: Double)?) -> (width: Double, height: Double)? {
		var landscape = false
		var sawOrientation = false
		var base: (width: Double, height: Double)?
		var lengths: [Double] = []
		for word in value.split(whereSeparator: \.isWhitespace) {
			let lower = word.lowercased()
			if lower == "landscape" {
				landscape = true
				sawOrientation = true
			} else if lower == "portrait" {
				sawOrientation = true
			} else if let size = named[lower] {
				base = (size.width * 72 / 25.4, size.height * 72 / 25.4)
			} else if let points = length(lower) {
				lengths.append(points)
			} else if lower != "auto" {
				return nil
			}
		}
		if let base {
			return landscape ? (base.height, base.width) : base
		}
		if lengths.count >= 2 { return (lengths[0], lengths[1]) }
		if lengths.count == 1 { return (lengths[0], lengths[0]) }
		if let fallback, sawOrientation { return landscape ? (fallback.height, fallback.width) : fallback }
		return nil
	}

	private static func length(_ text: String) -> Double? {
		for (unit, factor) in pointsPerUnit where text.hasSuffix(unit) {
			if let number = Double(text.dropLast(unit.count)), number > 0 { return number * factor }
		}
		return nil
	}

	private static func stripComments(_ css: String) -> String {
		var result = css
		while let start = result.range(of: "/*") {
			let end = result.range(of: "*/", range: start.upperBound..<result.endIndex)?.upperBound ?? result.endIndex
			result.removeSubrange(start.lowerBound..<end)
		}
		return result
	}
}
