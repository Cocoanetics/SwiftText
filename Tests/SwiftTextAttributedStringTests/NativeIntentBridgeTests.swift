// Native intents exist on every Apple platform (iOS 15+, etc.), but among the
// package's deployment targets only macOS (.v12) clears `AttributedString`'s
// floor, and swift-testing rejects an `@available` annotation — so this Apple-
// only suite compiles on macOS. The bridge code itself is identical across Apple
// platforms, so macOS coverage validates it everywhere.
#if os(macOS)

import Testing
import Foundation
@testable import SwiftTextAttributedString

/// Apple-only: verifies the renderer ALSO sets Foundation's native
/// `presentationIntent` / `inlinePresentationIntent`, derived from the same data
/// as the portable custom attributes, so the result interoperates with
/// SwiftUI / TextKit. (On Linux/Windows these types don't exist; only the
/// portable attributes are set — see `MarkdownAttributedStringRendererTests`.)
@Suite("Native presentation-intent bridge (Apple)")
struct NativeIntentBridgeTests {

	private func render(_ markdown: String) -> AttributedString {
		MarkdownAttributedStringRenderer.convert(markdown)
	}

	private func firstRun(
		_ attributed: AttributedString, where predicate: (String) -> Bool
	) -> AttributedString.Runs.Element? {
		for run in attributed.runs where predicate(String(attributed.characters[run.range])) {
			return run
		}
		return nil
	}

	@Test func headingHasNativeHeaderIntent() {
		let attributed = render("# Title")
		guard let kind = attributed.runs.first?.presentationIntent?.components.first?.kind else {
			Issue.record("missing native presentation intent"); return
		}
		#expect(kind == .header(level: 1))
	}

	@Test func listChainMatchesPortableChain() {
		let attributed = render("- item")
		let run = firstRun(attributed) { $0 == "item" }
		let nativeKinds = (run?.presentationIntent?.components ?? []).map { "\($0.kind)" }
		#expect(nativeKinds == ["paragraph", "listItem 1", "unorderedList"])
		// Native identities mirror the portable ones.
		let nativeIDs = (run?.presentationIntent?.components ?? []).map(\.identity)
		let portableIDs = (run?[SwiftTextMarkdownAttributes.Block.self]?.components ?? []).map(\.identity)
		#expect(nativeIDs == portableIDs)
	}

	@Test func tableNativeIntentCarriesAlignment() {
		let attributed = render("| L | R |\n|:--|--:|\n| a | b |")
		let bodyCell = firstRun(attributed) { $0 == "b" }
		guard case let .table(columns)? = bodyCell?.presentationIntent?.components.last?.kind else {
			Issue.record("missing native table intent"); return
		}
		#expect(columns.map(\.alignment) == [.left, .right])
	}

	@Test func boldMapsToNativeInlineIntent() {
		let attributed = render("a **b**")
		#expect(firstRun(attributed) { $0 == "b" }?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
	}

	@Test func softBreakMapsToNativeInlineIntent() {
		let attributed = render("x\ny")
		#expect(firstRun(attributed) { $0 == " " }?.inlinePresentationIntent?.contains(.softBreak) == true)
	}

	@Test func portableAndNativeAgreeOnBlockPresence() {
		// Every run with a portable block also has a native presentation intent,
		// and vice versa (HTML blocks have neither).
		let attributed = render("# H\n\npara\n\n- item\n\n> quote")
		for run in attributed.runs {
			let hasPortable = run[SwiftTextMarkdownAttributes.Block.self] != nil
			let hasNative = run.presentationIntent != nil
			#expect(hasPortable == hasNative)
		}
	}
}

#endif
