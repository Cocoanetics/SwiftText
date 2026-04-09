import Foundation

public enum HTMLParserEvent: Sendable, Equatable
{
	case startDocument
	case endDocument
	case startElement(name: String, attributes: [String: String])
	case endElement(name: String)
	case characters(String)
	case comment(String)
	case cdata(Data)
	case processingInstruction(target: String, data: String)
	case parseError(HTMLParserError)
}
