// swift-tools-version:6.1
import PackageDescription
import Foundation

// When SWIFTTEXT_PORTABLE_ONLY=1, the manifest is trimmed to the pure-Swift,
// Foundation-only targets and their tests — the surface with no libxml2
// (SwiftTextHTML / SwiftTextRender) and no ZIPFoundation (SwiftTextDOCX /
// SwiftTextPages) dependency. This lets CI *run* the portable unit tests on
// platforms where those native dependencies aren't readily available — Windows
// and the Android cross-compile SDK — instead of only build-checking the
// Markdown core. A plain `swift build` / `swift test` is completely unchanged.
let portableOnly = ProcessInfo.processInfo.environment["SWIFTTEXT_PORTABLE_ONLY"] == "1"

// Targets (and their test targets) that depend only on Foundation + swift-markdown.
let portableTargetNames: Set<String> = [
	"SwiftTextCore",
	"SwiftTextMarkdown",
	"SwiftTextAttributedString",
	"SwiftTextPDFWriter",
	"SwiftTextOpenType",
	"SwiftTextCSS",
	"SwiftTextCoreTests",
	"SwiftTextMarkdownTests",
	"SwiftTextAttributedStringTests",
	"SwiftTextPDFWriterTests",
	"SwiftTextOpenTypeTests",
	"SwiftTextCSSTests"
]

// A platform may need to drop a portable target it can't yet link. The Windows
// toolchain provides the AttributedString *API* (it compiles) but doesn't export
// the `_FoundationCollections.BigString` symbols that back its storage, so
// SwiftTextAttributedString fails at link there (swiftlang/swift#88132 — a
// compiler-side fix). Linux and Android link it fine. SWIFTTEXT_PORTABLE_EXCLUDE
// is a comma-separated list of target/test/product names to drop from the subset.
let portableExclude = Set(
	(ProcessInfo.processInfo.environment["SWIFTTEXT_PORTABLE_EXCLUDE"] ?? "")
		.split(separator: ",")
		.map { $0.trimmingCharacters(in: .whitespaces) }
		.filter { !$0.isEmpty }
)
let effectivePortableNames = portableTargetNames.subtracting(portableExclude)

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
	.executable(name: "swifttext", targets: ["SwiftTextCLI"])
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
			"SwiftTextNumbers",
			"SwiftTextKeynote",
			"SwiftTextRender",
			.product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["CLI"]))
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
			.product(name: "Markdown", package: "swift-markdown")
		],
		path: "Tests/SwiftTextOCRTests"
	)
]
let swiftTextExtraDeps: [Target.Dependency] = [
	.target(name: "SwiftTextOCR", condition: .when(traits: ["OCR"])),
	.target(name: "SwiftTextPDF", condition: .when(traits: ["PDF"]))
]
let ocrTestDeps: [Target.Dependency] = []
#endif

// HTML parsing comes from XMLKit's HTMLParser module (libxml2-backed,
// cross-platform — Linux needs libxml2-dev/pkg-config, vcpkg on Windows).
// SwiftTextMarkdown is platform-agnostic (built on swift-cmark), so it ships
// alongside SwiftTextHTML rather than being gated by it.
// SwiftTextAttributedString (Markdown → portable AttributedText) is likewise
// platform-agnostic and always available — its NSAttributedString bridge is
// gated internally by `#if canImport(UIKit)/AppKit`.
let htmlProducts: [Product] = [
	.library(name: "SwiftTextHTML", targets: ["SwiftTextHTML"]),
	.library(name: "SwiftTextMarkdown", targets: ["SwiftTextMarkdown"]),
	.library(name: "SwiftTextAttributedString", targets: ["SwiftTextAttributedString"])
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
			.product(name: "Markdown", package: "swift-markdown")
		],
		path: "Sources/SwiftTextHTML"
	),
	.target(
		name: "SwiftTextMarkdown",
		dependencies: [
			.product(name: "Markdown", package: "swift-markdown")
		],
		path: "Sources/SwiftTextMarkdown"
	),
	.target(
		name: "SwiftTextAttributedString",
		dependencies: [
			"SwiftTextMarkdown",
			.product(name: "Markdown", package: "swift-markdown")
		],
		path: "Sources/SwiftTextAttributedString"
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
	.testTarget(
		name: "SwiftTextAttributedStringTests",
		dependencies: ["SwiftTextAttributedString"],
		path: "Tests/SwiftTextAttributedStringTests"
	)
]

