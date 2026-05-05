import Markdown

/// Returns the concatenated plain-text content of an inline container, including
/// the text inside any nested formatting (`*emphasis*`, `**strong**`, `[links]`,
/// `~~strike~~`, `` `code` ``, soft/hard breaks, etc.).
///
/// Used for things like image `alt` attributes where a single string is wanted
/// regardless of how the source decorated the description. Direct-children-only
/// approaches (`children.compactMap { $0 as? Text }`) drop everything inside
/// nested inline containers and produce empty alt for inputs like
/// `![*diagram*](img.png)` or `![link [label]](...)`.
public func swiftMarkdownPlainText(of inlineContainer: Markup) -> String {
	var result = ""
	walkInlineForPlainText(inlineContainer, into: &result)
	return result
}

private func walkInlineForPlainText(_ markup: Markup, into result: inout String) {
	switch markup {
	case let text as Text:
		result += text.string
	case let code as InlineCode:
		result += code.code
	case is SoftBreak, is LineBreak:
		result += " "
	case let html as InlineHTML:
		result += html.rawHTML
	default:
		for child in markup.children {
			walkInlineForPlainText(child, into: &result)
		}
	}
}
