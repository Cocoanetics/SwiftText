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

	/// The page size in points from the last `@page { size }` declaration in `css`,
	/// or nil when there is none (or it can't be understood). A value with only an
	/// orientation (`landscape`, `portrait`) applies to `fallback`, the portrait paper.
	package static func pointSize(in css: String, fallback: (width: Double, height: Double)? = nil) -> (width: Double, height: Double)? {
		var result: (width: Double, height: Double)?
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
			for declaration in top.split(separator: ";") {
				let parts = declaration.split(separator: ":", maxSplits: 1)
				guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "size",
				      let size = parse(String(parts[1]), fallback: fallback) else { continue }
				result = size
			}
			if close == source.endIndex { break }
			search = close..<source.endIndex
		}
		return result
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
