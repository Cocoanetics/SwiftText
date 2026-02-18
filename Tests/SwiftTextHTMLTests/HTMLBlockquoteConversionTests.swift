import Foundation
import SwiftTextHTML
import Testing

@Test
func markdownRendersBlockquotesWithNestedLevels() async throws {
	let html = """
	<html>
	<body>
		<blockquote>
			<h4>Quarterly performance exceeded plan</h4>
			<ul>
				<li>Revenue climbed sharply.</li>
				<li>Margins expanded again.</li>
			</ul>
			<p><em>Everything</em> is proceeding as <strong>planned</strong>.</p>
		</blockquote>
		<blockquote>
			<p>Dorothy crossed several halls in the castle.</p>
			<blockquote>
				<p>The Witch told her to scrub the kettles and keep the fire going.</p>
			</blockquote>
		</blockquote>
	</body>
	</html>
	"""

	let document = try await HTMLDocument(data: Data(html.utf8))
	let markdown = document.markdown()
	let expected = """
	> #### Quarterly performance exceeded plan
	>
	> - Revenue climbed sharply.
	> - Margins expanded again.
	>
	> *Everything* is proceeding as **planned**.
	
	> Dorothy crossed several halls in the castle.
	>
	>> The Witch told her to scrub the kettles and keep the fire going.
	"""

	#expect(markdown == expected)
}
