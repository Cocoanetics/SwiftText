import Foundation
import Testing
@testable import SwiftTextRender
import SwiftTextCSS
import SwiftTextHTML

@Suite("Justification")
struct JustificationTests {
	private static let filler = "der die das und ein Haus Garten Fenster gehen sehr oft wenn schnell langsam Zeit Tisch Wasser"
		.split(separator: " ").map(String.init)

	private static func text(marks: [String]) -> String {
		var words: [String] = []
		for i in 0..<60 {
			var word = filler[(i * 7) % filler.count]
			if i % 9 == 4 { word = "<b>\(word) (Wort)</b>\(marks[(i / 9) % marks.count])" }
			words.append(word)
		}
		return words.joined(separator: " ") + "."
	}

	private func lines(_ body: String, style: String = "text-align: justify", width: Double = 220) async throws -> [LineBox] {
		let html = "<html><body><p style=\"\(style)\">\(body)</p></body></html>"
		let builder = try await DomBuilder(html: Data(html.utf8), baseURL: nil)
		let root = try #require(builder.root)
		let styled = StyledElement.build(domElement: root, resolver: StyleResolver())
		let rootBox = try #require(BoxTreeBuilder.build(from: styled) as? BlockBox)
		LayoutEngine(fonts: FontBook()).layout(root: rootBox, contentWidth: width, originX: 0, originY: 0)
		let paragraph = try #require(firstParagraph(in: rootBox))
		return paragraph.lines
	}

	private func firstParagraph(in box: BlockBox) -> BlockBox? {
		if box.element?.localName == "p" { return box }
		for case let child as BlockBox in box.children {
			if let found = firstParagraph(in: child) { return found }
		}
		return nil
	}

	@Test func punctuationAfterBoldStaysTouching() async throws {
		let result = try await lines(Self.text(marks: [".", ":", ",", ";"]))
		#expect(result.count > 3)
		for line in result.dropLast() {
			// Fragments split by a style change and not by a space touch exactly.
			for (a, b) in zip(line.fragments, line.fragments.dropFirst()) where [".", ":", ",", ";"].contains(String(b.text.prefix(1))) {
				#expect(abs(b.x - (a.x + a.width)) < 0.01)
			}
			let last = try #require(line.fragments.last)
			#expect(abs(last.x + last.width - (line.x + line.width)) < 0.01)
		}
	}

	@Test func stretchGoesOnlyIntoWordSpaces() async throws {
		let result = try await lines(Self.text(marks: [".", ","]))
		for line in result.dropLast() {
			let gaps = zip(line.fragments, line.fragments.dropFirst()).map { $1.x - ($0.x + $0.width) }.filter { $0 > 0.5 }
			if let first = gaps.first { #expect(gaps.allSatisfy { abs($0 - first) < 0.5 }) }
		}
	}

	@Test func midWordEmphasisStaysTouching() async throws {
		let result = try await lines("aaa bbb foo<b>bar</b>baz ccc ddd eee fff ggg hhh iii jjj", width: 120)
		for line in result.dropLast() {
			for (a, b) in zip(line.fragments, line.fragments.dropFirst()) where a.text == "foo" || a.text == "bar" {
				#expect(abs(b.x - (a.x + a.width)) < 0.01)
			}
		}
	}
}
