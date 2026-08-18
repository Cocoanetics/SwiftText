//  MainContentExtractor.swift
//  SwiftTextHTML
//
//  Reducing a page to the part a reader came for: the article, without the
//  cookie banner, the navigation, the sidebar, the share buttons and the
//  footer.
//
//  Two tiers, tried in order:
//
//  1. **Structural.** Honour the page's own semantics — `<article>`, `<main>`,
//     `role="main"`. Modern markup says where its content is, and believing it
//     beats guessing.
//  2. **Scoring.** For everything else, score text-bearing blocks by how much
//     prose they hold and propagate those scores to their ancestors, the way
//     Readability does. Whichever subtree accumulates the most wins.
//
//  Both run over a pruned copy of the tree, so boilerplate is gone before
//  anything is measured — a nav full of links cannot out-score an article, and
//  what tier 1 selects is clean too.
//
//  Pure DOM work over the existing tree: portable, no new dependencies.

import Foundation

/// Which part of a document a conversion covers.
public enum ContentScope: Sendable, Hashable {
	/// The entire document, chrome included.
	case wholeDocument

	/// The main content only — the article body, with navigation, cookie
	/// banners, sidebars, share widgets and footers left out.
	///
	/// Heuristic by nature: it reads a page's structure the way a reader view
	/// does. On a document where nothing looks like content it falls back to
	/// ``wholeDocument`` rather than returning nothing.
	case mainContent
}

enum MainContentExtractor {
	/// The main-content subtree of `root`, as a pruned copy.
	///
	/// Never returns something empty: if the heuristics find no content — an
	/// unusual page, or one that is *all* chrome — the original tree is returned
	/// unchanged, on the grounds that too much text is a far smaller failure
	/// than none.
	static func mainContent(of root: DOMElement) -> DOMElement {
		let body = firstDescendant(of: root, named: "body") ?? root

		// One walk for the whole tree: pruning weighs every candidate against the
		// page total, and recomputing each subtree's length on demand would make
		// that quadratic in the document size.
		var rawLengths: [ObjectIdentifier: Int] = [:]
		let totalTextLength = measureRawText(body, into: &rawLengths)

		let pruned = prune(body, rawLengths: rawLengths, totalTextLength: totalTextLength)
		let metrics = Metrics(root: pruned)
		guard metrics.textLength(of: pruned) > 0 else {
			return root
		}

		if let semantic = semanticRoot(in: pruned, metrics: metrics) {
			return semantic
		}
		if let scored = highestScoringSubtree(in: pruned, metrics: metrics) {
			return scored
		}
		return pruned
	}

	// MARK: - Tier 1: the page's own semantics

	/// The element a page nominates as its content: `<article>`, then `<main>`,
	/// then `role="main"`.
	///
	/// Each only counts when there is exactly one of it, and when it holds a
	/// meaningful share of what is left after pruning.
	///
	/// The count rules out a blog index, where there is an `<article>` per teaser
	/// and picking one would throw away the rest of the page. The share rules out
	/// the lone `<article>` that turns out to be a sponsored card or a sidebar
	/// teaser next to the real content — trusting the tag is right, trusting it
	/// past the point where it plainly is not the page is not.
	private static func semanticRoot(in root: DOMElement, metrics: Metrics) -> DOMElement? {
		let available = metrics.textLength(of: root)

		for candidate in [
			descendants(of: root, where: { $0.name.lowercased() == "article" }),
			descendants(of: root, where: { $0.name.lowercased() == "main" }),
			descendants(of: root, where: { ($0.attributes["role"] as? String)?.lowercased() == "main" })
		] {
			guard candidate.count == 1, let only = candidate.first else { continue }
			let length = metrics.textLength(of: only)
			guard length > 0, length * 4 >= available else { continue }
			return only
		}
		return nil
	}

	// MARK: - Tier 2: scoring

