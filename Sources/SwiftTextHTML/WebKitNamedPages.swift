#if os(macOS)
import AppKit
import Foundation
import PDFKit
import WebKit

extension WebKitBrowser {
	/// With `:left`/`:right` margins, lays every page out against the recto's; the
	/// other pages are shifted afterwards.
	@MainActor
	func layOutAtRectoMargins(in webView: WKWebView) async throws {
		guard let layout = pageSideMargins?.layoutMargins else { return }
		_ = try await webView.evaluateJavaScript("""
		(function() {
			const style = document.createElement('style');
			style.textContent = '@page { margin-left: \(layout.left)pt !important; margin-right: \(layout.right)pt !important; }';
			document.head.appendChild(style);
		})();
		""")
	}

	private struct RunPlan: Decodable {
		let name: String?
		let hasContent: Bool
	}

	/// Prints the document as runs: the flow around each `page: <name>` block, and each
	/// such block, every run on paper of its own size, joined into one PDF. WebKit prints
	/// a document in one pass at one paper size, so a run is isolated by taking the other
	/// runs out of the DOM while it prints. Returns nil when no element asks for a named page.
	@MainActor
	func exportRuns(in webView: WKWebView, paperSize: CGSize, namedPages: WebKitNamedPages) async throws -> (data: Data, anchorPages: [String: Int], blankPages: Set<Int>)? {
		// The browser resolves the cascade (specificity, importance, `page: auto`): each
		// assignment becomes a custom property rule, in source order, and is read back.
		let rules = namedPages.assignments.map { "\($0.selector) { --st-page: \($0.name)\($0.important ? " !important" : ""); }" }
		guard !rules.isEmpty, let rulesJSON = try? JSONSerialization.data(withJSONObject: rules),
		      let rulesText = String(data: rulesJSON, encoding: .utf8) else { return nil }
		// Wrap the outermost elements of each name in a container of their own, merging directly
		// adjacent siblings of one name. The container is the run's boundary, so it survives
		// the print preparation replacing a table with fragments.
		let planScript = """
		(function() {
			const style = document.createElement('style');
			style.textContent = \(rulesText).join('\\n');
			document.head.appendChild(style);
			const runs = [];
			function nameOf(element) {
				const value = getComputedStyle(element).getPropertyValue('--st-page').trim();
				return value && value !== 'auto' ? value : null;
			}
			function onlyBlankBetween(a, b) {
				for (let n = a.nextSibling; n && n !== b; n = n.nextSibling) {
					if (n.nodeType === Node.ELEMENT_NODE) return false;
					if (n.nodeType === Node.TEXT_NODE && n.textContent.trim()) return false;
				}
				return true;
			}
			function walk(parent) {
				for (const child of Array.from(parent.children)) {
					const name = nameOf(child);
					if (!name) { walk(child); continue; }
					const last = runs[runs.length - 1];
					if (last && last.name === name && last.last.parentNode === parent && onlyBlankBetween(last.last, child)) {
						last.last.appendChild(child);
					} else {
						const wrapper = document.createElement('div');
						wrapper.setAttribute('data-st-run', name);
						parent.insertBefore(wrapper, child);
						wrapper.appendChild(child);
						runs.push({ name: name, first: wrapper, last: wrapper });
					}
				}
			}
			walk(document.body);
			style.remove();
			window.__stRuns = runs;
			return runs.length;
		})();
		"""
		guard let count = try await webView.evaluateJavaScript(planScript) as? Int, count > 0 else { return nil }

		// Links and side breaks are located by text, in the document as a whole.
		let linkTargets = await PDFInternalLinks.collectTargets(in: webView)

		var documents: [PDFDocument] = []
		var blank: [Set<Int>] = []
		var named: [Bool] = []
		let sequence = (0 ... count * 2).map { $0 } // gap, run, gap, run, ..., gap
		for step in sequence {
			let isRun = !step.isMultiple(of: 2)
			let index = step / 2
			let isolate = """
			(function() {
				const runs = window.__stRuns;
				const range = document.createRange();
				if (\(isRun)) { range.setStartBefore(runs[\(index)].first); range.setEndAfter(runs[\(index)].last); }
				else {
					\(index > 0 ? "range.setStartAfter(runs[\(index - 1)].last);" : "range.setStart(document.body, 0);")
					\(index < count ? "range.setEndBefore(runs[\(index)].first);" : "range.setEnd(document.body, document.body.childNodes.length);")
				}
				const removed = [];
				function visit(parent) {
					for (const child of Array.from(parent.childNodes)) {
						const at = Array.prototype.indexOf.call(parent.childNodes, child);
						if (!range.intersectsNode(child)) { removed.push([parent, child, child.nextSibling]); parent.removeChild(child); continue; }
						const inside = range.comparePoint(parent, at) === 0 && range.comparePoint(parent, at + 1) === 0;
						if (inside) continue;
						if (child.nodeType === Node.ELEMENT_NODE) visit(child);
						else { removed.push([parent, child, child.nextSibling]); parent.removeChild(child); }
					}
				}
				visit(document.body);
				window.__stRestore = () => { for (const [parent, child, next] of removed.reverse()) parent.insertBefore(child, next); };
				const media = 'img,svg,canvas,video,hr,table,iframe,object';
				return JSON.stringify({ name: \(isRun ? "runs[\(index)].name" : "null"), hasContent: !!document.body.textContent.trim() || !!document.body.querySelector(media) });
			})();
			"""
			guard let json = try await webView.evaluateJavaScript(isolate) as? String,
			      let plan = try? JSONDecoder().decode(RunPlan.self, from: Data(json.utf8)) else { throw WebKitBrowserError.printFailed }
			guard plan.hasContent else {
				_ = try await webView.evaluateJavaScript("window.__stRestore();")
				continue
			}

			let namedPage = namedPages.pages.first { $0.name == plan.name }
			let size = namedPage?.size.map { CGSize(width: $0.width, height: $0.height) } ?? paperSize
			if let namedPage, !namedPage.margins.isEmpty {
				let minimum = namedPages.minimumVerticalMargin
				let declarations = namedPage.margins.map { declaration -> String in
					if minimum > 0, declaration.name == "margin-top" || declaration.name == "margin-bottom" {
						return "\(declaration.name): max(\(minimum)pt, \(declaration.value)) !important;"
					}
					return "\(declaration.name): \(declaration.value) !important;"
				}
				_ = try await webView.evaluateJavaScript("""
				(function() {
					let style = document.getElementById('__stRunStyle');
					if (!style) { style = document.createElement('style'); style.id = '__stRunStyle'; document.head.appendChild(style); }
					style.textContent = '@page { \(declarations.joined(separator: " ")) }';
				})();
				""")
			} else {
				_ = try await webView.evaluateJavaScript("document.getElementById('__stRunStyle') && document.getElementById('__stRunStyle').remove();")
			}
			// WebKit scales the view to the paper's width, so the view takes the run's.
			webView.frame = CGRect(x: 0, y: 0, width: size.width, height: webView.frame.height)
			webView.layout()
			try await prepareTablesForPrinting(in: webView, paperSize: size)
			let sideBreaks = await PDFParityPages.prepareBreaks(in: webView)
			var data = try await Self.paginatedPDFData(from: webView, paperSize: size)
			var blankPages: Set<Int> = []
			(data, blankPages) = PDFParityPages.insertingBlankPages(into: data, requests: sideBreaks)
			if let document = PDFDocument(data: data) {
				documents.append(document)
				blank.append(blankPages)
				named.append(isRun)
			}
			_ = try await webView.evaluateJavaScript("window.__stRestore();")
		}

		// Every run was empty: print the document as it is.
		if documents.isEmpty { return nil }
		// Join the runs' pages; the blank pages keep their place among them.
		let joined = PDFDocument()
		var blankPages: Set<Int> = []
		var namedPageIndices: Set<Int> = []
		for (offset, document) in documents.enumerated() {
			let before = joined.pageCount
			if named[offset] { namedPageIndices.formUnion(before ..< before + document.pageCount) }
			blankPages.formUnion(blank[offset].map { $0 + before })
			for pageIndex in 0 ..< document.pageCount {
				guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
				joined.insert(page, at: joined.pageCount)
			}
		}
		guard var data = joined.dataRepresentation() else { throw WebKitBrowserError.printFailed }
		data = shiftedForSideMargins(data, skipping: namedPageIndices)
		let resolved = PDFInternalLinks.resolve(pdfData: data, pageURL: webView.url, targets: linkTargets)
		return (resolved.data, resolved.anchorPages, blankPages)
	}
}
#endif

