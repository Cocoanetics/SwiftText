//  MarkdownToEpub.swift
//  SwiftTextEPUB
//
//  The public entry point: turn a Markdown manuscript (plus metadata and an
//  optional cover) into an EPUB 3 file. Chapters are split at a configurable
//  heading level and each becomes its own XHTML content document, wired into the
//  OPF manifest/spine and the nav/NCX tables of contents.

import Foundation
import Markdown

/// Options controlling EPUB generation.
public struct EpubOptions: Sendable {
	/// Heading level (1–6) at which a new chapter file begins. Content before the
	/// first heading of this level becomes a front-matter section. Default: 1.
	public var chapterLevel: Int
	/// CSS appended after the bundled stylesheet (so its rules win), shared by
	/// every content document. `nil` uses only the default stylesheet.
	public var userCSS: String?

	public init(chapterLevel: Int = 1, userCSS: String? = nil) {
		self.chapterLevel = chapterLevel
		self.userCSS = userCSS
	}
}

/// Converts Markdown text to an EPUB 3 publication.
///
/// Usage:
/// ```swift
/// let metadata = EpubMetadata(title: "The Shattered Skies", authors: ["Elise Kummer"])
/// try MarkdownToEpub.convert(markdown, to: outputURL, metadata: metadata,
///                            options: EpubOptions(chapterLevel: 2))
/// ```
public enum MarkdownToEpub {

	/// Writes an EPUB for `markdown` to `url`.
	public static func convert(_ markdown: String, to url: URL, metadata: EpubMetadata, options: EpubOptions = EpubOptions()) throws {
		let files = makeFiles(markdown, metadata: metadata, options: options)
		try EpubArchiveWriter.write(files, to: url, modificationDate: metadata.modified)
	}

	/// Builds an EPUB for `markdown` and returns its bytes.
	public static func makeData(_ markdown: String, metadata: EpubMetadata, options: EpubOptions = EpubOptions()) throws -> Data {
		let files = makeFiles(markdown, metadata: metadata, options: options)
		return try EpubArchiveWriter.makeData(files, modificationDate: metadata.modified)
	}

	/// Builds the ordered container file list (pre-zip). Exposed internally so
	/// tests can assert on individual documents without unzipping.
	static func makeFiles(_ markdown: String, metadata: EpubMetadata, options: EpubOptions) -> [EpubFile] {
		// Parse with smart typography disabled to match the HTML renderer: the
		// source already carries real typographic characters, so re-substituting
		// would double-transform them.
		let document = Document(parsing: markdown, options: [.disableSmartOpts])
		var chapters = ChapterSplitter.split(document: document, chapterLevel: options.chapterLevel, titleFallback: metadata.title)

		// A table of contents needs at least one entry. If the manuscript has no
		// heading at the split level, present its whole content as a single
		// titled chapter (an empty document still yields a one-chapter shell).
		if !chapters.contains(where: { !$0.isFrontmatter }) {
			if chapters.isEmpty {
				chapters = [EpubChapter(id: "ch001", title: metadata.title, bodyXHTML: "", isFrontmatter: false)]
			} else {
				chapters = chapters.map {
					EpubChapter(id: $0.id, title: metadata.title, bodyXHTML: $0.bodyXHTML, isFrontmatter: false)
				}
			}
		}

		let cover = metadata.coverImage.flatMap { CoverImage(data: $0, originalFilename: metadata.coverImageFilename) }
		return EpubPackageBuilder.build(metadata: metadata, chapters: chapters, cover: cover, userCSS: options.userCSS)
	}
}