	/// The subtree that accumulated the most content score.
	///
	/// Text-bearing blocks score by how much prose they carry; that score flows
	/// up to their ancestors, halving with each level, so the node holding the
	/// most prose most directly comes out on top. Link density then discounts
	/// the result — a block that is mostly anchors is a menu, however much text
	/// it holds.
	private static func highestScoringSubtree(in root: DOMElement, metrics: Metrics) -> DOMElement? {
		var scores: [ObjectIdentifier: Double] = [:]

		for block in descendants(of: root, where: isTextBlock) {
			let text = metrics.textLength(of: block)
			guard text >= 25 else { continue }

			var score = 1.0
			score += Double(metrics.commaCount(of: block))
			score += min(Double(text) / 100.0, 3.0)

			// The block itself is rarely the answer — a single `<p>` is not an
			// article — so the score is banked on its ancestors, weakening with
			// distance. Three levels is enough to reach a container without
			// reaching the whole page.
			var ancestor = metrics.parent(of: block)
			var level = 1
			while let current = ancestor, level <= 3, current !== root {
				scores[ObjectIdentifier(current), default: 0] += score / Double(level)
				ancestor = metrics.parent(of: current)
				level += 1
			}
		}

		let ranked = scores.compactMap { key, score -> (element: DOMElement, score: Double)? in
			guard let element = metrics.element(for: key) else { return nil }
			let adjusted = (score + tagWeight(of: element)) * (1.0 - metrics.linkDensity(of: element))
			return (element, adjusted)
		}

		guard let best = ranked.max(by: { $0.score < $1.score }), best.score > 0 else {
			return nil
		}
		return promoteToContentContainer(best.element, metrics: metrics)
	}

	/// A block whose text is its own, rather than the sum of its children's.
	///
	/// `<div>` and `<section>` count only when they hold nothing structural,
	/// which is what a paragraph looks like in markup that predates `<p>`
	/// discipline — the div-soup case tier 2 exists for. A wrapper of other
	/// blocks is not a paragraph, and scoring it as one would credit a container
	/// with prose it merely contains.
	private static func isTextBlock(_ element: DOMElement) -> Bool {
		switch element.name.lowercased() {
		case "p", "pre", "blockquote", "td", "dd", "figcaption":
			return true

		case "div", "section":
			return !element.children.contains { child in
				guard let child = child as? DOMElement else { return false }
				// `isBlockLevelElement` covers p/div/ul/ol/headings/table/pre;
				// the sectioning tags are not in that set but are just as
				// structural.
				return child.isBlockLevelElement
					|| sectioningElements.contains(child.name.lowercased())
			}

		default:
			return false
		}
	}

	private static let sectioningElements: Set<String> = [
		"section", "article", "main", "header", "footer", "aside", "nav"
	]

	/// A nudge from what the page calls the element. Class and id names are the
	/// most honest signal a div-soup page emits: `entry-content` and `post-body`
	/// mean what they say.
	private static func tagWeight(of element: DOMElement) -> Double {
		contentTokens.contains(where: element.classAndID.contains) ? 25 : 0
	}

	/// Climbs from the winning block to the container that *is* the article.
	///
	/// Scoring tends to land on the innermost wrapper — `div.entry` rather than
	/// the `div.post` that also carries the headline and byline. Climbing while
	/// the ancestor still looks like content and adds almost no text recovers
	/// those without risking a walk back out to the whole page: the ratio is
	/// what stops it, since any ancestor that pulls in real extra text is by
	/// definition no longer just the article.
	private static func promoteToContentContainer(_ element: DOMElement, metrics: Metrics) -> DOMElement {
		var best = element
		var current = metrics.parent(of: element)
		let baseline = max(metrics.textLength(of: element), 1)

		while let candidate = current {
			let name = candidate.name.lowercased()
			guard name != "body", name != "html" else { break }
			guard contentTokens.contains(where: candidate.classAndID.contains) else { break }
			guard Double(metrics.textLength(of: candidate)) / Double(baseline) <= 1.35 else { break }

			best = candidate
			current = metrics.parent(of: candidate)
		}
		return best
	}