#if os(macOS) || os(iOS)
import Foundation

/// The named pages (`@page <name>`) of a document and the style rules that assign them
/// (`.wide { page: wide }`), for ``WebKitBrowser`` to print each named block as a run of
/// pages of its own size.
package struct WebKitNamedPages {
	package var pages: [PageSizeRule.NamedPage]
	package var assignments: [(selector: String, name: String, important: Bool)]
	/// The least top and bottom page margin in points, which the running head and
	/// foot need; a named page's own margins never go below it.
	package var minimumVerticalMargin: Double

	package init(css: String, fallback: (width: Double, height: Double)? = nil, minimumVerticalMargin: Double = 0) {
		pages = PageSizeRule.namedPages(in: css, fallback: fallback)
		assignments = PageSizeRule.pageAssignments(in: css)
		self.minimumVerticalMargin = minimumVerticalMargin
	}

	package var isEmpty: Bool { assignments.isEmpty }
}

extension WebKitBrowser {
	/// Moves the pages of a PDF to their `:left`/`:right` margins (macOS only).
	/// Pages in `skipping` (those of named runs, which carry their own margins) stay put.
	func shiftedForSideMargins(_ data: Data, skipping: Set<Int> = []) -> Data {
		#if os(macOS)
		guard let margins = pageSideMargins else { return data }
		return PDFPageShift.apply(to: data) { skipping.contains($0) ? 0 : margins.shift(pageIndex: $0) }
		#else
		return data
		#endif
	}
}
#endif
