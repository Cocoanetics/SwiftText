// List-item continuation content: further paragraphs, quotes, code blocks and the
// like inside a list item, indented under the item's text.
extension DocxWriter {

	/// The text indent (twips) of a list item at `level`, matching the numbering
	/// definitions' `w:left`.
	static func listTextIndent(level: Int) -> Int {
		(level + 1) * 720
	}

	/// The left indent (twips) of content `quoteDepth` quote levels deep, shifted under
	/// a list item's text when it continues one.
	func leftIndent(quoteDepth: Int) -> Int {
		listTextIndent + quoteDepth * Self.quoteIndent
	}

	/// A list item's further content, indented under its text. The list's numbering
	/// runs on past it, so the next item continues the same list.
	func listContinuationXML(_ blocks: [Block], level: Int, quoteDepth: Int, above: DocxEdge?, below: DocxEdge?) -> String {
		let savedIndent = listTextIndent
		let savedListType = lastListType
		let savedNumId = currentNumId
		listTextIndent = leftIndent(quoteDepth: quoteDepth) + Self.listTextIndent(level: level)
		lastListType = nil
		let xml = renderBlocks(blocks, quoteDepth: 0, above: above, below: below)
		listTextIndent = savedIndent
		lastListType = savedListType
		currentNumId = savedNumId
		return xml
	}
}
