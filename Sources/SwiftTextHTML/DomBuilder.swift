import Foundation
import HTMLParser

public final class DomBuilder
{
	// MARK: - Public Properties

	public private(set) var root: DOMElement?

	// MARK: - Initialization

	private let baseURL: URL?
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

		let state = DOMBuilderState(baseURL: baseURL)

		for await event in parser.parseEvents() {
			await state.apply(event)
		}

		root = await state.rootElement()

		if root == nil {
			if let parseError = await state.recordedParseError() ?? (parser.error as? HTMLParserError) {
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

// MARK: - Errors

public enum DomBuilderError: Error
{
	case parsingFailed(Error)
}

private enum HTMLParserFallbackError: Error
{
	case parseFailed
}

private actor DOMBuilderState
{
	private let baseURL: URL?
	private let root: DOMElement
	private var currentElement: DOMElement
	private var elementStack: [DOMElement] = []
	private var parseError: HTMLParserError?

	init(baseURL: URL?)
	{
		self.baseURL = baseURL

		let documentRoot = DOMElement(name: "document", attributes: [:])
		documentRoot.isTransparentWrapper = true
		self.root = documentRoot
		self.currentElement = documentRoot
	}

	func apply(_ event: HTMLParserEvent)
	{
		switch event
		{
		case .startDocument, .endDocument, .comment, .cdata, .processingInstruction:
			return

		case let .startElement(name, attributes):
			handleStartElement(name, attributes: attributes)

		case let .endElement(name):
			handleEndElement(name)

		case let .characters(string):
			handleCharacters(string)

		case let .parseError(error):
			parseError = error
		}
	}

	func rootElement() -> DOMElement
	{
		root
	}

	func recordedParseError() -> HTMLParserError?
	{
		parseError
	}
}

private extension DOMBuilderState
{
	func handleStartElement(_ elementName: String, attributes: [String: String])
	{
		var attributes = attributes

		if elementName == "a",
		   let href = attributes["href"]
		{
			if href.hasPrefix("javascript:") {
				attributes["href"] = nil
			} else if let url = URL(string: href, relativeTo: baseURL) {
				attributes["href"] = url.absoluteString
			}
		}

		let element = DOMElement(name: elementName, attributes: attributes)
		element.isTransparentWrapper = isTransparentWrapperTag(elementName, attributes: attributes)

		currentElement.addChild(element)
		elementStack.append(currentElement)
		currentElement = element
	}

	func handleCharacters(_ string: String)
	{
		let isWhitespace = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

		if ["pre", "code"].contains(currentElement.name) {
			currentElement.addChild(DOMText(text: string, preserveWhitespace: true))
			return
		}

		if isWhitespace,
		   ["ul", "ol", "body", "div", "blockquote", "tr", "table", "document"].contains(currentElement.name)
		{
			return
		}

		currentElement.addChild(DOMText(text: string, preserveWhitespace: false))
	}

	func handleEndElement(_ _: String)
	{
		guard !elementStack.isEmpty else {
			currentElement = root
			return
		}

		currentElement = elementStack.removeLast()
	}

	func isTransparentWrapperTag(_ name: String, attributes: [String: String]) -> Bool
	{
		let tag = name.lowercased()

		guard ["div", "p", "span", "font", "center"].contains(tag) else {
			return false
		}

		let semanticKeys: Set<String> = ["id", "href", "src", "name", "role"]
		for (key, _) in attributes {
			let lowercasedKey = key.lowercased()
			if semanticKeys.contains(lowercasedKey) { return false }
			if lowercasedKey.hasPrefix("aria-") { return false }
			if lowercasedKey.hasPrefix("data-") { return false }
			if ["style", "class", "lang"].contains(lowercasedKey) { continue }
			return false
		}

		return true
	}
}
