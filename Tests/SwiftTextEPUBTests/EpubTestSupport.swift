//  EpubTestSupport.swift
//  SwiftTextEPUBTests
//
//  Shared helpers: a fixed metadata factory for deterministic output and an
//  XML well-formedness check used across the EPUB tests.

import Foundation
// On non-Apple platforms XMLParser lives in the separate FoundationXML module.
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import SwiftTextEPUB

/// Metadata with a pinned identifier and date so output is reproducible.
func fixedMetadata(
	title: String = "Test Book",
	authors: [String] = ["A. Writer"],
	language: String = "en",
	coverImage: Data? = nil,
	coverImageFilename: String? = nil
) -> EpubMetadata {
	EpubMetadata(
		title: title,
		authors: authors,
		language: language,
		identifier: "urn:uuid:00000000-0000-0000-0000-000000000000",
		modified: Date(timeIntervalSince1970: 1_700_000_000),
		coverImage: coverImage,
		coverImageFilename: coverImageFilename)
}

/// Returns the file at `path` from a built file list, or fails the test.
func file(_ files: [EpubFile], _ path: String, sourceLocation: SourceLocation = #_sourceLocation) -> EpubFile? {
	let match = files.first { $0.path == path }
	if match == nil { Issue.record("missing container file: \(path)", sourceLocation: sourceLocation) }
	return match
}

/// The UTF-8 string content of a container file.
func string(_ file: EpubFile?) -> String {
	guard let file else { return "" }
	return String(decoding: file.data, as: UTF8.self)
}

/// Asserts a string parses as well-formed XML.
func expectWellFormedXML(_ xml: String, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
	let parser = XMLParser(data: Data(xml.utf8))
	let delegate = StrictXMLDelegate()
	parser.delegate = delegate
	let ok = parser.parse()
	if !ok || delegate.error != nil {
		let detail = delegate.error.map { "\($0)" } ?? "\(parser.parserError.map { "\($0)" } ?? "unknown")"
		Issue.record("\(label) is not well-formed XML: \(detail)", sourceLocation: sourceLocation)
	}
}

private final class StrictXMLDelegate: NSObject, XMLParserDelegate {
	var error: Error?
	func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
		error = parseError
	}
}
