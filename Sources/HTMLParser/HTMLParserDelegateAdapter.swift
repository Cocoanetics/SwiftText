import Foundation

public final class HTMLParserDelegateAdapter: @unchecked Sendable
{
    public let parser: HTMLParser
    public weak var delegate: (any HTMLParserDelegate)?
    
    public init(parser: HTMLParser, delegate: (any HTMLParserDelegate)?)
    {
        self.parser = parser
        self.delegate = delegate
    }
    
    @discardableResult
    public func parse() -> Bool
    {
        let runContext = HTMLParserRunContext { [weak self] event in
            guard let self else {
                return
            }
            
            self.apply(event)
        }
        
        return parser.parseSynchronously(emittingWith: runContext)
    }
    
    @discardableResult
    public func parse() async -> Bool
    {
        for await event in parser.parseEvents() {
            apply(event)
        }
        
        return parser.lastParseSucceeded
    }
    
    public func abortParsing()
    {
        parser.abortParsing()
    }
    
    public var error: Error? {
        parser.error
    }
    
    func apply(_ event: HTMLParserEvent)
    {
        guard let delegate else {
            return
        }
        
        switch event
        {
            case .startDocument:
                delegate.parserDidStartDocument(parser)
                
            case .endDocument:
                delegate.parserDidEndDocument(parser)
                
            case let .startElement(name, attributes):
                delegate.parser(parser, didStartElement: name, attributes: attributes)
                
            case let .endElement(name):
                delegate.parser(parser, didEndElement: name)
                
            case let .characters(string):
                delegate.parser(parser, foundCharacters: string)
                
            case let .comment(comment):
                delegate.parser(parser, foundComment: comment)
                
            case let .cdata(data):
                delegate.parser(parser, foundCDATA: data)
                
            case let .processingInstruction(target, data):
                delegate.parser(parser, foundProcessingInstructionWithTarget: target, data: data)
                
            case let .parseError(error):
                delegate.parser(parser, parseErrorOccurred: error)
        }
    }
}
