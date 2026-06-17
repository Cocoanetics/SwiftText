// swift-tools-version:6.1
import PackageDescription

// macOS-only targets (Vision, PDFKit, AppKit, WebKit)
#if !os(macOS)
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
		dependencies: ["SwiftTextMarkdown"],
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
			"SwiftTextPages",
			.product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["CLI"])),
		],
		path: "Sources/SwiftTextCLI",
		plugins: [
			.plugin(name: "VersionGeneratorPlugin")
		]
	),
	.plugin(
		name: "VersionGeneratorPlugin",
		capability: .buildTool()
	),
	.testTarget(
		name: "SwiftTextOCRTests",
		dependencies: [
			"SwiftTextOCR",
			"SwiftTextPDF",
			.product(name: "Markdown", package: "swift-markdown"),
		],
		path: "Tests/SwiftTextOCRTests"
	),
]
let swiftTextExtraDeps: [Target.Dependency] = [
	.target(name: "SwiftTextOCR", condition: .when(traits: ["OCR"])),
	.target(name: "SwiftTextPDF", condition: .when(traits: ["PDF"])),
]
let ocrTestDeps: [Target.Dependency] = []
#endif

// HTML parsing comes from XMLKit's HTMLParser module (libxml2-backed,
// cross-platform — Linux needs libxml2-dev/pkg-config, vcpkg on Windows).
// SwiftTextMarkdown is platform-agnostic (built on swift-cmark), so it ships
// alongside SwiftTextHTML rather than being gated by it.
let htmlProducts: [Product] = [
	.library(name: "SwiftTextHTML", targets: ["SwiftTextHTML"]),
	.library(name: "SwiftTextMarkdown", targets: ["SwiftTextMarkdown"]),
]
let htmlTargets: [Target] = [
	.target(
		name: "SwiftTextHTML",
		dependencies: [
			// Single-trait condition, same reasoning as ZIPFoundation below. HTML
			// must be active wherever SwiftTextHTML compiles; the CLI default trait
			// transitively enables it for plain `swift build`.
			.product(name: "HTMLParser", package: "XMLKit", condition: .when(traits: ["HTML"])),
			"SwiftTextMarkdown",
			// The HTML→Markdown path builds a swift-markdown AST from the DOM and
			// renders it with MarkupFormatter, so it needs the Markdown module
			// directly (not just transitively via SwiftTextMarkdown). swift-markdown
			// is platform-agnostic and always resolved, so this isn't trait-gated.
			.product(name: "Markdown", package: "swift-markdown"),
		],
		path: "Sources/SwiftTextHTML"
	),
	.target(
		name: "SwiftTextMarkdown",
		dependencies: [
			.product(name: "Markdown", package: "swift-markdown"),
		],
		path: "Sources/SwiftTextMarkdown"
	),
	.testTarget(
		name: "SwiftTextHTMLTests",
		dependencies: ["SwiftTextHTML", "SwiftTextMarkdown", "SwiftTextCore"],
		path: "Tests/SwiftTextHTMLTests"
	),
	.testTarget(
		name: "SwiftTextMarkdownTests",
		dependencies: ["SwiftTextMarkdown"],
		path: "Tests/SwiftTextMarkdownTests"
	),
]

let swiftTextHTMLDeps: [Target.Dependency] = [
	.target(name: "SwiftTextHTML", condition: .when(traits: ["HTML"])),
]

let packageProducts: [Product] = [
	.library(
		name: "SwiftText",
		targets: ["SwiftText"]
	),
	.library(
		name: "SwiftTextCore",
		targets: ["SwiftTextCore"]
	),
	.library(
		name: "SwiftTextDOCX",
		targets: ["SwiftTextDOCX"]
	),
	.library(
		name: "SwiftTextPages",
		targets: ["SwiftTextPages"]
	),
	// Cross-platform HTML/CSS → PDF rendering engine (a port of WeasyPrint).
	// SwiftTextPDFWriter is the Foundation-only PDF output substrate (a port of
	// pydyf); it is always available because it has no external dependencies.
	.library(
		name: "SwiftTextPDFWriter",
		targets: ["SwiftTextPDFWriter"]
	),
] + htmlProducts + macOSProducts

let swiftTextDependencies: [Target.Dependency] = [
	.target(name: "SwiftTextDOCX", condition: .when(traits: ["DOCX"])),
	.target(name: "SwiftTextPages", condition: .when(traits: ["PAGES"])),
] + swiftTextHTMLDeps + swiftTextExtraDeps

