import Foundation
import SwiftTextHTML
import Testing

@Test
func htmlPrefersContentInsideHTMLTagOverTrailingSiblings() async throws {
	let html = """
	<html><head><meta charset=\"utf-8\"></head>
	<body>Ok. I'll set that up later today.<div>--OC</div></body></html>
	<br>
	<span>CONFIDENTIALITY NOTICE: should not win</span>
	"""
	let document = try await HTMLDocument(data: Data(html.utf8), baseURL: nil)
	let md = document.markdown()
	#expect(md.contains("Ok. I'll set that up later today."))
	#expect(md.contains("--OC"))
	#expect(!md.contains("CONFIDENTIALITY NOTICE"))
}
