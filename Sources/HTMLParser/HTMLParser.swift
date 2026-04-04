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

public struct HTMLParserError: Error
{
	public let message: String
}

public class HTMLParser
{
	public weak var delegate: (any HTMLParserDelegate)?

	private var data: Data
	private var encoding: String.Encoding
	private var options: HTMLParserOptions

	private var parserContext: htmlparser_parser_t?
	private var accumulateBuffer: String?
	private var parserError: Error?
	private var isAborting = false

	public init(data: Data, encoding: String.Encoding, options: HTMLParserOptions = [.recover, .noNet, .compact, .noBlanks])
	{
		self.data = data
		self.encoding = encoding
		self.options = options
	}

	deinit {
		if let context = parserContext {
			htmlparser_free(context)
		}
	}

	public var lineNumber: Int {
		Int(htmlparser_line_number(parserContext))
	}

	public var columnNumber: Int {
		Int(htmlparser_column_number(parserContext))
	}

	public var systemID: String? {
		guard let systemID = htmlparser_system_id(parserContext) else { return nil }
		return String(cString: systemID)
	}

	public var publicID: String? {
		guard let publicID = htmlparser_public_id(parserContext) else { return nil }
		return String(cString: publicID)
	}

	public var error: Error? {
		parserError
	}

	@discardableResult
	public func parse() -> Bool
	{
		var charEnc = Int32(HTMLPARSER_ENCODING_NONE)
		if encoding == .utf8 {
			charEnc = Int32(HTMLPARSER_ENCODING_UTF8)
		}

		let callbacks = makeCallbacks()
		data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
			parserContext = htmlparser_create(
				ptr.baseAddress,
				Int32(ptr.count),
				Unmanaged.passUnretained(self).toOpaque(),
				callbacks,
				charEnc
			)
		}

		let result = htmlparser_parse(parserContext, options.rawValue)
		return result == 0 && !isAborting
	}

	public func abortParsing()
	{
		if let context = parserContext {
			htmlparser_stop(context)
			htmlparser_free(context)
			parserContext = nil
		}

		isAborting = true

		if let delegate, let error = parserError {
			delegate.parser(self, parseErrorOccurred: error)
		}
	}

	private func makeCallbacks() -> htmlparser_sax_callbacks
	{
		htmlparser_sax_callbacks(
			startDocument: { context in
				let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
				parser.delegate?.parserDidStartDocument(parser)
			},
			endDocument: { context in
				let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
				parser.delegate?.parserDidEndDocument(parser)
			},
			startElement: { context, name, atts in
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
			},
			endElement: { context, name in
				let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
				parser.resetAccumulateBufferAndReportCharacters()
				let elementName = String(cString: name!)
				parser.delegate?.parser(parser, didEndElement: elementName)
			},
			characters: { context, chars, len in
				let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
				parser.accumulateCharacters(chars, length: len)
			},
			comment: { context, chars in
				let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
				let comment = String(cString: chars!)
				parser.delegate?.parser(parser, foundComment: comment)
			},
			cdataBlock: { context, value, len in
				let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
				let data = Data(bytes: value!, count: Int(len))
				parser.delegate?.parser(parser, foundCDATA: data)
			},
			processingInstruction: { context, target, data in
				let parser = Unmanaged<HTMLParser>.fromOpaque(context!).takeUnretainedValue()
				let targetString = String(cString: target!)
				let dataString = String(cString: data!)
				parser.delegate?.parser(parser, foundProcessingInstructionWithTarget: targetString, data: dataString)
			},
			error: { context, message in
				guard let context, let message else { return }
				let parser = Unmanaged<HTMLParser>.fromOpaque(context).takeUnretainedValue()
				parser.handleError(String(cString: message))
			}
		)
	}

	private func resetAccumulateBufferAndReportCharacters()
	{
		if let buffer = accumulateBuffer, !buffer.isEmpty {
			delegate?.parser(self, foundCharacters: buffer)
			accumulateBuffer = nil
		}
	}

	private func accumulateCharacters(_ characters: UnsafePointer<UInt8>?, length: Int32)
	{
		guard let characters else { return }
		let buf = UnsafeBufferPointer(start: characters, count: Int(length))
		if let str = String(bytes: buf, encoding: .utf8) {
			if accumulateBuffer == nil {
				accumulateBuffer = str
			} else {
				accumulateBuffer?.append(str)
			}
		}
	}

	func handleError(_ errorMessage: String)
	{
		let error = HTMLParserError(message: errorMessage)
		parserError = error
		delegate?.parser(self, parseErrorOccurred: error)
	}
}
