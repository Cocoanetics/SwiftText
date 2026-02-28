import Foundation
import SwiftTextHTML
import Testing

@Test
func htmlDeepWrapperChainDoesNotCrash() async throws {
	// Build a pathological wrapper chain that would previously risk stack overflow.
	let depth = 400
	var html = "<html><body>"
	for i in 0..<depth {
		html += (i % 2 == 0) ? "<div class=\"w\">" : "<span style=\"color:#000\">"
	}
	html += "Hello ü"
	for i in (0..<depth).reversed() {
		html += (i % 2 == 0) ? "</div>" : "</span>"
	}
	html += "</body></html>"

	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	let md = document.markdown()
	#expect(md.contains("Hello ü"))
}
