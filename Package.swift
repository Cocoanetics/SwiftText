// swift-tools-version:6.1
import PackageDescription

let package = Package(
	name: "SwiftText",
	products: [
		.library(
			name: "SwiftText",
			targets: ["SwiftText"]
		),
		.library(
			name: "SwiftTextHTML",
			targets: ["SwiftTextHTML"]
		),
		.library(
			name: "SwiftTextOCR",
			targets: ["SwiftTextOCR"]
		),
		.library(
			name: "SwiftTextPDF",
			targets: ["SwiftTextPDF"]
		),
		.library(
			name: "SwiftTextDOCX",
			targets: ["SwiftTextDOCX"]
		),
		.executable(
			name: "swifttext",
			targets: ["SwiftTextCLI"]
		),
	],
	traits: [
		.trait(name: "OCR", description: "Image OCR support"),
		.trait(name: "HTML", description: "HTML parsing"),
		.trait(name: "PDF", description: "PDF text extraction", enabledTraits: ["OCR"]),
		.trait(name: "DOCX", description: "DOCX extraction"),
		.default(enabledTraits: ["OCR"]),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
		.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.12"),
	],
	targets: [
		.target(
			name: "SwiftText",
			dependencies: [
				.target(name: "SwiftTextHTML", condition: .when(traits: ["HTML"])),
				.target(name: "SwiftTextOCR", condition: .when(traits: ["OCR"])),
				.target(name: "SwiftTextPDF", condition: .when(traits: ["PDF"])),
				.target(name: "SwiftTextDOCX", condition: .when(traits: ["DOCX"])),
			],
			path: "Sources/SwiftText"
		),
		.target(
			name: "SwiftTextHTML",
			dependencies: ["HTMLParser", "CHTMLParser"],
			path: "Sources/SwiftTextHTML"
		),
		.target(
			name: "HTMLParser",
			dependencies: ["CHTMLParser"],
			path: "Sources/HTMLParser"
		),
		.target(
			name: "CHTMLParser",
			dependencies: {
				#if os(Linux)
				return [.systemLibrary(name: "libxml2", pkgConfig: "libxml-2.0", providers: [
					.apt(["libxml2-dev"]),
					.brew(["libxml2"])
				])]
				#else
				return []
				#endif
			}(),
			path: "Sources/CHTMLParser",
			publicHeadersPath: "include",
			linkerSettings: [
				.linkedLibrary("xml2")
			]
		),
		.target(
			name: "SwiftTextOCR",
			path: "Sources/SwiftTextOCR"
		),
		.target(
			name: "SwiftTextPDF",
			dependencies: ["SwiftTextOCR"],
			path: "Sources/SwiftTextPDF"
		),
		.target(
			name: "SwiftTextDOCX",
			dependencies: [
				.product(name: "ZIPFoundation", package: "ZIPFoundation"),
			],
			path: "Sources/SwiftTextDOCX"
		),
		.executableTarget(
			name: "SwiftTextCLI",
			dependencies: [
				"SwiftTextHTML",
				"SwiftTextOCR",
				"SwiftTextPDF",
				"SwiftTextDOCX",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			],
			path: "Sources/SwiftTextCLI"
		),
		.testTarget(
			name: "SwiftTextHTMLTests",
			dependencies: ["SwiftTextHTML"],
			path: "Tests/SwiftTextHTMLTests"
		),
		.testTarget(
			name: "SwiftTextOCRTests",
			dependencies: ["SwiftTextOCR", "SwiftTextPDF"],
			path: "Tests/SwiftTextOCRTests"
		),
		.testTarget(
			name: "SwiftTextDOCXTests",
			dependencies: ["SwiftTextDOCX"],
			path: "Tests/SwiftTextDOCXTests",
			resources: [
				.process("Resources"),
			]
		),
	]
)
