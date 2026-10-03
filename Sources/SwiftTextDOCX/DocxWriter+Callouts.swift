import SwiftTextMarkdown

// Alert boxes (`> [!NOTE]`), horizontal rules and block quotes: the paragraphs that
// space themselves like the CSS against their neighbours (see `DocxBoxLayout` and
// Docs/DOCX_WRITING.md), and the paragraph styles they use.
extension DocxWriter {

	// MARK: - Neighbour-Aware Block Rendering

	/// Renders a run of blocks, telling each one what is above and below it (alert boxes
	/// and rules space themselves against their neighbours, like CSS margins). `above`
	/// and `below` are the neighbours of the whole run.
	func renderBlocks(_ blocks: [Block], quoteDepth: Int, above: DocxEdge?, below: DocxEdge?) -> String {
		var xml = ""
		for (index, block) in blocks.enumerated() {
			let previous = index > 0 ? bottomEdge(of: blocks[index - 1]) : above
			let next = index + 1 < blocks.count ? topEdge(of: blocks[index + 1]) : below
			xml += renderBlock(block, quoteDepth: quoteDepth, above: previous, below: next)
			if case .blockquote = block, index + 1 < blocks.count, case .blockquote = blocks[index + 1] {
				// Two quotes in a row would draw (and read back) as one.
				xml += spacerParagraph()
			}
		}
		return xml
	}

	/// What a block shows the block above it: its first paragraph's space before, or
	/// that it is a box or rule.
	func topEdge(of block: Block) -> DocxEdge {
		switch block {
		case .alert: return .box
		case .horizontalRule: return .rule
		case .heading(let level, _): return .spacing(Self.headingSpaceBefore(level: max(1, min(level, 6))))
		case .blockquote(let inner): return inner.first.map(topEdge(of:)) ?? .spacing(0)
		case .paragraph, .listItem, .codeBlock, .table, .image: return .spacing(0)
		}
	}

	/// What a block shows the block below it: its last paragraph's space after, or that
	/// it is a box or rule.
	func bottomEdge(of block: Block) -> DocxEdge {
		switch block {
		case .alert(_, let title, let inner):
			if case .block(let last)? = calloutPieces(title: title, blocks: inner).last { return bottomEdge(of: last) }
			return .box
		case .horizontalRule: return .rule
		case .heading: return .spacing(Self.headingSpaceAfter)
		case .blockquote(let inner): return inner.last.map(bottomEdge(of:)) ?? .spacing(0)
		case .paragraph, .listItem, .image: return .spacing(Self.paragraphSpaceAfter)
		case .codeBlock, .table: return .spacing(0)
		}
	}

	/// A rule: an empty paragraph in the "Horizontal Rule" style (a bottom border under
	/// a 1pt line), spaced by the CSS `hr` margins against its neighbours.
	func horizontalRuleParagraph(quoteDepth: Int, above: DocxEdge?, below: DocxEdge?) -> String {
		usesRuleStyle = true
		let layout = boxLayout
		var pPr = "<w:pStyle w:val=\"\(DocxStyleID.rule)\"/>"
		pPr += "<w:spacing w:before=\"\(layout.ruleSpaceBefore(above: above))\" w:after=\"\(layout.ruleSpaceAfter(below: below))\"/>"
		if quoteDepth > 0 {
			pPr += "<w:ind w:left=\"\(quoteDepth * Self.quoteIndent)\"/>"
		}
		return "<w:p><w:pPr>\(pPr)</w:pPr></w:p>\n"
	}

	// MARK: - Alert Boxes

	/// A paragraph of an alert box.
	struct CalloutParagraph {
		enum Role {
			case title
			case body
			case listItem(ordered: Bool, level: Int)
		}
		var role: Role
		var runs: [Run]

		var isListItem: Bool {
			if case .listItem = role { return true }
			return false
		}
	}

	/// An alert's content, as Word can draw it: runs of paragraphs that form one box, and
	/// the tables, images and rules that can't sit inside a paragraph box and split it.
	enum CalloutPiece {
		case box([CalloutParagraph])
		case block(Block)
	}

	/// Flattens an alert into box paragraphs: headings become bold lines, quotes italic
	/// ones and code blocks monospace ones, since a second frame or indent would break
	/// the box apart (as in the Pages writer). Nested list levels keep their numbering
	/// level but share the box's indent.
	func calloutPieces(title: String, blocks: [Block]) -> [CalloutPiece] {
		var pieces = [CalloutPiece]()
		var current = [CalloutParagraph(role: .title, runs: [Run(text: title)])]
		func styled(_ runs: [Run], bold: Bool = false, italic: Bool) -> [Run] {
			runs.map { run in
				var run = run
				run.bold = run.bold || bold
				run.italic = run.italic || italic
				return run
			}
		}
		func flatten(_ blocks: [Block], italic: Bool) {
			for block in blocks {
				switch block {
				case .paragraph(let runs):
					current.append(CalloutParagraph(role: .body, runs: styled(runs, italic: italic)))
				case .heading(_, let runs):
					current.append(CalloutParagraph(role: .body, runs: styled(runs, bold: true, italic: italic)))
				case .listItem(let ordered, let level, let runs):
					current.append(CalloutParagraph(role: .listItem(ordered: ordered, level: level), runs: styled(runs, italic: italic)))
				case .codeBlock(_, let text):
					current.append(CalloutParagraph(role: .body, runs: [Run(text: text, italic: italic, code: true)]))
				case .blockquote(let inner):
					flatten(inner, italic: true)
				case .alert(_, let innerTitle, let inner):
					current.append(CalloutParagraph(role: .body, runs: [Run(text: innerTitle, bold: true, italic: true)]))
					flatten(inner, italic: true)
				case .horizontalRule, .table, .image:
					if !current.isEmpty { pieces.append(.box(current)) }
					current = []
					pieces.append(.block(block))
				}
			}
		}
		flatten(blocks, italic: false)
		if !current.isEmpty { pieces.append(.box(current)) }
		return pieces
	}

