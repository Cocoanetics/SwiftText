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

public struct HTMLParserError: Error, Sendable, Equatable
{
	public let message: String
}

public class HTMLParser: @unchecked Sendable
{
	private let data: Data
	private let encoding: String.Encoding
	private let options: HTMLParserOptions
	private let runContextLock = NSLock()
	private var activeRunContext: HTMLParserRunContext?
	private var parserError: HTMLParserError?
	var lastParseSucceeded = false

	public init(data: Data, encoding: String.Encoding, options: HTMLParserOptions = [.recover, .noNet, .compact, .noBlanks])
	{
		self.data = data
		self.encoding = encoding
		self.options = options
	}

	public var lineNumber: Int {
		guard let context = currentParserContext else {
			return 0
		}

		return Int(htmlparser_line_number(context))
	}

	public var columnNumber: Int {
		guard let context = currentParserContext else {
			return 0
		}

		return Int(htmlparser_column_number(context))
	}

	public var systemID: String? {
		guard let context = currentParserContext,
			  let systemID = htmlparser_system_id(context)
		else {
			return nil
		}

		return String(cString: systemID)
	}

	public var publicID: String? {
		guard let context = currentParserContext,
			  let publicID = htmlparser_public_id(context)
		else {
			return nil
		}

		return String(cString: publicID)
	}

	public var error: Error? {
		parserError
	}

	public func parseEvents() -> AsyncStream<HTMLParserEvent>
	{
		AsyncStream(bufferingPolicy: .unbounded) { continuation in
			let task = Task { [weak self] in
				guard let self else {
					continuation.finish()
					return
				}

				let runContext = HTMLParserRunContext { event in
					continuation.yield(event)
				}

				_ = self.parseSynchronously(emittingWith: runContext)
				continuation.finish()
			}

			continuation.onTermination = { [weak self] _ in
				self?.abortParsing()
				task.cancel()
			}
		}
	}

	public func abortParsing()
	{
		runContextLock.lock()
		let activeRunContext = activeRunContext
		runContextLock.unlock()

		activeRunContext?.abort()
	}

	private func makeCallbacks() -> htmlparser_sax_callbacks
	{
		htmlparser_sax_callbacks(
			startDocument: { context in
				guard let context else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.emit(.startDocument)
			},
			endDocument: { context in
				guard let context else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.flushAccumulatedCharacters()
				runContext.emit(.endDocument)
			},
			startElement: { context, name, atts in
				guard let context, let name else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.flushAccumulatedCharacters()
				let elementName = String(cString: name)
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
				runContext.emit(.startElement(name: elementName, attributes: attributes))
			},
			endElement: { context, name in
				guard let context, let name else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.flushAccumulatedCharacters()
				let elementName = String(cString: name)
				runContext.emit(.endElement(name: elementName))
			},
			characters: { context, chars, len in
				guard let context else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.accumulateCharacters(chars, length: len)
			},
			comment: { context, chars in
				guard let context, let chars else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.flushAccumulatedCharacters()
				let comment = String(cString: chars)
				runContext.emit(.comment(comment))
			},
			cdataBlock: { context, value, len in
				guard let context, let value else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.flushAccumulatedCharacters()
				let data = Data(bytes: value, count: Int(len))
				runContext.emit(.cdata(data))
			},
			processingInstruction: { context, target, data in
				guard let context, let target, let data else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.flushAccumulatedCharacters()
				let targetString = String(cString: target)
				let dataString = String(cString: data)
				runContext.emit(.processingInstruction(target: targetString, data: dataString))
			},
			error: { context, message in
				guard let context, let message else { return }
				let runContext = Unmanaged<HTMLParserRunContext>.fromOpaque(context).takeUnretainedValue()
				guard !runContext.abortIfCancelled() else { return }

				runContext.flushAccumulatedCharacters()
				runContext.record(error: HTMLParserError(message: String(cString: message)))
			}
		)
	}

	private var currentParserContext: htmlparser_parser_t?
	{
		runContextLock.lock()
		let context = activeRunContext?.parserContext
		runContextLock.unlock()
		return context
	}

	@discardableResult
	func parseSynchronously(emittingWith runContext: HTMLParserRunContext) -> Bool
	{
		parserError = nil
		lastParseSucceeded = false

		guard !Task.isCancelled else {
			runContext.abort()
			return false
		}

		var charEnc = Int32(HTMLPARSER_ENCODING_NONE)
		if encoding == .utf8 {
			charEnc = Int32(HTMLPARSER_ENCODING_UTF8)
		}

		let callbacks = makeCallbacks()
		runContextLock.lock()
		activeRunContext = runContext
		runContextLock.unlock()

		defer {
			if let context = runContext.parserContext {
				htmlparser_free(context)
				runContext.parserContext = nil
			}

			runContextLock.lock()
			if activeRunContext === runContext {
				activeRunContext = nil
			}
			runContextLock.unlock()

			parserError = runContext.parserError
		}

		data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
			runContext.parserContext = htmlparser_create(
				ptr.baseAddress,
				Int32(ptr.count),
				Unmanaged.passUnretained(runContext).toOpaque(),
				callbacks,
				charEnc
			)
		}

		guard runContext.parserContext != nil else {
			runContext.record(error: HTMLParserError(message: "Failed to create HTML parser context"))
			return false
		}

		let result = htmlparser_parse(runContext.parserContext, options.rawValue)
		runContext.flushAccumulatedCharacters()

		if result != 0, runContext.parserError == nil, !runContext.isAborting {
			runContext.record(error: HTMLParserError(message: "HTML parsing failed"))
		}

		let success = result == 0 && !runContext.isAborting && runContext.parserError == nil
		lastParseSucceeded = success
		return success
	}
}

final class HTMLParserRunContext
{
	private let emitEvent: (HTMLParserEvent) -> Void

	var parserContext: htmlparser_parser_t?
	var parserError: HTMLParserError?
	var isAborting = false
	private var accumulateBuffer: String?

	init(emitEvent: @escaping (HTMLParserEvent) -> Void)
	{
		self.emitEvent = emitEvent
	}

	func abort()
	{
		guard !isAborting else {
			return
		}

		isAborting = true

		if let parserContext {
			htmlparser_stop(parserContext)
		}
	}

	func abortIfCancelled() -> Bool
	{
		guard Task.isCancelled else {
			return false
		}

		abort()
		return true
	}

	func emit(_ event: HTMLParserEvent)
	{
		emitEvent(event)
	}

	func flushAccumulatedCharacters()
	{
		if let accumulateBuffer, !accumulateBuffer.isEmpty {
			emit(.characters(accumulateBuffer))
			self.accumulateBuffer = nil
		}
	}

	func accumulateCharacters(_ characters: UnsafePointer<UInt8>?, length: Int32)
	{
		guard let characters else {
			return
		}

		let buffer = UnsafeBufferPointer(start: characters, count: Int(length))
		guard let string = String(bytes: buffer, encoding: .utf8) else {
			return
		}

		if accumulateBuffer == nil {
			accumulateBuffer = string
		} else {
			accumulateBuffer?.append(string)
		}
	}

	func record(error: HTMLParserError)
	{
		guard parserError == nil else {
			return
		}

		parserError = error
		emit(.parseError(error))
	}
}