let packageTargets: [Target] = [
	.target(
		name: "SwiftTextCore",
		path: "Sources/SwiftTextCore"
	),
	.target(
		name: "SwiftText",
		dependencies: swiftTextDependencies,
		path: "Sources/SwiftText"
	),
	.target(
		name: "SwiftTextDOCX",
		dependencies: [
			"SwiftTextMarkdown",
			// Single-trait condition on purpose: Swift 6.2's SwiftPM requires ALL listed
			// traits to be enabled (6.3 changed this to any-of), so an OR-set like
			// ["DOCX", "CLI"] would drop ZIPFoundation on 6.2 toolchains. The CLI case
			// is covered by the CLI trait transitively enabling DOCX instead.
			.product(name: "ZIPFoundation", package: "ZIPFoundation", condition: .when(traits: ["DOCX"])),
			// Shared dependency-free utilities (ImageDimensions). No external product,
			// so no trait condition is needed.
			"SwiftTextCore",
		],
		path: "Sources/SwiftTextDOCX"
	),
	.target(
		name: "SwiftTextPages",
		dependencies: [
			// Same single-trait reasoning as SwiftTextDOCX's ZIPFoundation
			// dependency: Pages files are Zip archives, and the CLI default trait
			// enables PAGES transitively for a plain `swift build`. Snappy and
			// Protocol Buffers decoding are implemented in-target, so ZIPFoundation
			// is the only external dependency.
			.product(name: "ZIPFoundation", package: "ZIPFoundation", condition: .when(traits: ["PAGES"])),
			// Markdown → Pages writing parses with swift-markdown and reuses the
			// shared plain-text helper. Both are platform-agnostic and always
			// resolved (as in SwiftTextDOCX), so they are not trait-gated.
			"SwiftTextMarkdown",
			.product(name: "Markdown", package: "swift-markdown"),
			// Shared dependency-free utilities (ImageDimensions); see SwiftTextDOCX.
			"SwiftTextCore",
		],
		path: "Sources/SwiftTextPages"
	),
	.testTarget(
		name: "SwiftTextDOCXTests",
		dependencies: ["SwiftTextDOCX"],
		path: "Tests/SwiftTextDOCXTests",
		resources: [
			.process("Resources"),
		]
	),
	.testTarget(
		name: "SwiftTextPagesTests",
		dependencies: ["SwiftTextPages"],
		path: "Tests/SwiftTextPagesTests",
		resources: [
			.process("Resources"),
		]
	),
	.testTarget(
		name: "SwiftTextCoreTests",
		dependencies: ["SwiftTextCore"],
		path: "Tests/SwiftTextCoreTests"
	),
	// Cross-platform HTML/CSS → PDF rendering engine (a port of WeasyPrint).
	.target(
		name: "SwiftTextPDFWriter",
		path: "Sources/SwiftTextPDFWriter"
	),
	.testTarget(
		name: "SwiftTextPDFWriterTests",
		dependencies: ["SwiftTextPDFWriter"],
		path: "Tests/SwiftTextPDFWriterTests"
	),
] + htmlTargets + macOSTargets

let package = Package(
	name: "SwiftText",
	platforms: [
		.macOS(.v12),
		.iOS(.v13),
		.tvOS(.v13),
		.watchOS(.v6),
	],
	products: packageProducts,
	traits: [
		.trait(name: "OCR", description: "Image OCR support"),
		.trait(name: "HTML", description: "HTML parsing"),
		.trait(name: "PDF", description: "PDF text extraction", enabledTraits: ["OCR"]),
		.trait(name: "DOCX", description: "DOCX extraction"),
		.trait(name: "PAGES", description: "Pages (iWork) extraction"),
		// CLI enables DOCX, PAGES, and HTML because SwiftTextCLI links
		// SwiftTextDOCX, SwiftTextPages, and SwiftTextHTML, whose external products
		// (ZIPFoundation, XMLKit's HTMLParser) are guarded by those traits.
		.trait(name: "CLI", description: "swifttext command-line tool dependencies", enabledTraits: ["DOCX", "PAGES", "HTML"]),
		// "CLI" must be a default trait: the SwiftTextCLI and SwiftTextDOCX targets are
		// always part of the manifest, so a plain `swift build` needs their external
		// products (ArgumentParser, ZIPFoundation) active to compile. Consumers that
		// specify explicit traits (e.g. ["HTML"]) drop the defaults, which lets SwiftPM
		// prune both packages from their dependency resolution.
		.default(enabledTraits: ["OCR", "CLI"]),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
		.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.12"),
		.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
		.package(url: "https://github.com/Cocoanetics/XMLKit.git", from: "1.0.0"),
	],
	targets: packageTargets
)
