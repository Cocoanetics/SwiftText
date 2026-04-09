import Foundation
import SwiftTextHTML
import Testing

@Test
func htmlParserEmitsSequentialEvents() async
{
	let html = """
	<html><body><p>Hello <b>World</b></p></body></html>
	"""

	let parser = HTMLParser(data: Data(html.utf8), encoding: .utf8)
	var events: [String] = []

	for await event in parser.parseEvents() {
		events.append(string(for: event))
	}

	#expect(events.first == "startDocument")
	#expect(events.last == "endDocument")

	let expectedSequence = [
		"startElement:p",
		"characters:Hello ",
		"startElement:b",
		"characters:World",
		"endElement:b",
		"endElement:p"
	]

	#expect(containsOrderedSubsequence(expectedSequence, in: events))
}

@Test
func delegateAdapterForwardsStreamEventsToDelegateCallbacks() async
{
	let html = """
	<html><body><p>Hello</p></body></html>
	"""

	let parser = HTMLParser(data: Data(html.utf8), encoding: .utf8)
	let recorder = DelegateRecorder()
	let adapter = HTMLParserDelegateAdapter(parser: parser, delegate: recorder)

	_ = await adapter.parse()

	#expect(recorder.events.first == "startDocument")
	#expect(recorder.events.contains("startElement:p"))
	#expect(recorder.events.contains("characters:Hello"))
	#expect(recorder.events.contains("endElement:p"))
	#expect(recorder.events.last == "endDocument")
}

private final class DelegateRecorder: HTMLParserDelegate
{
	var events: [String] = []

	func parserDidStartDocument(_ parser: HTMLParser)
	{
		events.append("startDocument")
	}

	func parserDidEndDocument(_ parser: HTMLParser)
	{
		events.append("endDocument")
	}

	func parser(_ parser: HTMLParser, didStartElement elementName: String, attributes attributeDict: [String : String])
	{
		events.append("startElement:\(elementName)")
	}

	func parser(_ parser: HTMLParser, didEndElement elementName: String)
	{
		events.append("endElement:\(elementName)")
	}

	func parser(_ parser: HTMLParser, foundCharacters string: String)
	{
		events.append("characters:\(string)")
	}
}

private func string(for event: HTMLParserEvent) -> String
{
	switch event
	{
	case .startDocument:
		return "startDocument"

	case .endDocument:
		return "endDocument"

	case let .startElement(name, _):
		return "startElement:\(name)"

	case let .endElement(name):
		return "endElement:\(name)"

	case let .characters(string):
		return "characters:\(string)"

	case let .comment(comment):
		return "comment:\(comment)"

	case let .cdata(data):
		return "cdata:\(data.count)"

	case let .processingInstruction(target, data):
		return "processingInstruction:\(target):\(data)"

	case let .parseError(error):
		return "parseError:\(error.message)"
	}
}

private func containsOrderedSubsequence(_ subsequence: [String], in events: [String]) -> Bool
{
	var searchStart = events.startIndex

	for needle in subsequence {
		guard let index = events[searchStart...].firstIndex(of: needle) else {
			return false
		}

		searchStart = events.index(after: index)
	}

	return true
}