	// MARK: - Pruning

	/// Copies `element`, dropping the parts of it that are chrome.
	///
	/// A copy rather than an edit: a document's tree is shared by every
	/// conversion of it, so `markdown(scope: .mainContent)` must not change what
	/// a later `markdown()` returns.
	private static func prune(
		_ element: DOMElement,
		rawLengths: [ObjectIdentifier: Int],
		totalTextLength: Int
	) -> DOMElement {
		let copy = DOMElement(name: element.name, attributes: element.attributes)
		copy.isTransparentWrapper = element.isTransparentWrapper

		for child in element.children {
			guard let childElement = child as? DOMElement else {
				// Text and raw-text nodes are immutable leaves, so they can be
				// shared with the original tree instead of copied.
				copy.addChild(child)
				continue
			}

			let length = rawLengths[ObjectIdentifier(childElement)] ?? 0
			if isBoilerplate(childElement, textLength: length, totalTextLength: totalTextLength) {
				continue
			}
			copy.addChild(prune(childElement, rawLengths: rawLengths, totalTextLength: totalTextLength))
		}
		return copy
	}

	/// Records the text length of every element in the subtree, and returns the
	/// total.
	///
	/// Deliberately not `text().count`: that renders a document — inserting
	/// newlines, dropping `<nav>` and friends — and pruning has to weigh what is
	/// *there*, including the parts it is about to remove.
	@discardableResult
	private static func measureRawText(_ element: DOMElement, into lengths: inout [ObjectIdentifier: Int]) -> Int {
		var total = 0
		for child in element.children {
			if let childElement = child as? DOMElement {
				total += measureRawText(childElement, into: &lengths)
			} else {
				total += child.text().count
			}
		}
		lengths[ObjectIdentifier(element)] = total
		return total
	}

	/// Whether an element is page furniture rather than content.
	///
	/// The size check comes first and overrides everything: an element holding
	/// most of the page's text is the content container no matter what it is
	/// called. Without it a single unlucky class name — `<div class="wrapper
	/// has-sidebar">` — would prune the article along with the sidebar.
	private static func isBoilerplate(_ element: DOMElement, textLength: Int, totalTextLength: Int) -> Bool {
		if totalTextLength > 0, textLength * 2 > totalTextLength {
			return false
		}

		let name = element.name.lowercased()
		if boilerplateTags.contains(name) {
			return true
		}
		if element.attributes["hidden"] != nil {
			return true
		}
		if let role = (element.attributes["role"] as? String)?.lowercased(),
		   boilerplateRoles.contains(role) {
			return true
		}
		return boilerplateTokens.contains(where: element.classAndID.contains)
	}

	/// Elements that are never article content. `<header>` is deliberately
	/// absent: inside an article it carries the headline.
	private static let boilerplateTags: Set<String> = [
		"nav", "footer", "aside", "form", "dialog", "template",
		"script", "style", "noscript", "iframe", "svg", "canvas",
		"button", "select", "input", "textarea"
	]

	/// ARIA landmarks for the same furniture, for pages that mark it up
	/// properly: `banner` is the site header, `complementary` the sidebar,
	/// `contentinfo` the footer.
	private static let boilerplateRoles: Set<String> = [
		"navigation", "banner", "complementary", "contentinfo",
		"search", "form", "dialog", "alertdialog", "menu", "menubar", "toolbar"
	]