	func renderAlert(kind: String, title: String, blocks: [Block], quoteDepth: Int, above: DocxEdge?, below: DocxEdge?) -> String {
		if !calloutKinds.contains(kind) { calloutKinds.append(kind) }
		lastListType = nil
		let pieces = calloutPieces(title: title, blocks: blocks)
		var xml = ""
		for (index, piece) in pieces.enumerated() {
			let previous: DocxEdge?
			if index == 0 {
				previous = above
			} else if case .block(let block) = pieces[index - 1] {
				previous = bottomEdge(of: block)
			} else {
				previous = .box
			}
			let next: DocxEdge?
			if index + 1 == pieces.count {
				next = below
			} else if case .block(let block) = pieces[index + 1] {
				next = topEdge(of: block)
			} else {
				next = .box
			}
			switch piece {
			case .box(let paragraphs):
				xml += calloutBoxXML(paragraphs, kind: kind, quoteDepth: quoteDepth, above: previous, below: next)
			case .block(let block):
				xml += renderBlock(block, quoteDepth: quoteDepth, above: previous, below: next)
			}
		}
		lastListType = nil
		return xml
	}

	/// One box: its paragraphs share the kind's borders, shading and indents, so Word
	/// draws them as one frame, and are spaced like the CSS box, in `em` of the body font.
	func calloutBoxXML(_ paragraphs: [CalloutParagraph], kind: String, quoteDepth: Int, above: DocxEdge?, below: DocxEdge?) -> String {
		let layout = boxLayout
		// Word splits a box wherever borders or indents differ, so every paragraph gets
		// the same ones: the style's, unless a quote's indent or list bullets (which hang
		// in a wider left padding) move the text.
		let listHang = paragraphs.contains(where: \.isListItem) ? Self.listHangingIndent : 0
		let offset = quoteDepth * Self.quoteIndent
		let directBorders = listHang > 0 ? calloutBordersXML(kind: kind, listHang: listHang) : ""
		let directIndent = listHang > 0 || offset > 0
		var xml = ""
		for (index, paragraph) in paragraphs.enumerated() {
			let isLast = index + 1 == paragraphs.count
			let before = index == 0 ? layout.boxSpaceBefore(above: above) : 0
			let after: Int
			if isLast {
				after = layout.boxSpaceAfter(below: below)
			} else if case .title = paragraph.role {
				after = layout.paragraphGap
			} else if paragraph.isListItem, paragraphs[index + 1].isListItem {
				after = layout.itemGap
			} else {
				after = layout.bodyGap
			}

			var styleID = DocxStyleID.callout(kind: kind)
			if case .title = paragraph.role { styleID = DocxStyleID.calloutTitle(kind: kind) }
			var pPr = "<w:pStyle w:val=\"\(styleID)\"/>"
			if !isLast { pPr += "<w:keepNext/>" }                  // CSS break-inside: avoid
			var hanging = ""
			if case .listItem(let ordered, let level) = paragraph.role {
				pPr += "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(listNumId(ordered: ordered))\"/></w:numPr>"
				hanging = " w:hanging=\"\(listHang)\""
			} else {
				lastListType = nil
			}
			pPr += directBorders
			pPr += "<w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/>"
			if directIndent {
				pPr += "<w:ind w:left=\"\(layout.leftIndent(listHang: listHang, offset: offset))\" w:right=\"\(layout.rightIndent)\"\(hanging)/>"
			}
			xml += "<w:p><w:pPr>\(pPr)</w:pPr>\(renderRuns(paragraph.runs))</w:p>\n"
		}
		if below == .box {
			// Two boxes in a row would join into one: an unbordered 1pt paragraph parts them.
			xml += spacerParagraph()
		}
		return xml
	}

	/// An empty, unstyled 1pt paragraph that keeps two framed groups (boxes, quotes)
	/// from joining; the reader takes it as the boundary between them.
	func spacerParagraph() -> String {
		let hairline = DocxBoxLayout.hairlineTwips
		let size = DocxBoxLayout.hairlineHalfPoints
		return "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"\(hairline)\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:pPr></w:p>\n"
	}

