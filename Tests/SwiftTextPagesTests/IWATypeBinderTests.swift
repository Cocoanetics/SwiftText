import Foundation
import Testing
@testable import SwiftTextPages

/// The reflective type-binder recovers app-layer (TP/TN) type numbers without a
/// debugger, by best-fit decode against a real document.
@Suite("IWA type binder")
struct IWATypeBinderTests {
	@Test("derives TP.DocumentArchive (type 10000) from the committed Sample.pages")
	func derivesDocumentArchive() throws {
		let url = try #require(Bundle.module.url(forResource: "Sample", withExtension: "pages"))
		var objects = [IWAObject]()
		for entry in try PagesContainer.entries(at: url, prefix: "Index/", suffix: ".iwa") {
			if let objs = try? IWAArchive.objects(from: entry.data) { objects += objs }
		}
		let bindings = IWATypeBinder.deriveBindings(from: objects, existing: IWATypeRegistry.modeledTypes)
		// The document root is TP.DocumentArchive at persistence type 10000.
		#expect(bindings[10000] == "TP.DocumentArchive")
	}
}
