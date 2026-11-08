#if os(macOS) || os(iOS)
import Foundation
import WebKit

/// A heading for the PDF outline, located in the printed PDF like ``PDFChapterHeading``.
package struct PDFOutlineHeading: Decodable {
	package let level: Int
	package let title: String
	package let searchText: String
	package let occurrence: Int
}

@available(macOS 10.15, iOS 13.0, *)
extension WebKitBrowser {
	/// Every `h1`…`h6` with text, in document order, for the PDF outline.
	@MainActor
	package func outlineHeadings() async throws -> [PDFOutlineHeading] {
		let webView = try await loadedWebView()
		let script = """
		(function() {
			const normalize = s => s.replace(/\\s+/g, ' ').trim();
			const result = [];
			for (const heading of Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6'))) {
				const title = normalize(heading.textContent || '');
				const searchText = title.slice(0, 40).trim();
				if (!searchText) continue;
				const range = document.createRange();
				range.setStart(document.body, 0);
				range.setEndBefore(heading);
				// Counted without case, as the PDF is searched: CSS text-transform changes
				// the printed case but not the DOM text.
				const before = normalize(range.toString()).toLowerCase();
				const needle = searchText.toLowerCase();
				let occurrence = 0, from = 0, hit;
				while ((hit = before.indexOf(needle, from)) !== -1) { occurrence++; from = hit + 1; }
				result.push({ level: Number(heading.tagName.slice(1)), title, searchText, occurrence });
			}
			return JSON.stringify(result);
		})();
		"""
		guard let json = try await webView.evaluateJavaScript(script) as? String, let data = json.data(using: .utf8) else {
			throw WebKitBrowserError.printFailed
		}
		return try JSONDecoder().decode([PDFOutlineHeading].self, from: data)
	}
}
#endif
