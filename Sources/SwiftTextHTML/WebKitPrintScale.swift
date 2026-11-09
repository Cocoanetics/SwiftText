#if os(macOS) || os(iOS)
import WebKit

extension WebKitBrowser {
	/// WebKit's print layout is `printingMinimumShrinkFactor` (1.25) wider than the printable
	/// width and is then scaled down to fit, so a CSS px prints as 0.8 pt instead of 0.75 pt
	/// (text 16/15 too large). A root zoom of 0.75 × 1.25 cancels that; an author's own
	/// root `zoom` is multiplied in rather than replaced.
	private static let printShrinkCompensation = 0.75 * 1.25

	@MainActor
	func compensatePrintShrink(in webView: WKWebView) async throws {
		let script = """
		(function() {
			const root = document.documentElement;
			// The authored zoom is read once (a repeated export must not compensate twice) and
			// from the print cascade: an inline value would outrank an `@media print` rule.
			if (!root.dataset.swiftTextAuthoredZoom) {
				// Screen-only rules are skipped, so the computed (screen) value is not used.
				let authored = 1;
				function scan(rules) {
					for (const rule of Array.from(rules)) {
						if (rule.type === CSSRule.MEDIA_RULE) {
							const media = rule.media.mediaText;
							if (!media || /\\b(print|all)\\b/.test(media) || !/\\bscreen\\b/.test(media)) scan(rule.cssRules);
						} else if (rule.type === CSSRule.STYLE_RULE && rule.style.zoom && root.matches(rule.selectorText)) {
							authored = parseFloat(rule.style.zoom) || authored;
						}
					}
				}
				for (const sheet of Array.from(document.styleSheets)) {
					try { scan(sheet.cssRules); } catch (_) { /* cross-origin stylesheet */ }
				}
				authored = parseFloat(root.style.zoom) || authored; // inline outranks the rules
				root.dataset.swiftTextAuthoredZoom = String(authored);
			}
			root.style.zoom = String(parseFloat(root.dataset.swiftTextAuthoredZoom) * \(Self.printShrinkCompensation));
		})()
		"""
		_ = try await webView.evaluateJavaScript(script)
	}
}
#endif
