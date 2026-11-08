import Testing
@testable import SwiftTextMarkdown

@Suite("smart punctuation")
struct SmartPunctuationTests {
	@Test("the issue's repro")
	func repro() {
		#expect(SmartPunctuation.apply(to: "Parkinson's disease -- \"a quote\" -- Alzheimer's...")
			== "Parkinson\u{2019}s disease \u{2013} \u{201C}a quote\u{201D} \u{2013} Alzheimer\u{2019}s\u{2026}")
	}

	@Test("no-break space after abbreviations")
	func abbreviations() {
		let text = "Frau Dr. Sturm und Prof. Huber, Nr. 3, z. B. so."
		#expect(SmartPunctuation.apply(to: text, language: "de")
			== "Frau Dr.\u{00A0}Sturm und Prof.\u{00A0}Huber, Nr.\u{00A0}3, z. B. so.")
		// Nr. is a German abbreviation only; whole words only; end of line keeps its text.
		#expect(SmartPunctuation.apply(to: "Nr. 3", language: "de-AT") == "Nr.\u{00A0}3")
		#expect(SmartPunctuation.apply(to: "Nr. 3", language: "den") == "Nr. 3")
		#expect(SmartPunctuation.apply(to: "Dr. Sturm, Nr. 3") == "Dr.\u{00A0}Sturm, Nr. 3")
		#expect(SmartPunctuation.apply(to: "See e.g. this, cf. that; the cap. Next Dipl.-Ing. X", language: "de")
			== "See e.g.\u{00A0}this, cf.\u{00A0}that; the cap. Next Dipl.-Ing.\u{00A0}X")
		#expect(SmartPunctuation.apply(to: "Ask Mr. Smith.\nThen Dr.") == "Ask Mr.\u{00A0}Smith.\nThen Dr.")
		#expect(SmartPunctuation.apply(to: "`Dr. X` Dr. Y") == "`Dr. X` Dr.\u{00A0}Y")
	}

	@Test("em dash and nested quotes")
	func dashesAndNesting() {
		#expect(SmartPunctuation.apply(to: "a---b He said \"'Hi'\" ('90s)")
			== "a\u{2014}b He said \u{201C}\u{2018}Hi\u{2019}\u{201D} (\u{2019}90s)")
	}

	@Test("quote style follows the language")
	func languages() {
		#expect(SmartPunctuation.apply(to: "\"Wort\"", language: "de-AT") == "\u{201E}Wort\u{201C}")
		#expect(SmartPunctuation.apply(to: "\"mot\"", language: "fr") == "\u{00AB}mot\u{00BB}")
	}

	@Test("an apostrophe after a word-final s is U+2019 in German too")
	func trailingApostrophe() {
		#expect(SmartPunctuation.apply(to: "Practitioners' impressions and the grandparents' views; it's Parkinson's. 'Zitat' hier.", language: "de")
			== "Practitioners\u{2019} impressions and the grandparents\u{2019} views; it\u{2019}s Parkinson\u{2019}s. \u{201A}Zitat\u{2018} hier.")
		#expect(SmartPunctuation.apply(to: "the dogs' bowls", language: "en") == "the dogs\u{2019} bowls")
	}

	@Test("a possessive inside a single-quoted phrase keeps the quote open")
	func possessiveInsideQuote() {
		#expect(SmartPunctuation.apply(to: "He called it 'the parents' room'", language: "de")
			== "He called it \u{201A}the parents\u{2019} room\u{2018}")
	}

	@Test("a single quote spanning hard-wrapped lines still closes")
	func quoteAcrossLines() {
		#expect(SmartPunctuation.apply(to: "He called it 'the big\nidea' yesterday", language: "de")
			== "He called it \u{201A}the big\nidea\u{2018} yesterday")
	}

	@Test("code, URLs, markers, html and link destinations are untouched")
	func leftAlone() {
		let kept = [
			"`it's -- \"x\"...`",
			"``a ` \"b\"``",
			"see https://example.com/it's--here ok",
			"[^a'b] and [12] and <span title=\"x\">",
			"[link](http://x.y/a \"title\") ",
			"\\\"escaped\\\"",
			"```\nit's \"code\" --\n```",
			"    \"indented\"",
			"---\ntitle: \"It's\"\n---",
			"| a | b |\n|---|---|",
			"[ref]: http://x.y \"Title\"",
			"<!--\nit's\n-->",
			"<script>let x = \"a--b\";</script>",
			"> ```\n> \"code\" --\n> ```",
			"`code\n\"literal\" --` end",
			"1. Run:\n\n    ~~~\n    echo \"a\" -- b\n\n    echo \"c\"\n    ~~~",
			"see [Bob's page] and [here][Bob's page]\n\n[Bob's page]: http://x.y",
			"## Part one {#part--one}",
			"## Pros -- cons"
		]
		for text in kept {
			#expect(SmartPunctuation.apply(to: text) == text, "\(text)")
		}
	}

	@Test("footnote definitions and list items are converted")
	func proseBlocks() {
		#expect(SmartPunctuation.apply(to: "[^1]: Smith's \"note\"") == "[^1]: Smith\u{2019}s \u{201C}note\u{201D}")
		#expect(SmartPunctuation.apply(to: "- it's\n\n    still item's text") == "- it\u{2019}s\n\n    still item\u{2019}s text")
	}

	@Test("a leading thematic break without a closing delimiter is not front matter")
	func notFrontMatter() {
		#expect(SmartPunctuation.apply(to: "---\nit's") == "---\nit\u{2019}s")
	}

	@Test("text around a multi-line code span is converted")
	func multilineSpan() {
		#expect(SmartPunctuation.apply(to: "a's `x\ny` b's") == "a\u{2019}s `x\ny` b\u{2019}s")
	}

	@Test("existing typographic characters survive")
	func nonASCII() {
		let text = "\u{2014} \u{2026} \u{201C}x\u{201D} \u{2019}"
		#expect(SmartPunctuation.apply(to: text) == text)
	}
}
