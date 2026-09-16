//
//  StyleRunMarkup.swift
//  SwiftTextOCR
//
//  Turning style runs into Markdown inline markup.
//

import Foundation
import Markdown

extension Array where Element == StyleRun {
	/// These runs as Markdown inline markup, with each run's style written as
	/// the emphasis that produced it.
	///
	/// Whitespace at a run's edges is moved outside the emphasis. Markdown
	/// closes emphasis on a non-space character, so `*kursiv *` — which is how
	/// a page hands the run over — would not be emphasis at all. Monospaced
	/// text becomes inline code and takes no further emphasis, because code
	/// spans hold no markup.
	func inlineMarkup(bodySize: CGFloat?) -> [InlineMarkup] {
		var result: [InlineMarkup] = []
		for run in coalesced() {
			guard let style = run.style, isEmphasised(style, bodySize: bodySize) else {
				result.append(Text(run.text))
				continue
			}
			let leading = String(run.text.prefix { $0.isWhitespace })
			let trailing = String(run.text.reversed().prefix { $0.isWhitespace }.reversed())
			let core = String(run.text.dropFirst(leading.count).dropLast(trailing.count))
			guard !core.isEmpty else {
				result.append(Text(run.text))
				continue
			}
			if !leading.isEmpty { result.append(Text(leading)) }
			result.append(emphasis(around: core, style: style))
			if !trailing.isEmpty { result.append(Text(trailing)) }
		}
		return result.isEmpty ? [Text(text)] : result
	}

	private func emphasis(around text: String, style: TextStyle) -> InlineMarkup {
		if style.isMonospaced { return InlineCode(text) }
		if style.isBold && style.isItalic { return Strong(Emphasis(Text(text))) }
		if style.isBold { return Strong(Text(text)) }
		return Emphasis(Text(text))
	}

	/// Whether a run differs from body text in a way Markdown can write.
	///
	/// A heading's own bold is not emphasis — it is what makes it a heading —
	/// so a run larger than body text is left plain and the block carries the
	/// level instead.
	private func isEmphasised(_ style: TextStyle, bodySize: CGFloat?) -> Bool {
		if let bodySize, style.fontSize > bodySize + 0.5 { return false }
		return style.isBold || style.isItalic || style.isMonospaced
	}
}
