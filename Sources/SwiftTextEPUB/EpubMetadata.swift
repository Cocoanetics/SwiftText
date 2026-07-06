//  EpubMetadata.swift
//  SwiftTextEPUB
//
//  The Dublin Core / EPUB package metadata that drives the OPF and nav
//  documents: title, author(s), language, a unique identifier, the last-modified
//  timestamp, and an optional cover image.

import Foundation

/// Metadata for an EPUB publication.
///
/// Mirrors the subset of Dublin Core / EPUB `<metadata>` a single-author book
/// needs. `identifier` and `modified` default to a fresh random UUID and the
/// current time; pass explicit values for a reproducible build (e.g. in tests).
public struct EpubMetadata: Sendable {
	/// The book title (`dc:title`).
	public var title: String
	/// The author(s), in reading order (`dc:creator`, role `aut`).
	public var authors: [String]
	/// BCP-47 language tag (`dc:language`), e.g. `"en"`.
	public var language: String
	/// The publication's unique identifier (`dc:identifier`). A `urn:uuid:…`
	/// string by default; any stable, globally unique URN/URI is valid.
	public var identifier: String
	/// The last-modified instant (`dcterms:modified`), serialized as UTC.
	public var modified: Date
	/// The raw bytes of the cover image, if any.
	public var coverImage: Data?
	/// The cover image's original filename, used only to pick an extension when
	/// the format can't be sniffed from the bytes. Optional.
	public var coverImageFilename: String?

	public init(
		title: String,
		authors: [String] = [],
		language: String = "en",
		identifier: String? = nil,
		modified: Date? = nil,
		coverImage: Data? = nil,
		coverImageFilename: String? = nil
	) {
		self.title = title
		self.authors = authors
		self.language = language.isEmpty ? "en" : language
		self.identifier = identifier ?? "urn:uuid:\(UUID().uuidString.lowercased())"
		self.modified = modified ?? Date()
		self.coverImage = coverImage
		self.coverImageFilename = coverImageFilename
	}

	/// `dcterms:modified` requires a UTC timestamp with no fractional seconds
	/// (`CCYY-MM-DDThh:mm:ssZ`), per the EPUB spec.
	var modifiedUTCString: String {
		let formatter = ISO8601DateFormatter()
		formatter.timeZone = TimeZone(identifier: "UTC")
		formatter.formatOptions = [.withInternetDateTime]
		return formatter.string(from: modified)
	}
}
