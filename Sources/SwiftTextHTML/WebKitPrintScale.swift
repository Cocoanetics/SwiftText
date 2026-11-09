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
			const authored = parseFloat(getComputedStyle(root).zoom) || 1;
			root.style.zoom = String(authored * \(Self.printShrinkCompensation));
		})()
		"""
		_ = try await webView.evaluateJavaScript(script)
	}
}
#endif
