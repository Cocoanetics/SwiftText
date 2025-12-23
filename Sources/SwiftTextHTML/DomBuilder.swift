import Foundation
import HTMLParser
import CHTMLParser

public final class DomBuilder: NSObject
{
	// MARK: - Public Properties

	public private(set) var root: DOMElement?

	// MARK: - Internal State

	private var currentElement: DOMElement?
	private var elementStack: [DOMElement] = []
	private let baseURL: URL?
	private var parseError: Error?

	// MARK: - Initialization

	public init(html: Data, baseURL: URL?) async throws
	{
		self.baseURL = baseURL
		super.init()
		try await parseHTML(html)
	}

	// MARK: - Async Parsing

	private func parseHTML(_ html: Data) async throws {
		let options: HTMLParserOptions = [.noWarning, .noError, .noNet, .recover]
		let parser = HTMLParser(data: html, encoding: .utf8, options: options)
		parser.delegate = self

		let success = parser.parse()
		if !success, root == nil {
			if let parseError = parseError ?? parser.error {
				throw DomBuilderError.parsingFailed(parseError)
			}
			throw DomBuilderError.parsingFailed(HTMLParserFallbackError.parseFailed)
		}
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

	public func parser(_ parser: HTMLParser, parseErrorOccurred parseError: NSError) {
		self.parseError = parseError
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
