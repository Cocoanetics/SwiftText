import Foundation

/// Converts Markdown text to a DOCX file, backed by swift-markdown's parser.
///
/// Usage:
/// ```swift
/// try MarkdownToDocx.convert(markdownString, to: outputURL)
/// ```
public enum MarkdownToDocx {

	/// Converts Markdown text to a DOCX file at the given URL.
	/// - Parameters:
	///   - markdown: The Markdown source text.
	///   - url: Destination file URL for the `.docx` output.
	///   - pageSetup: Page configuration (paper size, margins, orientation). Defaults to A4 portrait.
	///   - baseURL: The directory standalone Markdown image paths are resolved against
	///     (typically the source `.md` file's folder). When `nil`, images fall back to
	///     alt-text placeholders.
	public static func convert(_ markdown: String, to url: URL, pageSetup: DocxPageSetup = .a4, baseURL: URL? = nil) throws {
		let build = MarkdownDocxBuilder.build(from: markdown)
		let writer = DocxWriter()
		writer.blocks = build.blocks
		writer.footnotes = build.footnotes
		writer.pageSetup = pageSetup
		writer.baseURL = baseURL
		try writer.write(to: url)
	}

	/// Parses Markdown text into an array of ``DocxWriter/Block`` elements.
	public static func parseBlocks(_ markdown: String) -> [DocxWriter.Block] {
		MarkdownDocxBuilder.blocks(from: markdown)
	}

	/// Parses inline Markdown formatting into DocxWriter runs.
	public static func parseInline(_ text: String) -> [DocxWriter.Run] {
		MarkdownDocxBuilder.runs(fromInline: text)
	}
}
