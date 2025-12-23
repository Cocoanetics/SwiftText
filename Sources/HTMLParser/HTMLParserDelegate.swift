import Foundation

@objc(DTHTMLParserDelegate)
public protocol HTMLParserDelegate: AnyObject
{
	@objc optional func parserDidStartDocument(_ parser: HTMLParser)
	@objc optional func parserDidEndDocument(_ parser: HTMLParser)
	@objc optional func parser(_ parser: HTMLParser, didStartElement elementName: String, attributes attributeDict: [String: String])
	@objc optional func parser(_ parser: HTMLParser, didEndElement elementName: String)
	@objc optional func parser(_ parser: HTMLParser, foundCharacters string: String)
	@objc optional func parser(_ parser: HTMLParser, foundComment comment: String)
	@objc optional func parser(_ parser: HTMLParser, foundCDATA CDATABlock: Data)
	@objc optional func parser(_ parser: HTMLParser, foundProcessingInstructionWithTarget target: String, data: String)
	@objc optional func parser(_ parser: HTMLParser, parseErrorOccurred parseError: NSError)
}

