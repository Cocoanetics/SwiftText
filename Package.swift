// swift-tools-version:6.1
import PackageDescription

// macOS-only targets (Vision, PDFKit, AppKit, WebKit)
#if os(Linux)
let macOSProducts: [Product] = []
let macOSTargets: [Target] = []
let swiftTextExtraDeps: [Target.Dependency] = []
let ocrTestDeps: [Target.Dependency] = []
#else
let macOSProducts: [Product] = [
	.library(name: "SwiftTextOCR", targets: ["SwiftTextOCR"]),
	.library(name: "SwiftTextPDF", targets: ["SwiftTextPDF"]),
	.executable(name: "swifttext", targets: ["SwiftTextCLI"]),
]
let macOSTargets: [Target] = [
	.target(
		name: "SwiftTextOCR",
		path: "Sources/SwiftTextOCR"
	),
	.target(
		name: "SwiftTextPDF",
		dependencies: ["SwiftTextOCR"],
		path: "Sources/SwiftTextPDF"
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
		name: "SwiftTextOCRTests",
		dependencies: ["SwiftTextOCR", "SwiftTextPDF"],
		path: "Tests/SwiftTextOCRTests"
	),
]
let swiftTextExtraDeps: [Target.Dependency] = [
	.target(name: "SwiftTextOCR", condition: .when(traits: ["OCR"])),
	.target(name: "SwiftTextPDF", condition: .when(traits: ["PDF"])),
]
let ocrTestDeps: [Target.Dependency] = []
#endif

// libxml2 system library:
//   - On Linux: resolved via pkg-config "libxml-2.0" which provides
//     -I/usr/include/libxml2 and -lxml2.  CHTMLParser depends on CLibXML2
//     so those flags propagate automatically.
//   - On macOS: libxml2 is part of the SDK; link directly with -lxml2.
#if os(Linux)
let cHTMLParserDeps: [Target.Dependency] = [.target(name: "CLibXML2")]
let cHTMLParserLinker: [LinkerSetting] = []
let xmlSystemTargets: [Target] = [
	.systemLibrary(
		name: "CLibXML2",
		pkgConfig: "libxml-2.0",
		providers: [.apt(["libxml2-dev"])]
	),
]
#else
let cHTMLParserDeps: [Target.Dependency] = []
let cHTMLParserLinker: [LinkerSetting] = [.linkedLibrary("xml2")]
let xmlSystemTargets: [Target] = []
#endif

// HTMLParser is cross-platform: libxml2 HTML parsing works fine on Linux.
let htmlProducts: [Product] = [
	.library(name: "SwiftTextHTML", targets: ["SwiftTextHTML"]),
]
let htmlTargets: [Target] = [
	.target(
		name: "CHTMLParser",
		dependencies: cHTMLParserDeps,
		path: "Sources/CHTMLParser",
		publicHeadersPath: "include",
		linkerSettings: cHTMLParserLinker
	),
	.target(
		name: "HTMLParser",
		dependencies: ["CHTMLParser"],
		path: "Sources/HTMLParser"
	),
	.target(
		name: "SwiftTextHTML",
		dependencies: ["HTMLParser", "CHTMLParser"],
		path: "Sources/SwiftTextHTML"
	),
	.testTarget(
		name: "SwiftTextHTMLTests",
		dependencies: ["SwiftTextHTML"],
		path: "Tests/SwiftTextHTMLTests"
	),
] + xmlSystemTargets

let swiftTextHTMLDeps: [Target.Dependency] = [
	.target(name: "SwiftTextHTML", condition: .when(traits: ["HTML"])),
]

let packageProducts: [Product] = [
	.library(
		name: "SwiftText",
		targets: ["SwiftText"]
	),
	.library(
		name: "SwiftTextDOCX",
		targets: ["SwiftTextDOCX"]
	),
] + htmlProducts + macOSProducts

let swiftTextDependencies: [Target.Dependency] = [
	.target(name: "SwiftTextDOCX", condition: .when(traits: ["DOCX"])),
] + swiftTextHTMLDeps + swiftTextExtraDeps

let packageTargets: [Target] = [
	.target(
		name: "SwiftText",
		dependencies: swiftTextDependencies,
		path: "Sources/SwiftText"
	),
	.target(
		name: "SwiftTextDOCX",
		dependencies: [
			.product(name: "ZIPFoundation", package: "ZIPFoundation"),
		],
		path: "Sources/SwiftTextDOCX"
	),
	.testTarget(
		name: "SwiftTextDOCXTests",
		dependencies: ["SwiftTextDOCX"],
		path: "Tests/SwiftTextDOCXTests",
		resources: [
			.process("Resources"),
		]
	),
] + htmlTargets + macOSTargets

let package = Package(
	name: "SwiftText",
	products: packageProducts,
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
	targets: packageTargets
)