	/// Substrings that mark a class or id as chrome. Matched against the
	/// element's class and id joined together, so `sd-sharing-enabled`,
	/// `jp-relatedposts` and `widget_eu_cookie_law_widget` all hit.
	///
	/// Every entry is long enough not to fire inside an ordinary word — the
	/// reason `ad` is not here and `advert` is.
	private static let boilerplateTokens: [String] = [
		"cookie", "consent", "gdpr", "banner", "sidebar", "share", "social",
		"related", "comment", "footer", "masthead", "breadcrumb", "newsletter",
		"subscribe", "advert", "sponsor", "promo", "popup", "modal",
		"pagination", "navigation", "navbar", "menu", "widget", "toolbar",
		"skip-link", "back-to-top", "disqus", "paywall", "signup", "login"
	]

	/// Substrings that mark a class or id as content-bearing.
	private static let contentTokens: [String] = [
		"article", "entry", "post", "content", "main", "story", "blog",
		"hentry", "page-body", "text-body", "markdown"
	]

	// MARK: - Tree helpers

	private static func firstDescendant(of element: DOMElement, named name: String) -> DOMElement? {
		if element.name.lowercased() == name { return element }
		for case let child as DOMElement in element.children {
			if let found = firstDescendant(of: child, named: name) { return found }
		}
		return nil
	}

	private static func descendants(of element: DOMElement, where predicate: (DOMElement) -> Bool) -> [DOMElement] {
		var found: [DOMElement] = []
		for case let child as DOMElement in element.children {
			if predicate(child) { found.append(child) }
			found.append(contentsOf: descendants(of: child, where: predicate))
		}
		return found
	}

	/// Text lengths, link densities and parent links for one tree, computed in a
	/// single walk.
	///
	/// Scoring asks for the same measurements over and over; recomputing them
	/// from the tree each time would be quadratic in the page size.
	private struct Metrics {
		private var textLengths: [ObjectIdentifier: Int] = [:]
		private var linkTextLengths: [ObjectIdentifier: Int] = [:]
		private var commaCounts: [ObjectIdentifier: Int] = [:]
		private var parents: [ObjectIdentifier: DOMElement] = [:]
		private var elements: [ObjectIdentifier: DOMElement] = [:]

		init(root: DOMElement) {
			measure(root, parent: nil)
		}

		@discardableResult
		private mutating func measure(_ element: DOMElement, parent: DOMElement?) -> (text: Int, link: Int, commas: Int) {
			let key = ObjectIdentifier(element)
			elements[key] = element
			if let parent { parents[key] = parent }

			var text = 0
			var link = 0
			var commas = 0

			for child in element.children {
				if let childElement = child as? DOMElement {
					let child = measure(childElement, parent: element)
					text += child.text
					link += child.link
					commas += child.commas
				} else {
					let value = child.text()
					text += value.count
					commas += value.reduce(into: 0) { count, character in
						if character == "," || character == "，" { count += 1 }
					}
				}
			}

			// An anchor's own text counts as linked; nested anchors are illegal
			// HTML, so no double counting is possible.
			if element.name.lowercased() == "a" {
				link = text
			}

			textLengths[key] = text
			linkTextLengths[key] = link
			commaCounts[key] = commas
			return (text, link, commas)
		}

		func element(for key: ObjectIdentifier) -> DOMElement? { elements[key] }
		func parent(of element: DOMElement) -> DOMElement? { parents[ObjectIdentifier(element)] }
		func textLength(of element: DOMElement) -> Int { textLengths[ObjectIdentifier(element)] ?? 0 }
		func commaCount(of element: DOMElement) -> Int { commaCounts[ObjectIdentifier(element)] ?? 0 }

		func linkDensity(of element: DOMElement) -> Double {
			let text = textLength(of: element)
			guard text > 0 else { return 0 }
			return min(Double(linkTextLengths[ObjectIdentifier(element)] ?? 0) / Double(text), 1)
		}
	}
}

private extension DOMElement {
	/// The element's class and id, lowercased and joined — the string the
	/// boilerplate and content token lists are matched against.
	var classAndID: String {
		let classNames = (attributes["class"] as? String) ?? ""
		let identifier = (attributes["id"] as? String) ?? ""
		return "\(classNames) \(identifier)".lowercased()
	}

}
