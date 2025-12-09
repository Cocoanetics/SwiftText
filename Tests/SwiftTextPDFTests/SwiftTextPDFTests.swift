//
//  SwiftTextPDFTests.swift
//  SwiftText
//
//  Created by Oliver Drobnik on 09.12.24.
//

import Foundation
import PDFKit
import Testing

@testable import SwiftTextPDF

struct SwiftTextPDFTests {
	
	@Test func testTextLineAssembly() async throws {
		// Test that fragments are correctly assembled into lines
		let fragment1 = TextFragment(bounds: CGRect(x: 0, y: 0, width: 50, height: 12), string: "Hello")
		let fragment2 = TextFragment(bounds: CGRect(x: 60, y: 0, width: 50, height: 12), string: "World")
		let fragment3 = TextFragment(bounds: CGRect(x: 0, y: 20, width: 100, height: 12), string: "Second line")
		
		let fragments = [fragment1, fragment2, fragment3]
		let lines = fragments.assembledLines()
		
		#expect(lines.count == 2)
		#expect(lines[0].combinedText == "Hello World")
		#expect(lines[1].combinedText == "Second line")
	}
	
	@Test func testTextLineString() async throws {
		// Test conversion of TextLines to string
		let line1 = TextLine(fragments: [TextFragment(bounds: CGRect(x: 0, y: 0, width: 100, height: 12), string: "First line")])
		let line2 = TextLine(fragments: [TextFragment(bounds: CGRect(x: 0, y: 14, width: 100, height: 12), string: "Second line")])
		
		let lines = [line1, line2]
		let result = lines.string()
		
		#expect(result.contains("First line"))
		#expect(result.contains("Second line"))
	}
}



