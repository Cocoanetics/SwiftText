#if canImport(PDFKit) && canImport(WebKit)
import Foundation
import PDFKit
import WebKit

/// Where a same-document fragment link points, as the page's DOM sees it.
struct FragmentLinkTarget: Decodable, Equatable {
	/// The decoded fragment (`q1` for `#q1`).
	let id: String
	/// The first words of the text at the target, used to find it in the PDF.
	let text: String
	/// How many earlier occurrences of `text` precede the target in document order.
	let index: Int
}

enum PDFInternalLinks {

	/// Collects, for every `#fragment` link in the page, the text at its target.
	///
	/// WebKit's print path has no notion of page anchors, so the PDF is later searched
	/// for this text to find the page and position to jump to.
	@MainActor
	static func collectTargets(in webView: WKWebView) async -> [FragmentLinkTarget] {
		let script = """
		(function() {
			\(PDFTextLocator.occurrenceScript)
			const normalize = s => s.replace(/\\s+/g, ' ').trim();
			const result = [];
			const seen = new Set();
			for (const link of Array.from(document.querySelectorAll('a[href^="#"]'))) {
				let id = link.getAttribute('href').slice(1);
				try { id = decodeURIComponent(id); } catch (e) {}
				if (!id || seen.has(id)) continue;
				const target = document.getElementById(id) || document.getElementsByName(id)[0];
				if (!target) continue;
				seen.add(id);
				let text = normalize(target.textContent || '');
				if (!text) {
					// An empty anchor: use the first text that follows it.
					const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
					walker.currentNode = target;
					let node;
					while ((node = walker.nextNode())) {
						if (target.contains(node)) continue;
						text = normalize(node.textContent);
						if (text) break;
					}
				}
				text = text.slice(0, 40).trim();
				if (!text) continue;
				result.push({ id: id, text: text, index: occurrencesBefore(target, text) });
			}
			return JSON.stringify(result);
		})();
		"""
		guard let json = try? await webView.evaluateJavaScript(script) as? String,
		      let data = json.data(using: .utf8),
		      let targets = try? JSONDecoder().decode([FragmentLinkTarget].self, from: data) else { return [] }
		return targets
	}

	/// Rewrites link annotations that WebKit wrote as `/URI` actions on the page's own
	/// URL (`file:///…/x.html#q1`) into internal `GoTo` destinations.
	///
	/// Links whose target can't be located in the PDF are left untouched.
	///
	/// Also returns the zero-based page index of every target that was located.
	static func resolve(pdfData: Data, pageURL: URL?, targets: [FragmentLinkTarget]) -> (data: Data, anchorPages: [String: Int]) {
		guard !targets.isEmpty, let document = PDFDocument(data: pdfData) else { return (pdfData, [:]) }

		let pageBase = pageURL.map(baseString) ?? "about:blank"
		var destinations: [String: PDFDestination] = [:]
		var anchorPages: [String: Int] = [:]
		let locator = PDFTextLocator(document: document)
		for target in targets {
			guard let found = locator.locate(target.text, occurrence: target.index),
			      let page = document.page(at: found.pageIndex) else { continue }
			destinations[target.id] = PDFDestination(page: page, at: CGPoint(x: 0, y: found.bounds.maxY + 4))
			anchorPages[target.id] = found.pageIndex
		}

		var changed = false
		for pageIndex in 0 ..< document.pageCount {
			guard let page = document.page(at: pageIndex) else { continue }
			for annotation in page.annotations {
				guard let url = annotation.url, let fragment = url.fragment, !fragment.isEmpty,
				      baseString(url) == pageBase || baseString(url) == "about:blank" else { continue }
				guard let destination = destinations[fragment.removingPercentEncoding ?? fragment] else { continue }
				annotation.url = nil
				annotation.action = PDFActionGoTo(destination: destination)
				changed = true
			}
		}
		guard changed else { return (pdfData, anchorPages) }
		return (document.dataRepresentation() ?? pdfData, anchorPages)
	}

	private static func baseString(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		components?.fragment = nil
		return components?.string ?? url.absoluteString
	}
}
#endif
