//  MainContentExtractionTests.swift
//  SwiftTextHTMLTests
//
//  `ContentScope.mainContent` — the article without the page around it.
//
//  The shape fixtures below are written out rather than saved from the web:
//  what is being tested is a *structure* (semantic tags, div soup, a listing
//  page), and a hand-written fixture states that structure in twenty lines
//  instead of burying it in three hundred of third-party markup. The one real
//  page in `Resources` is the counterweight — the exact URL from issue #56,
//  saved verbatim, so the heuristics face markup nobody tidied for them.

import Foundation
import Testing
@testable import SwiftTextHTML

@Suite("Main-content extraction")
struct MainContentExtractionTests {

	// MARK: - The real page from the issue

	private func wordPressBlogPost() throws -> Data {
		let url = try #require(
			Bundle.module.url(forResource: "wordpress-blog-post", withExtension: "html"),
			"the saved fixture is missing from the test bundle"
		)
		return try Data(contentsOf: url)
	}

	/// The issue's reproduction, verbatim: `swifttext html --markdown` on this
	/// page opened with a cookie notice, an ad slot, the logo, the social icons
	/// and the main menu — several screens before the article started.
	@Test("The chrome the issue complained about is gone")
	func realPageDropsChrome() async throws {
		let document = try await HTMLDocument(data: try wordPressBlogPost())
		let markdown = document.markdown(scope: .mainContent)

		// Every one of these is quoted in the issue.
		#expect(!markdown.contains("Privacy & Cookies"))
		#expect(!markdown.contains("Cookie Policy"))
		#expect(!markdown.contains("Our DNA is written in Swift"))
		#expect(!markdown.contains("youtube.com/mindpower74"))
		#expect(!markdown.contains("/advertise/"))

		// Share buttons and related posts sit *after* the body, so they survive
		// any heuristic that only trims a prefix. Both strings below appear in
		// the whole-document conversion of this same fixture, which is what
		// makes their absence here worth asserting.
		#expect(!markdown.contains("Click to share on"))
		#expect(!markdown.contains("### *Related*"))
	}

	/// Dropping the chrome is only half of it — the article has to survive.
	@Test("The article itself is kept, headline first")
	func realPageKeepsArticle() async throws {
		let document = try await HTMLDocument(data: try wordPressBlogPost())
		let markdown = document.markdown(scope: .mainContent)

		#expect(markdown.hasPrefix("# SwiftText"))
		#expect(markdown.contains("Reading PDFs"))
		#expect(markdown.contains("Conclusion"))
		// A body sentence, to catch an extractor that keeps the headings and
		// loses the prose under them.
		#expect(markdown.contains("bank statements"))
	}

	/// The scope is opt-in: the default has to keep behaving exactly as it did.
	@Test("The default scope still converts the whole page")
	func realPageWholeDocumentUnchanged() async throws {
		let document = try await HTMLDocument(data: try wordPressBlogPost())
		let whole = document.markdown()

		#expect(whole.contains("Privacy & Cookies"))
		#expect(whole.contains("Our DNA is written in Swift"))
		#expect(whole.contains("bank statements"))
		#expect(whole.count > document.markdown(scope: .mainContent).count)
	}

	/// The tree a document exposes is shared by every conversion of it, so
	/// extraction must copy rather than prune in place. This is the test that
	/// fails if it ever starts editing the original.
	@Test("Extraction leaves the document's own tree alone")
	func extractionDoesNotMutateTheDocument() async throws {
		let document = try await HTMLDocument(data: try wordPressBlogPost())
		let before = document.markdown()
		_ = document.markdown(scope: .mainContent)
		_ = document.text(scope: .mainContent)
		#expect(document.markdown() == before)
	}

	// MARK: - Structural tier

	@Test("A single <article> is taken as the content")
	func semanticArticle() async throws {
		let html = """
		<html><body>
		<div class="cookie-consent"><p>We use cookies to improve your experience.</p></div>
		<nav><a href="/">Home</a> <a href="/news">News</a></nav>
		<article>
			<h1>Bridge Reopens</h1>
			<p>The bridge reopened on Tuesday after eighteen months of repairs, which the council said had run to budget.</p>
			<p>Traffic returned to the crossing within the hour, easing the detour that had added twenty minutes to the trip.</p>
		</article>
		<aside class="sidebar"><h2>Most read</h2><p>Ten things you missed this week.</p></aside>
		<footer><p>Copyright 2026 The Example Times.</p></footer>
		</body></html>
		"""
		let markdown = try await HTMLDocument(data: Data(html.utf8)).markdown(scope: .mainContent)

		#expect(markdown.hasPrefix("# Bridge Reopens"))
		#expect(markdown.contains("eighteen months"))
		#expect(!markdown.contains("cookies"))
		#expect(!markdown.contains("Most read"))
		#expect(!markdown.contains("Copyright"))
	}

	@Test("<main> is used when there is no <article>")
	func semanticMain() async throws {
		let html = """
		<html><body>
		<nav class="docs-sidebar"><a href="/install">Install</a> <a href="/usage">Usage</a></nav>
		<main>
			<h1>Installation</h1>
			<p>Add the package to your dependencies and import the module you need; each one is small enough to adopt on its own.</p>
		</main>
		<footer>Built with love.</footer>
		</body></html>
		"""
		let markdown = try await HTMLDocument(data: Data(html.utf8)).markdown(scope: .mainContent)

		#expect(markdown.hasPrefix("# Installation"))
		#expect(!markdown.contains("Install]"))
		#expect(!markdown.contains("Built with love"))
	}

	@Test("role=\"main\" is honoured when the tags are not")
	func ariaMainRole() async throws {
		let html = """
		<html><body>
		<div role="navigation"><a href="/">Home</a></div>
		<div role="main">
			<h1>Quarterly Update</h1>
			<p>Revenue held steady through the quarter, with the shortfall in hardware offset by a better than expected services line.</p>
		</div>
		<div role="contentinfo">All rights reserved.</div>
		</body></html>
		"""
		let markdown = try await HTMLDocument(data: Data(html.utf8)).markdown(scope: .mainContent)

		#expect(markdown.hasPrefix("# Quarterly Update"))
		#expect(!markdown.contains("All rights reserved"))
	}

	/// A listing page has an `<article>` per teaser. Picking one of them would
	/// throw away the rest of the page, so the structural tier stands down and
	/// scoring finds their common parent instead.
	@Test("A page of many <article>s keeps all of them")
	func multipleArticlesFallThroughToScoring() async throws {
		let teasers = (1 ... 4).map { index in
			"""
			<article>
				<h2>Story number \(index)</h2>
				<p>A summary of story number \(index), long enough to read as prose rather than as a label, with a clause after a comma.</p>
			</article>
			"""
		}.joined()
		let html = """
		<html><body>
		<nav class="site-menu"><a href="/">Home</a></nav>
		<div id="content">\(teasers)</div>
		<footer>Copyright 2026.</footer>
		</body></html>
		"""
		let markdown = try await HTMLDocument(data: Data(html.utf8)).markdown(scope: .mainContent)

		for index in 1 ... 4 {
			#expect(markdown.contains("Story number \(index)"))
		}
		#expect(!markdown.contains("Copyright"))
	}

	/// A lone `<article>` is not automatically the page. A sponsored card or a
	/// teaser beside the real content carries the tag just as legitimately, so
	/// the structural tier stands down when the element holds only a sliver of
	/// what is left after pruning.
	@Test("A tiny lone <article> does not beat the real body")
	func smallArticleIsNotTrusted() async throws {
		let body = (1 ... 6).map { index in
			"<div class=\"post-body\">Paragraph \(index) of the actual report, which runs on at length, with commas, and carries the substance of the page.</div>"
		}.joined()
		let html = """
		<html><body>
		<article><h2>Sponsored</h2><p>A short promotional blurb.</p></article>
		<div id="content">\(body)</div>
		</body></html>
		"""
		let markdown = try await HTMLDocument(data: Data(html.utf8)).markdown(scope: .mainContent)

		#expect(markdown.contains("the actual report"))
		#expect(!markdown.contains("Sponsored"))
	}

	// MARK: - Scoring tier

	/// No semantic tags at all — the case the second tier exists for.
	@Test("Div soup is scored, and the prose wins")
	func divSoupIsScored() async throws {
		let html = """
		<html><body>
		<div id="header"><div class="banner">Subscribe now and save, our best offer yet, ending soon!</div></div>
		<div id="nav-main"><a href="/a">Alpha</a><a href="/b">Beta</a><a href="/c">Gamma</a><a href="/d">Delta</a></div>
		<div id="page">
			<div id="content-main">
				<div class="post-body">
					<div>The harbour project began in spring, and by midsummer the first of the new berths was taking boats, ahead of a schedule nobody had believed.</div>
					<div>Costs, which had been the sticking point at every hearing, came in under the revised estimate, though above the original one.</div>
				</div>
			</div>
			<div id="sidebar-right"><a href="/x">Popular</a><a href="/y">Recent</a><a href="/z">Archive</a></div>
		</div>
		<div id="footer-wrap">Copyright 2026 Harbour Gazette.</div>
		</body></html>
		"""
		let markdown = try await HTMLDocument(data: Data(html.utf8)).markdown(scope: .mainContent)

		#expect(markdown.contains("harbour project"))
		#expect(markdown.contains("sticking point"))
		#expect(!markdown.contains("Subscribe"))
		#expect(!markdown.contains("Popular"))
		#expect(!markdown.contains("Copyright"))
	}

	/// Link density is what separates a menu from an article: a block of pure
	/// anchors can be longer than the prose and still must not win.
	@Test("A long list of links does not out-score shorter prose")
	func linkDensityDemotesMenus() async throws {
		let links = (1 ... 40).map { "<a href=\"/page\($0)\">Section number \($0) of the handbook</a>" }.joined()
		let html = """
		<html><body>
		<div id="directory"><div>\(links)</div></div>
		<div id="story">
			<p>The vote passed in the evening, after two amendments, and the result was posted before the room had emptied.</p>
		</div>
		</body></html>
		"""
		let markdown = try await HTMLDocument(data: Data(html.utf8)).markdown(scope: .mainContent)

		#expect(markdown.contains("The vote passed"))
		#expect(!markdown.contains("Section number 1 of the handbook"))
	}

	// MARK: - Fallback

	/// Returning almost nothing is a far worse failure than returning too much,
	/// so a page the heuristics cannot read must come back whole.
	@Test("A page with no discernible content is returned whole")
	func fallsBackToWholeDocument() async throws {
		let html = "<html><body><div class=\"menu\"><a href=\"/\">Home</a></div></body></html>"
		let document = try await HTMLDocument(data: Data(html.utf8))
		#expect(document.markdown(scope: .mainContent) == document.markdown())
	}

	@Test("An empty document does not trap the extractor")
	func emptyDocument() async throws {
		let document = try await HTMLDocument(data: Data("<html><body></body></html>".utf8))
		#expect(document.markdown(scope: .mainContent).isEmpty)
		#expect(document.text(scope: .mainContent).isEmpty)
	}

	// MARK: - Plain text

	@Test("text(scope:) narrows the same way markdown(scope:) does")
	func plainTextHonoursScope() async throws {
		let html = """
		<html><body>
		<div class="cookie-banner"><p>This site uses cookies for analytics and advertising purposes.</p></div>
		<article><h1>Tide Tables</h1><p>The spring tide arrives on Thursday, an hour later than the almanac has it, and runs high into the evening.</p></article>
		</body></html>
		"""
		let document = try await HTMLDocument(data: Data(html.utf8))

		let scoped = document.text(scope: .mainContent)
		#expect(scoped.contains("spring tide"))
		#expect(!scoped.contains("cookies"))
		#expect(document.text().contains("cookies"))
	}
}
