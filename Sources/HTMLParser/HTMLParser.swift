import Foundation
import CHTMLParser

// Pure-Swift OptionSet for libxml2 HTML parser options.
// Replaces the former C header HTMLParserOptions.h (NS_OPTIONS), which
// produced an OptionSet on macOS but just an Int32 on Linux.
public struct HTMLParserOptions: OptionSet, Sendable
{
	public let rawValue: Int32
	public init(rawValue: Int32) { self.rawValue = rawValue }

	public static let recover   = HTMLParserOptions(rawValue: 1 << 0)
	public static let noError   = HTMLParserOptions(rawValue: 1 << 1)
	public static let noWarning = HTMLParserOptions(rawValue: 1 << 2)
	public static let pedantic  = HTMLParserOptions(rawValue: 1 << 3)
	public static let noBlanks  = HTMLParserOptions(rawValue: 1 << 4)
	public static let noNet     = HTMLParserOptions(rawValue: 1 << 5)
	public static let compact   = HTMLParserOptions(rawValue: 1 << 6)
}

// Simple Swift error type — no ObjC runtime required
public struct HTMLParserError: Error
{
	public let message: String
}

public class HTMLParser
{
	public weak var delegate: (any HTMLParserDelegate)?

	// Input
	private var data: Data
	private var encoding: String.Encoding
	private var options: HTMLParserOptions

	// Parser State
	private var parserContext: htmlParserCtxtPtr?
	private var handler: htmlSAXHandler
	private var accumulateBuffer: String?
	private var parserError: Error?
	private var isAborting = false

	// MARK: - Init / Deinit

	public init(data: Data, encoding: String.Encoding, options: HTMLParserOptions = [.recover, .noNet, .compact, .noBlanks])
	{
		self.data = data
		self.encoding = encoding
		self.options = options
		self.handler = htmlSAXHandler()
	}

	deinit {
		if let context = parserContext {
			htmlFreeParserCtxt(context)
		}
	}

	// MARK: - Public Methods

	public var lineNumber: Int {
		return Int(xmlSAX2GetLineNumber(parserContext))
	}

	public var columnNumber: Int {
		return Int(xmlSAX2GetColumnNumber(parserContext))
	}

	public var systemID: String? {
		guard let systemID = xmlSAX2GetSystemId(parserContext) else { return nil }
		return String(cString: systemID)
	}

	public var publicID: String? {
		guard let publicID = xmlSAX2GetPublicId(parserContext) else { return nil }
		return String(cString: publicID)
	}

	public var error: Error? {
		return parserError
	}

	@discardableResult
	public func parse() -> Bool
	{
		configureHandlers()

		var charEnc: xmlCharEncoding = XML_CHAR_ENCODING_NONE
		if encoding == .utf8 {
			charEnc = XML_CHAR_ENCODING_UTF8
		}

		// htmlCreatePushParserCtxt copies the initial buffer, so the pointer
		// only needs to be valid for the duration of this call.
		data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
			parserContext = htmlCreatePushParserCtxt(
				&handler,
				Unmanaged.passUnretained(self).toOpaque(),
				ptr.baseAddress,
				Int32(ptr.count),
				nil,
				charEnc
			)
		}

		htmlCtxtUseOptions(parserContext, options.rawValue)

		let result = htmlParseDocument(parserContext)

		return result == 0 && !isAborting
	}

	public func abortParsing()
	{
		if parserContext != nil {
			xmlStopParser(parserContext)
			parserContext = nil
		}

		isAborting = true

		handler.startDocument = nil
		handler.endDocument = nil
		handler.startElement = nil
		handler.endElement = nil
		handler.characters = nil
		handler.comment = nil
		handler.error = nil
		handler.processingInstruction = nil

		if let delegate = delegate, let error = parserError {
			delegate.parser(self, parseErrorOccurred: error)
		}
	}

	// MARK: - Helpers

	private func configureHandlers() {
		handler.startDocument = { context in
			let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
			parser.delegate?.parserDidStartDocument(parser)
		}

		handler.endDocument = { context in
			let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
			parser.delegate?.parserDidEndDocument(parser)
		}

		handler.startElement = { context, name, atts in
			let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
			parser.resetAccumulateBufferAndReportCharacters()
			let elementName = String(cString: name!)
			var attributes = [String: String]()
			var i = 0
			while let att = atts?[i] {
				let key = String(cString: att)
				i += 1
				if let valueAtt = atts?[i] {
					let value = String(cString: valueAtt)
					attributes[key] = value
				}
				i += 1
			}
			parser.delegate?.parser(parser, didStartElement: elementName, attributes: attributes)
		}

		handler.endElement = { context, name in
			let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
			parser.resetAccumulateBufferAndReportCharacters()
			let elementName = String(cString: name!)
			parser.delegate?.parser(parser, didEndElement: elementName)
		}

		handler.characters = { context, chars, len in
			let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
			parser.accumulateCharacters(chars, length: len)
		}

		handler.comment = { context, chars in
			let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
			let comment = String(cString: chars!)
			parser.delegate?.parser(parser, foundComment: comment)
		}

		handler.cdataBlock = { context, value, len in
			let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
			let data = Data(bytes: value!, count: Int(len))
			parser.delegate?.parser(parser, foundCDATA: data)
		}

		handler.processingInstruction = { context, target, data in
			let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
			let targetString = String(cString: target!)
			let dataString = String(cString: data!)
			parser.delegate?.parser(parser, foundProcessingInstructionWithTarget: targetString, data: dataString)
		}

		htmlparser_set_error_handler(&handler)
	}

	private func resetAccumulateBufferAndReportCharacters() {
		if let buffer = accumulateBuffer, !buffer.isEmpty {
			delegate?.parser(self, foundCharacters: buffer)
			accumulateBuffer = nil
		}
	}

	private func accumulateCharacters(_ characters: UnsafePointer<xmlChar>?, length: Int32) {
		guard let characters = characters else { return }
		let buf = UnsafeBufferPointer(start: characters, count: Int(length))
		if let str = String(bytes: buf, encoding: .utf8) {
			if accumulateBuffer == nil {
				accumulateBuffer = str
			} else {
				accumulateBuffer?.append(str)
			}
		}
	}

	// Function to handle the formatted error message
	func handleError(_ errorMessage: String)
	{
		let error = HTMLParserError(message: errorMessage)
		self.parserError = error
		delegate?.parser(self, parseErrorOccurred: error)
	}
}

// Extern declaration called from C error bridge
@_cdecl("swift_error_handler")
func swift_error_handler(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
	guard let context = ctx, let message = msg else { return }
	let parser = Unmanaged<HTMLParser>.fromOpaque(context).takeUnretainedValue()
	parser.handleError(String(cString: message))
}
