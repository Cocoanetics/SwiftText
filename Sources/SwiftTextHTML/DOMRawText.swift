import Foundation

/// The raw, unparsed source of a "raw text element": the CSS inside `<style>`
/// or the program inside `<script>`.
///
/// It is a node in the tree like any child, but a *distinct* type from
/// ``DOMText`` — so it is never mistaken for, or collected as, document text.
/// `text()` and `markdown()` yield nothing. It is an implementation detail of
/// the DOM; read a document's CSS via ``DOMElement/styleSheets()``.
final class DOMRawText: DOMNode, @unchecked Sendable {
	let name = "#raw-text"

	/// The verbatim source (CSS or script), preserved exactly — no whitespace
	/// collapsing or entity decoding.
	private(set) var content: String

	init(content: String) {
		self.content = content
	}

	/// Coalesce an adjacent chunk the parser delivers for the same element.
	func append(_ string: String) {
		content += string
	}

	func markdown() -> String { "" }
	func markdown(imageResolver: ((String) -> String?)?) -> String { "" }
	func text() -> String { "" }
}