	/// The box frame: the kind's 3pt accent border on the left, and borders in the fill
	/// colour on the other sides, which only exist to pad the text (Word pads a side
	/// only when it has a border). The shading fills the padding.
	func calloutBordersXML(kind: String, listHang: Int) -> String {
		let palette = alertColors.palette(forKind: kind)
		let layout = boxLayout
		let hairline = DocxBoxLayout.hairlineBorderEighths
		return "<w:pBdr>"
			+ "<w:top w:val=\"single\" w:sz=\"\(hairline)\" w:space=\"\(layout.paddingBlock)\" w:color=\"\(palette.background)\"/>"
			+ "<w:left w:val=\"single\" w:sz=\"\(layout.accentBorderEighths)\" w:space=\"\(layout.paddingLeft(listHang: listHang))\" w:color=\"\(palette.border)\"/>"
			+ "<w:bottom w:val=\"single\" w:sz=\"\(hairline)\" w:space=\"\(layout.paddingBlock)\" w:color=\"\(palette.background)\"/>"
			+ "<w:right w:val=\"single\" w:sz=\"\(hairline)\" w:space=\"\(layout.paddingRight)\" w:color=\"\(palette.background)\"/>"
			+ "</w:pBdr>"
	}

	// MARK: - Styles

	/// "Block Quote": the grey left bar and one level's indent of a quoted paragraph.
	func quoteStyle() -> String {
		guard usesQuoteStyle else { return "" }
		return """

		<w:style w:type="paragraph" w:customStyle="1" w:styleId="\(DocxStyleID.blockQuote)">
		<w:name w:val="\(DocxStyleID.blockQuoteName)"/>
		<w:basedOn w:val="Normal"/>
		<w:next w:val="\(DocxStyleID.blockQuote)"/>
		<w:qFormat/>
		<w:pPr>
		<w:pBdr><w:left w:val="single" w:sz="12" w:space="4" w:color="CCCCCC"/></w:pBdr>
		<w:ind w:left="\(Self.quoteIndent)"/>
		</w:pPr>
		</w:style>

		"""
	}

	/// "Horizontal Rule": an empty 1pt line with a bottom border; each rule paragraph
	/// sets its own CSS-like spacing.
	func ruleStyle() -> String {
		guard usesRuleStyle else { return "" }
		let hairline = DocxBoxLayout.hairlineTwips
		let size = DocxBoxLayout.hairlineHalfPoints
		return """

		<w:style w:type="paragraph" w:customStyle="1" w:styleId="\(DocxStyleID.rule)">
		<w:name w:val="\(DocxStyleID.ruleName)"/>
		<w:basedOn w:val="Normal"/>
		<w:next w:val="Normal"/>
		<w:pPr>
		<w:pBdr><w:bottom w:val="single" w:sz="\(DocxBoxLayout.ruleBorderEighths)" w:space="0" w:color="DDDDDD"/></w:pBdr>
		<w:spacing w:before="0" w:after="0" w:line="\(hairline)" w:lineRule="exact"/>
		</w:pPr>
		<w:rPr><w:sz w:val="\(size)"/><w:szCs w:val="\(size)"/></w:rPr>
		</w:style>

		"""
	}

	/// "Callout Note" and "Callout Note Title" (and so on for each kind used): the box's
	/// frame, tint, indents and text colour live in the body style, which the title style
	/// inherits, so both draw as one box. The colours are the CSS ones.
	func calloutStyles() -> String {
		let layout = boxLayout
		return calloutKinds.map { kind in
			let palette = alertColors.palette(forKind: kind)
			let body = DocxStyleID.callout(kind: kind)
			return """

			<w:style w:type="paragraph" w:customStyle="1" w:styleId="\(body)">
			<w:name w:val="\(xmlEscape(DocxStyleID.calloutName(kind: kind, title: false)))"/>
			<w:basedOn w:val="Normal"/>
			<w:next w:val="\(body)"/>
			<w:qFormat/>
			<w:pPr>
			<w:keepLines/>
			\(calloutBordersXML(kind: kind, listHang: 0))
			<w:shd w:val="clear" w:color="auto" w:fill="\(palette.background)"/>
			<w:spacing w:before="0" w:after="\(layout.bodyGap)"/>
			<w:ind w:left="\(layout.leftIndent(listHang: 0, offset: 0))" w:right="\(layout.rightIndent)"/>
			</w:pPr>
			<w:rPr><w:color w:val="\(palette.text)"/></w:rPr>
			</w:style>
			<w:style w:type="paragraph" w:customStyle="1" w:styleId="\(DocxStyleID.calloutTitle(kind: kind))">
			<w:name w:val="\(xmlEscape(DocxStyleID.calloutName(kind: kind, title: true)))"/>
			<w:basedOn w:val="\(body)"/>
			<w:next w:val="\(body)"/>
			<w:qFormat/>
			<w:pPr><w:keepNext/><w:spacing w:before="\(layout.margin)" w:after="\(layout.paragraphGap)"/></w:pPr>
			<w:rPr><w:b/><w:bCs/></w:rPr>
			</w:style>
			"""
		}.joined()
	}
}
