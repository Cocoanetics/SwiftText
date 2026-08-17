//  PageBreakTests.swift
//  SwiftTextRenderTests
//
//  CSS Fragmentation: break-before / break-after / break-inside, and the legacy
//  page-break-* aliases.

import Testing
import Foundation
@testable import SwiftTextRender
import SwiftTextCSS

#if canImport(PDFKit)
import PDFKit
#endif

@Suite("Page breaks")
struct PageBreakTests {

	/// Count page objects in raw PDF bytes. Page dictionaries are never inside a
	/// compressed stream, so this works without PDFKit — which matters because
	/// pagination is portable logic that must be tested off Apple platforms too.
	private func pageCount(_ data: Data) -> Int {
		func occurrences(of string: String) -> Int {
			let needle = Data(string.utf8)
			var count = 0
			var index = data.startIndex
			while let range = data[index...].range(of: needle) {
				count += 1
				index = range.upperBound
			}
			return count
		}
		// "/Type /Pages" is the page-tree node, not a page.
		return occurrences(of: "/Type /Page") - occurrences(of: "/Type /Pages")
	}

	private let threeSections = """
	<style>h1 { break-before: page; }</style>
	<h1>Alpha</h1><p>First.</p>
	<h1>Beta</h1><p>Second.</p>
	<h1>Gamma</h1><p>Third.</p>
	"""

	@Test("break-before: page starts each section on a new page")
	func forcedBreakBefore() async throws {
		let data = try await HTMLRenderer.renderPDF(html: threeSections)
		#expect(pageCount(data) == 3)
	}

	@Test("The same content without the rule stays on one page")
	func withoutRuleStaysSinglePage() async throws {
		let html = threeSections.replacingOccurrences(of: "break-before: page;", with: "")
		let data = try await HTMLRenderer.renderPDF(html: html)
		#expect(pageCount(data) == 1)
	}

	@Test("Legacy page-break-before: always is honoured identically")
	func legacyAliasMatchesModernProperty() async throws {
		let legacy = threeSections.replacingOccurrences(
			of: "break-before: page;", with: "page-break-before: always;")
		let modern = try await HTMLRenderer.renderPDF(html: threeSections)
		let data = try await HTMLRenderer.renderPDF(html: legacy)
		#expect(pageCount(data) == pageCount(modern))
		#expect(pageCount(data) == 3)
	}

	@Test("A forced break with nothing above it does not emit a blank first page")
	func noLeadingBlankPage() async throws {
		// The document opens with the breaking element, so the break sits below
		// the body's top margin rather than at y = 0 — the suppression has to be
		// based on painted content, not on the coordinate.
		let data = try await HTMLRenderer.renderPDF(html: threeSections)
		#expect(pageCount(data) == 3)

		#if canImport(PDFKit)
		let document = try #require(PDFDocument(data: data))
		let firstPage = try #require(document.page(at: 0)).string ?? ""
		#expect(firstPage.contains("Alpha"))
		#endif
	}

	@Test("A forced break below existing content is honoured")
	func breakAfterLeadingContentIsKept() async throws {
		let html = """
		<style>h1 { break-before: page; }</style>
		<p>Introduction before any heading.</p>
		<h1>Alpha</h1><p>First.</p>
		<h1>Beta</h1><p>Second.</p>
		"""
		let data = try await HTMLRenderer.renderPDF(html: html)
		#expect(pageCount(data) == 3)
	}

	@Test("break-after: page ends a section")
	func forcedBreakAfter() async throws {
		let html = """
		<style>.section { break-after: page; }</style>
		<div class="section"><p>One.</p></div>
		<div class="section"><p>Two.</p></div>
		<p>Three.</p>
		"""
		let data = try await HTMLRenderer.renderPDF(html: html)
		#expect(pageCount(data) == 3)
	}

	@Test("A trailing break-after does not emit a blank last page")
	func noTrailingBlankPage() async throws {
		let html = """
		<style>p { break-after: page; }</style>
		<p>Only paragraph.</p>
		"""
		let data = try await HTMLRenderer.renderPDF(html: html)
		#expect(pageCount(data) == 1)
	}

