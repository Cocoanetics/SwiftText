import Foundation

public class DOMElement: DOMNode
{
	// MARK: - Public Properties

	public let name: String
	public let attributes: [AnyHashable: Any]
	public var children: [DOMNode]

	// MARK: - Initialization

	init(name: String, attributes: [AnyHashable: Any] = [:]) {
		self.name = name
		self.attributes = attributes
		self.children = []
	}

	// MARK: - Public Functions

	func addChild(_ child: DOMNode)
	{
		children.append(child)
	}

	public func markdown() -> String
	{
		markdown(imageResolver: nil)
	}

	public func markdown(imageResolver: ((String) -> String?)?) -> String
	{
		if ["script", "style", "iframe", "nav", "meta", "link", "title", "select", "input", "button", "noscript", "footer"].contains(name)
		{
			return ""
		}

		var result = ""

		switch name
		{
		case "p", "div":
			var content = ""

			for child in children
			{
				if child.isBlockLevelElement
				{
					content.ensureTwoTrailingNewlines()
				}

					content += child.markdown(imageResolver: imageResolver)
				}

			content = content.trimmingCharacters(in: .whitespacesAndNewlines)

			guard !content.isEmpty else {
				return ""
			}
			result += content

		case "b", "strong":
			let content = children.map { $0.markdown(imageResolver: imageResolver) }.joined()
			result += handleInlineElement(content, with: "**")

		case "i", "em":
			let content = children.map { $0.markdown(imageResolver: imageResolver) }.joined()
			result += handleInlineElement(content, with: "*")

		case "a":
			let href = attributes["href"] as? String ?? ""
			let content = children.map { $0.markdown(imageResolver: imageResolver) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

			if href.contains("#"),
			   let components = URLComponents(string: href),
			   components.fragment != nil
			{
				result += content
			}
			else if !href.isEmpty, !content.isEmpty
			{
				result += "[" + content + "]" + "(\(href))"
			}

		case "img":
			let src = attributes["src"] as? String ?? ""
			let alt = attributes["alt"] as? String ?? "Image"
			let resolvedSrc = imageResolver?(src) ?? src

			if !resolvedSrc.isEmpty, !resolvedSrc.hasPrefix("data:")
			{
				result += "![\(alt)](\(resolvedSrc))"
			}

		case "figcaption":
			let content = children.map { $0.markdown(imageResolver: imageResolver) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
			result = "\n" + content

		case "br":
			result += "\n"

		case "ul":
			for child in children {
				let childText = child.markdown(imageResolver: imageResolver)
				if !childText.isEmpty {
					result += "- " + childText + "\n"
				}
			}

		case "ol":
			var index = 1
			for child in children {
				let childText = child.markdown(imageResolver: imageResolver)
				if !childText.isEmpty {
					result += "\(index). " + childText + "\n"
					index += 1
				}
			}

		case "li":
			let content = children.map { $0.markdown(imageResolver: imageResolver) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
			guard !content.isEmpty else {
				return ""
			}
			result += content

		case "h1":
			result += "# " + children.map { $0.markdown(imageResolver: imageResolver) }.joined()

		case "h2":
			result += "## " + children.map { $0.markdown(imageResolver: imageResolver) }.joined()

		case "h3":
			result += "### " + children.map { $0.markdown(imageResolver: imageResolver) }.joined()

		case "h4":
			result += "#### " + children.map { $0.markdown(imageResolver: imageResolver) }.joined()

		case "h5":
			result += "##### " + children.map { $0.markdown(imageResolver: imageResolver) }.joined()

		case "h6":
			result += "###### " + children.map { $0.markdown(imageResolver: imageResolver) }.joined()

		case "table":
			let columns = buildTableColumns(imageResolver: imageResolver)
			result += formatTable(columns: columns)

		case "tr":
			let cells = children.map { $0.markdown(imageResolver: imageResolver).trimmingCharacters(in: .whitespacesAndNewlines) }
			result += cells.joined(separator: " | ") + "\n"

		case "th":
			let content = children.map { $0.markdown(imageResolver: imageResolver) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
			let normalized = normalizeTableCellContent(content)
			result += "**" + normalized + "**"

		case "td":
			let content = children.map { $0.markdown(imageResolver: imageResolver) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
			let normalized = normalizeTableCellContent(content)
			result += normalized

		case "blockquote":
			let blockquoteContent = children.map { $0.markdown(imageResolver: imageResolver).trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n")
			result += "> " + blockquoteContent.replacingOccurrences(of: "\n", with: "\n> ")

		case "pre":
			let preContent: String

			if let code = children.first as? DOMElement, code.name == "code", children.count == 1
			{
					preContent = code.children.map { $0.markdown(imageResolver: imageResolver) }.joined().trimmingCharacters(in: .newlines)
				}
				else
				{
					preContent = children.map { $0.markdown(imageResolver: imageResolver) }.joined().trimmingCharacters(in: .newlines)
				}

			result += "```\n" + preContent + "\n```\n"

		case "code":
			let content = children.map { $0.markdown(imageResolver: imageResolver) }.joined()
			result += handleInlineElement(content, with: "`")

		default:
			result += children.map { $0.markdown(imageResolver: imageResolver) }.joined()
		}

		if isBlockLevelElement
		{
			result.ensureTwoTrailingNewlines()
		}

		return result
	}

	public func text() -> String
	{
		if ["script", "style", "iframe", "nav", "meta", "link", "title", "select", "input", "button", "noscript", "footer"].contains(name)
		{
			return ""
		}

		var result = ""

		switch name
		{
		case "br":
			result += "\n"

		case "ul", "ol":
			for child in children {
				let childText = child.text().trimmingCharacters(in: .whitespacesAndNewlines)
				guard !childText.isEmpty else { continue }
				result += childText
				result.ensureTwoTrailingNewlines()
			}

		case "li":
			let content = children.map { $0.text() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
			guard !content.isEmpty else {
				return ""
			}
			result += content

		case "table":
			let rows = collectTableRows()
			for row in rows {
				let rowText = row.text().trimmingCharacters(in: .whitespacesAndNewlines)
				guard !rowText.isEmpty else { continue }
				result += rowText + "\n"
			}

		case "tr":
			let cells = children.map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
			result += cells.filter { !$0.isEmpty }.joined(separator: " | ")

		default:
			result += children.map { $0.text() }.joined()
		}

		if isBlockLevelElement
		{
			result.ensureTwoTrailingNewlines()
		}

		return result
	}

	private func handleInlineElement(_ content: String, with markdownSyntax: String) -> String {
		let leadingWhitespaceRange = content.range(of: "^\\s+", options: .regularExpression)
		let leadingWhitespace = leadingWhitespaceRange.map { String(content[$0]) } ?? ""

		let trailingWhitespaceRange = content.range(of: "\\s+$", options: .regularExpression)
		let trailingWhitespace = trailingWhitespaceRange.map { String(content[$0]) } ?? ""

		let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
		let result = leadingWhitespace + markdownSyntax + trimmedContent + markdownSyntax + trailingWhitespace

		return result
	}

	private func buildTableColumns(imageResolver: ((String) -> String?)?) -> [[String]] {
		var columns: [[String]] = []
		var maxColumns = 0
		let rows = collectTableRows()

		for row in rows {
			var currentRow: [String] = []
			for cell in row.children {
				let cellContent = cell.markdown(imageResolver: imageResolver).trimmingCharacters(in: .whitespacesAndNewlines)
				currentRow.append(cellContent)
			}
			maxColumns = max(maxColumns, currentRow.count)
			columns.append(currentRow)
		}

		for i in 0..<columns.count {
			while columns[i].count < maxColumns {
				columns[i].append("")
			}
		}

		return columns
	}

	private func collectTableRows() -> [DOMElement] {
		collectTableRows(from: self)
	}

	private func collectTableRows(from element: DOMElement) -> [DOMElement] {
		var rows: [DOMElement] = []
		for child in element.children {
			guard let childElement = child as? DOMElement else { continue }
			if childElement.name == "tr" {
				rows.append(childElement)
				continue
			}

			if ["thead", "tbody", "tfoot"].contains(childElement.name) {
				rows.append(contentsOf: collectTableRows(from: childElement))
			}
		}
		return rows
	}

	private func formatTable(columns: [[String]]) -> String {
		guard !columns.isEmpty else {
			return ""
		}

		var maxColumnWidths = Array(repeating: 0, count: columns.first?.count ?? 0)

		for row in columns {
			for (i, cell) in row.enumerated() {
				let lines = cell.components(separatedBy: "\n")
				let longestLine = lines.map { $0.count }.max() ?? 0
				if maxColumnWidths.count <= i {
					maxColumnWidths.append(longestLine)
				} else {
					maxColumnWidths[i] = max(maxColumnWidths[i], longestLine)
				}
			}
		}

		let separatorWidths = maxColumnWidths.map { max($0, 3) }

		var formattedTable = ""

		for (rowIndex, row) in columns.enumerated() {
			let cellLines = row.map { $0.components(separatedBy: "\n") }
			let lineCount = cellLines.map { $0.count }.max() ?? 1

			for lineIndex in 0..<lineCount {
				var formattedRow = "|"
				for (i, lines) in cellLines.enumerated() {
					let line = lineIndex < lines.count ? lines[lineIndex] : ""
					let paddedContent = line.padding(toLength: maxColumnWidths[i], withPad: " ", startingAt: 0)
					formattedRow += " \(paddedContent) |"
				}
				formattedTable += formattedRow + "\n"
			}

			if rowIndex == 0 {
				let separatorLine = separatorWidths.map { String(repeating: "-", count: $0) }.joined(separator: " | ")
				formattedTable += "| " + separatorLine + " |\n"
			}
		}

		return formattedTable
	}

	private func normalizeTableCellContent(_ content: String) -> String {
		var normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
		normalized = normalized.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
		var lines = normalized.components(separatedBy: "\n")
		lines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
		while let first = lines.first, first.isEmpty { lines.removeFirst() }
		while let last = lines.last, last.isEmpty { lines.removeLast() }
		return lines.joined(separator: "\n")
	}
}