let swiftTextHTMLDeps: [Target.Dependency] = [
	.target(name: "SwiftTextHTML", condition: .when(traits: ["HTML"]))
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
	// Shared iWork (IWA) read core: Snappy, Protobuf, the .iwa container/object
	// store, and the TST table decoder — the foundation both SwiftTextPages and
	// SwiftTextNumbers build on.
	.library(
		name: "SwiftTextIWA",
		targets: ["SwiftTextIWA"]
	),
	.library(
		name: "SwiftTextNumbers",
		targets: ["SwiftTextNumbers"]
	),
	.library(
		name: "SwiftTextKeynote",
		targets: ["SwiftTextKeynote"]
	),
	// Cross-platform HTML/CSS → PDF rendering engine (a port of WeasyPrint).
	// SwiftTextPDFWriter is the Foundation-only PDF output substrate (a port of
	// pydyf); it is always available because it has no external dependencies.
	.library(
		name: "SwiftTextPDFWriter",
		targets: ["SwiftTextPDFWriter"]
	),
	// Pure-Swift OpenType/TrueType reader (font metrics + embeddable bytes),
	// the replacement for fontconfig/HarfBuzz. Foundation-only, always available.
	.library(
		name: "SwiftTextOpenType",
		targets: ["SwiftTextOpenType"]
	),
	// CSS Syntax Level 3 tokenizer + parser (a port of tinycss2).
	// Foundation-only, always available.
	.library(
		name: "SwiftTextCSS",
		targets: ["SwiftTextCSS"]
	),
	// The cross-platform HTML/CSS → PDF rendering engine itself: box tree,
	// layout, and drawing over the CSS/OpenType/PDF-writer foundations.
	.library(
		name: "SwiftTextRender",
		targets: ["SwiftTextRender"]
	)
] + htmlProducts + macOSProducts