	#if canImport(PDFKit)
	@Test("break-inside: avoid moves a block that would straddle a page boundary")
	func breakInsideAvoidKeepsBlockTogether() async throws {
		// A 120px spacer, then a ~96px block of five unmargined lines. With a 180px
		// content height the block straddles the boundary and would naturally be
		// split after its third line — but it is short enough to fit on a page of
		// its own, so the preference is satisfiable.
		func html(avoid: Bool) -> String {
			"""
			<style>
			.spacer { height: 120px; }
			.keep p { margin: 0; }
			.keep { \(avoid ? "break-inside: avoid;" : "") }
			</style>
			<div class="spacer"></div>
			<div class="keep">
			<p>Kappa one</p><p>Kappa two</p><p>Kappa three</p>
			<p>Kappa four</p><p>Kappa five</p>
			</div>
			"""
		}
		let options = RenderOptions(pageWidthPx: 400, pageHeightPx: 200, pageMarginPx: 10)

		let split = try #require(PDFDocument(data:
			try await HTMLRenderer.renderPDF(html: html(avoid: false), options: options)))
		let kept = try #require(PDFDocument(data:
			try await HTMLRenderer.renderPDF(html: html(avoid: true), options: options)))

		// Without the rule the block is split across the boundary...
		let splitFirstPage = try #require(split.page(at: 0)).string ?? ""
		#expect(splitFirstPage.contains("Kappa one"))
		#expect(!splitFirstPage.contains("Kappa five"))

		// ...with it, the whole block moves to the next page.
		let keptFirstPage = try #require(kept.page(at: 0)).string ?? ""
		#expect(!keptFirstPage.contains("Kappa one"))

		let keptSecondPage = try #require(kept.page(at: 1)).string ?? ""
		for line in ["Kappa one", "Kappa two", "Kappa three", "Kappa four", "Kappa five"] {
			#expect(keptSecondPage.contains(line), "\(line) should share a page")
		}
	}
	#endif

	@Test("A block taller than the page is still split despite break-inside: avoid")
	func oversizedBlockIsSplitAnyway() async throws {
		let paragraphs = (0 ..< 40).map { "<p>Line number \($0) of a very tall block.</p>" }.joined()
		let html = """
		<style>.keep { break-inside: avoid; }</style>
		<div class="keep">\(paragraphs)</div>
		"""
		let options = RenderOptions(pageWidthPx: 400, pageHeightPx: 200, pageMarginPx: 10)
		let data = try await HTMLRenderer.renderPDF(html: html, options: options)
		// It cannot fit, so the preference is dropped rather than looping forever.
		#expect(pageCount(data) > 1)
	}

	@Test("break-inside rejects forced-break keywords, break-before rejects avoid-only ones")
	func keywordSetsAreNotInterchangeable() {
		func style(_ css: String) -> ComputedStyle {
			applyDeclarations(parseDeclarations(inlineStyle: css),
			                  inheriting: .initial, rootFontSize: 16)
		}
		// `break-inside: page` is invalid — the property has no forced-break value.
		#expect(style("break-inside: page").breakInside == .auto)
		#expect(style("break-inside: avoid").breakInside == .avoid)
		// Column/region variants collapse onto their page equivalents.
		#expect(style("break-inside: avoid-column").breakInside == .avoid)
		#expect(style("break-before: left").breakBefore == .page)
		#expect(style("break-before: avoid").breakBefore == .avoid)
		#expect(style("break-before: nonsense").breakBefore == .auto)
	}

	@Test("An auto-height render stays on one page despite forced breaks")
	func autoHeightIgnoresForcedBreaks() async throws {
		// `pageHeightPx: nil` means "one page, as tall as the content" — there is
		// no page boundary for a break to land on.
		let options = RenderOptions(pageHeightPx: nil)
		let data = try await HTMLRenderer.renderPDF(html: threeSections, options: options)
		#expect(pageCount(data) == 1)
	}

	@Test("An empty block that paints only a background still counts as content")
	func backgroundOnlyBlockCountsAsContent() async throws {
		// The banner paints, so the break after it is not a leading blank page.
		let html = """
		<style>.banner { height: 20px; background: #c00; break-after: page; }</style>
		<div class="banner"></div>
		<p>Text below the banner.</p>
		"""
		let data = try await HTMLRenderer.renderPDF(html: html)
		#expect(pageCount(data) == 2)
	}

	@Test("A decorative wrapper around the content does not defeat blank-page suppression")
	func wrapperBackgroundDoesNotCountAsContent() async throws {
		// A background on an element that *contains* the content is not itself
		// content; the leading blank page must still be suppressed.
		let html = threeSections.replacingOccurrences(
			of: "<style>", with: "<style>body { background: #eee; }\n")
		let data = try await HTMLRenderer.renderPDF(html: html)
		#expect(pageCount(data) == 3)
	}

	@Test("Modern and legacy spellings cascade as one property, in source order")
	func aliasesCascadeTogether() async throws {
		// Both spellings target the same property, so the later declaration wins
		// regardless of which spelling it uses. Keying them separately would make
		// the outcome depend on dictionary iteration order.
		let legacyThenModern = """
		<style>h1 { page-break-before: always; break-before: auto; }</style>
		<h1>Alpha</h1><p>First.</p>
		<h1>Beta</h1><p>Second.</p>
		"""
		let modernThenLegacy = """
		<style>h1 { break-before: auto; page-break-before: always; }</style>
		<h1>Alpha</h1><p>First.</p>
		<h1>Beta</h1><p>Second.</p>
		"""
		#expect(pageCount(try await HTMLRenderer.renderPDF(html: legacyThenModern)) == 1)
		#expect(pageCount(try await HTMLRenderer.renderPDF(html: modernThenLegacy)) == 2)
	}

	@Test("Fragmentation properties are not inherited")
	func notInherited() {
		var parent = ComputedStyle.initial
		parent.breakBefore = .page
		parent.breakInside = .avoid
		let child = ComputedStyle.inheriting(from: parent)
		#expect(child.breakBefore == .auto)
		#expect(child.breakInside == .auto)
	}
}
