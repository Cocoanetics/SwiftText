#if os(macOS) || os(iOS)
import Foundation
import WebKit
#if canImport(PDFKit)
import PDFKit
#endif

/// A block that asked to start on a specific side of the spread
/// (`break-before: left|right|recto|verso`), as the page's DOM sees it.
struct SideBreakRequest: Decodable, Equatable {
	/// Whether the block wants a right-hand (odd) page; otherwise a left-hand one.
	let right: Bool
	/// The first words of the block's text, used to find its page in the PDF.
	let text: String
	/// How many earlier occurrences of `text` precede the block in document order.
	let index: Int
}

/// Blank pages that put `break-before: left|right` blocks on the requested side.
///
/// WebKit's print paginator treats those keywords as a plain page break, so the
/// browser prints every one as `page` and the parity is repaired afterwards:
/// walking the blocks in page order, a blank page goes before one that landed on
/// the wrong side, which also moves every later page, so each block is judged
/// at its position once the earlier blanks are in.
enum PDFParityPages {
	/// For blocks starting original pages (zero-based, as `(page, right)`), the
	/// original pages a blank page goes in front of, and the final zero-based
	/// indices of those blank pages. The first block on a page decides for it.
	static func blankPages(for requests: [(page: Int, right: Bool)]) -> (before: [Int], indices: Set<Int>) {
		var before: [Int] = []
		var indices: Set<Int> = []
		var seen: Set<Int> = []
		for request in requests.enumerated().sorted(by: { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }).map(\.element)
		where seen.insert(request.page).inserted {
			let position = request.page + before.count
			// Page 1 (index 0) is a right-hand page.
			guard position.isMultiple(of: 2) != request.right else { continue }
			indices.insert(position)
			before.append(request.page)
		}
		return (before, indices)
	}

	/// Marks forced breaks for printing and returns the ones that ask for a side.
	///
	/// Every `left`/`right`/`recto`/`verso` is printed as a plain page break. A forced
	/// break with nothing above it is dropped, as WebKit would otherwise open the
	/// document with a blank page; a side request there is still returned, so a
	/// `left` start gets its blank first page.
	@MainActor
	static func prepareBreaks(in webView: WKWebView) async -> [SideBreakRequest] {
		let script = """
		(function() {
			const normalize = s => s.replace(/\\s+/g, ' ').trim();
			const sides = new Set(['left', 'right', 'recto', 'verso']);
			const forced = new Set(['page', 'always', 'left', 'right', 'recto', 'verso']);
			const all = Array.from(document.body.querySelectorAll('*'));
			let contentSeen = false;
			function leading(element) {
				if (contentSeen) return false;
				for (const other of all) {
					if (other === element) break;
					if (other.contains(element)) continue;
					const rect = other.getBoundingClientRect();
					if (rect.width > 0 && rect.height > 0) { contentSeen = true; return false; }
				}
				return true;
			}
			function locate(element) {
				let text = normalize(element.textContent || '');
				if (!text) {
					const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
					walker.currentNode = element;
					let node;
					while ((node = walker.nextNode())) {
						if (element.contains(node)) continue;
						text = normalize(node.textContent);
						if (text) break;
					}
				}
				text = text.slice(0, 40).trim();
				if (!text) return null;
				const range = document.createRange();
				range.setStart(document.body, 0);
				range.setEndBefore(element);
				const before = normalize(range.toString()).toLowerCase();
				const needle = text.toLowerCase();
				let index = 0, from = 0, hit;
				while ((hit = before.indexOf(needle, from)) !== -1) { index += 1; from = hit + 1; }
				return { text, index };
			}
			const result = [];
			for (const element of all) {
				const style = getComputedStyle(element);
				const breakBefore = style.breakBefore, breakAfter = style.breakAfter;
				if (forced.has(breakAfter)) element.style.setProperty('break-after', 'page', 'important');
				if (!forced.has(breakBefore)) continue;
				const atTop = leading(element);
				const position = sides.has(breakBefore) ? locate(element) : null;
				element.style.setProperty('break-before', atTop ? 'auto' : 'page', 'important');
				if (position) result.push({ right: breakBefore === 'right' || breakBefore === 'recto', text: position.text, index: position.index });
			}
			return JSON.stringify(result);
		})();
		"""
		guard let json = try? await webView.evaluateJavaScript(script) as? String,
		      let data = json.data(using: .utf8),
		      let requests = try? JSONDecoder().decode([SideBreakRequest].self, from: data) else { return [] }
		return requests
	}

	#if canImport(PDFKit)
	/// Adds the blank pages the requests call for, each the size of the page it
	/// precedes. Returns the PDF and the zero-based indices of the blank pages in it.
	static func insertingBlankPages(into data: Data, requests: [SideBreakRequest]) -> (data: Data, blankPages: Set<Int>) {
		guard !requests.isEmpty, let document = PDFDocument(data: data) else { return (data, []) }
		let located = requests.compactMap { request -> (page: Int, right: Bool)? in
			let matches = document.findString(request.text, withOptions: [.caseInsensitive])
			guard request.index < matches.count, let page = matches[request.index].pages.first else { return nil }
			return (document.index(for: page), request.right)
		}
		let plan = blankPages(for: located)
		guard !plan.before.isEmpty else { return (data, []) }
		for (offset, original) in plan.before.enumerated() {
			let blank = PDFPage()
			if let neighbour = document.page(at: original + offset) {
				blank.setBounds(neighbour.bounds(for: .mediaBox), for: .mediaBox)
			}
			document.insert(blank, at: original + offset)
		}
		return (document.dataRepresentation() ?? data, plan.indices)
	}
	#endif
}
#endif