let swiftTextDependencies: [Target.Dependency] = [
	.target(name: "SwiftTextDOCX", condition: .when(traits: ["DOCX"])),
	.target(name: "SwiftTextPages", condition: .when(traits: ["PAGES"])),
	// Platform-agnostic and dependency-light, so always linked (not trait-gated).
	"SwiftTextAttributedString"
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
			"SwiftTextCore"
		],
		path: "Sources/SwiftTextDOCX"
	),
	// Shared iWork (IWA) read core. Snappy and Protocol Buffers decoding are
	// implemented in-target; ZIPFoundation (the .iwa container is a Zip archive)
	// is the only external dependency, gated by PAGES with the same single-trait
	// reasoning as SwiftTextDOCX — the CLI default trait enables PAGES transitively.
	.target(
		name: "SwiftTextIWA",
		dependencies: [
			.product(name: "ZIPFoundation", package: "ZIPFoundation", condition: .when(traits: ["PAGES"]))
		],
		path: "Sources/SwiftTextIWA"
	),
	.target(
		name: "SwiftTextPages",
		dependencies: [
			// The shared IWA read core (Snappy/Protobuf/container/object store/TST
			// table decoder), which also carries the ZIPFoundation dependency.
			"SwiftTextIWA",
			// Markdown → Pages writing parses with swift-markdown and reuses the
			// shared plain-text helper. Both are platform-agnostic and always
			// resolved (as in SwiftTextDOCX), so they are not trait-gated.
			"SwiftTextMarkdown",
			.product(name: "Markdown", package: "swift-markdown"),
			// Shared dependency-free utilities (ImageDimensions); see SwiftTextDOCX.
			"SwiftTextCore"
		],
		path: "Sources/SwiftTextPages"
	),
	// Apple Numbers reader: sheets of tables to Markdown/HTML/JSON/TSV. Reuses the
	// IWA core and the shared TST table decoder; no Pages dependency.
	.target(
		name: "SwiftTextNumbers",
		dependencies: ["SwiftTextIWA"],
		path: "Sources/SwiftTextNumbers"
	),
	// Apple Keynote reader: deck slide text (title/body/notes) to Markdown/JSON/text.
	// Navigates the slide graph structurally via the IWA core; no Pages dependency.
	.target(
		name: "SwiftTextKeynote",
		dependencies: ["SwiftTextIWA"],
		path: "Sources/SwiftTextKeynote"
	),
	.testTarget(
		name: "SwiftTextDOCXTests",
		dependencies: ["SwiftTextDOCX"],
		path: "Tests/SwiftTextDOCXTests",
		resources: [
			.process("Resources")
		]
	),
	.testTarget(
		name: "SwiftTextPagesTests",
		dependencies: ["SwiftTextPages", "SwiftTextIWA"],
		path: "Tests/SwiftTextPagesTests",
		resources: [
			.process("Resources")
		]
	),
	.testTarget(
		name: "SwiftTextNumbersTests",
		dependencies: ["SwiftTextNumbers", "SwiftTextIWA"],
		path: "Tests/SwiftTextNumbersTests",
		resources: [
			.process("Resources")
		]
	),
	.testTarget(
		name: "SwiftTextKeynoteTests",
		dependencies: ["SwiftTextKeynote", "SwiftTextIWA"],
		path: "Tests/SwiftTextKeynoteTests",
		resources: [
			.process("Resources")
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
	.target(
		name: "SwiftTextOpenType",
		path: "Sources/SwiftTextOpenType"
	),
	.testTarget(
		name: "SwiftTextOpenTypeTests",
		dependencies: ["SwiftTextOpenType"],
		path: "Tests/SwiftTextOpenTypeTests"
	),
	.target(
		name: "SwiftTextCSS",
		path: "Sources/SwiftTextCSS"
	),
	.testTarget(
		name: "SwiftTextCSSTests",
		dependencies: ["SwiftTextCSS"],
		path: "Tests/SwiftTextCSSTests"
	),
	// The rendering engine. Depends on SwiftTextHTML (the libxml2-backed DOM,
	// like SwiftTextCLI) plus the cross-platform CSS/OpenType/PDF foundations.
	.target(
		name: "SwiftTextRender",
		dependencies: [
			"SwiftTextHTML",
			"SwiftTextCSS",
			"SwiftTextOpenType",
			"SwiftTextPDFWriter"
		],
		path: "Sources/SwiftTextRender"
	),
	.testTarget(
		name: "SwiftTextRenderTests",
		dependencies: ["SwiftTextRender", "SwiftTextHTML", "SwiftTextCSS"],
		path: "Tests/SwiftTextRenderTests"
	)
] + htmlTargets + macOSTargets

let allTraits: Set<Trait> = [
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
	.default(enabledTraits: ["OCR", "CLI"])
]

let allDependencies: [Package.Dependency] = [
	.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
	.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.12"),
	.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
	.package(url: "https://github.com/Cocoanetics/XMLKit.git", from: "1.0.0")
]

// The portable subset needs only swift-markdown; dropping the others keeps the
// dependency graph clean on platforms without libxml2 / ZIPFoundation toolchains.
let portableDependencies: [Package.Dependency] = [
	.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
]

let package = Package(
	name: "SwiftText",
	platforms: [
		.macOS(.v12),
		.iOS(.v13),
		.tvOS(.v13),
		.watchOS(.v6)
	],
	products: portableOnly ? packageProducts.filter { effectivePortableNames.contains($0.name) } : packageProducts,
	traits: portableOnly ? [] : allTraits,
	dependencies: portableOnly ? portableDependencies : allDependencies,
	targets: portableOnly ? packageTargets.filter { effectivePortableNames.contains($0.name) } : packageTargets
)
