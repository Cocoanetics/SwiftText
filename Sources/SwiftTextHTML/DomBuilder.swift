import Foundation
import HTMLParser

public final class DomBuilder
{
	// MARK: - Public Properties

	public private(set) var root: DOMElement?

	// MARK: - Internal State

	private var currentElement: DOMElement?
	private var elementStack: [DOMElement] = []
	private let baseURL: URL?
	private var parseError: Error?

	// MARK: - Initialization

	private let encoding: String.Encoding?

	public init(html: Data, baseURL: URL?, encoding: String.Encoding? = nil) async throws
	{
		self.baseURL = baseURL
		self.encoding = encoding
		try await parseHTML(html)
	}

	// MARK: - Async Parsing

	private func parseHTML(_ html: Data) async throws {
		let options: HTMLParserOptions = [.noWarning, .noError, .noNet, .recover]

		// If the caller provides an explicit encoding hint, honor it and parse the original bytes.
		// Otherwise we normalize common bogus legacy charset declarations when the bytes are valid UTF-8.
		let dataToParse: Data
		let encodingToUse: String.Encoding
		if let encoding {
			dataToParse = html
			encodingToUse = encoding
		} else {
			dataToParse = normalizeCharsetIfNeeded(html)
			encodingToUse = .utf8
		}

		let parser = HTMLParser(data: dataToParse, encoding: encodingToUse, options: options)
		parser.delegate = self

		let success = parser.parse()
		if !success, root == nil {
			if let parseError = parseError ?? parser.error {
				throw DomBuilderError.parsingFailed(parseError)
			}
			throw DomBuilderError.parsingFailed(HTMLParserFallbackError.parseFailed)
		}
	}

	/// Some HTML (notably email bodies) declares `charset=iso-8859-1` (or similar)
	/// while the actual bytes are valid UTF-8. libxml/HTMLParser will honor the declared
	/// charset and produce mojibake (e.g. "fÃ¼r" instead of "für").
	///
	/// If the HTML bytes are valid UTF-8, we rewrite common legacy charset declarations
	/// to `utf-8` before parsing so that entities/text decode correctly.
	private func normalizeCharsetIfNeeded(_ html: Data) -> Data {
		guard let utf8 = String(data: html, encoding: .utf8) else {
			return html
		}

		// Only rewrite if the document explicitly claims a legacy single-byte charset.
		let pattern = "(?i)charset\\s*=\\s*(iso-8859-1|windows-1252|latin1)"
		guard utf8.range(of: pattern, options: .regularExpression) != nil else {
			return html
		}

		let rewritten = utf8.replacingOccurrences(
			of: pattern,
			with: "charset=utf-8",
			options: .regularExpression
		)
		return Data(rewritten.utf8)
	}
}

// MARK: - HTMLParserDelegate

extension DomBuilder: HTMLParserDelegate
{
	public func parser(_ parser: HTMLParser, didStartElement elementName: String, attributes attributeDict: [String: String]) {
		var attributeDict = attributeDict

		if elementName == "a"
		{
			if let href = attributeDict["href"]
			{
				if href.hasPrefix("javascript:")
				{
					attributeDict["href"] = nil
				}
				else if let url = URL(string: href, relativeTo: baseURL)
				{
					attributeDict["href"] = url.absoluteString
				}
			}
		}

		let element = DOMElement(name: elementName, attributes: attributeDict)
		element.isTransparentWrapper = isTransparentWrapperTag(elementName, attributes: attributeDict)

		if let current = currentElement
		{
			current.addChild(element)
			elementStack.append(current)
		}
		else
		{
			root = element
		}

		currentElement = element
	}

	public func parser(_ parser: HTMLParser, foundCharacters string: String) {
		let isWhiteSpace = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

		if (["pre", "code"].contains(currentElement?.name ?? ""))
		{
			let textNode = DOMText(text: string, preserveWhitespace: true)
			currentElement?.addChild(textNode)
		}
		else
		{
			if isWhiteSpace,
			   let currentElement,
			   ["ul", "ol", "body", "div", "blockquote", "tr", "table"].contains(currentElement.name)
			{
				return
			}
			else
			{
				let textNode = DOMText(text: string, preserveWhitespace: false)
				currentElement?.addChild(textNode)
			}
		}
	}

	public func parser(_ parser: HTMLParser, didEndElement elementName: String) {
		guard !elementStack.isEmpty else
		{
			currentElement = nil
			return
		}

		currentElement = elementStack.removeLast()
	}

	public func parser(_ parser: HTMLParser, parseErrorOccurred parseError: Error) {
		self.parseError = parseError
	}
}

// MARK: - Transparent wrapper tagging

private extension DomBuilder {
	func isTransparentWrapperTag(_ name: String, attributes: [String: String]) -> Bool {
		let tag = name.lowercased()

		// Conservative set: common email/layout wrappers.
		guard ["div", "p", "span", "font", "center"].contains(tag) else {
			return false
		}

		// If it carries semantics, do not treat as transparent.
		let semanticKeys: Set<String> = ["id", "href", "src", "name", "role"]
		for (k, _) in attributes {
			let key = k.lowercased()
			if semanticKeys.contains(key) { return false }
			if key.hasPrefix("aria-") { return false }
			if key.hasPrefix("data-") { return false }
			// Allow purely presentational attributes.
			if ["style", "class", "lang"].contains(key) { continue }
			// Unknown attribute => be conservative.
			return false
		}

		return true
	}
}

// MARK: - Errors

public enum DomBuilderError: Error
{
	case parsingFailed(Error)
}

private enum HTMLParserFallbackError: Error
{
	case parseFailed
}
