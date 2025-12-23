// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "SwiftText",
	products: [
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
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
		.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.12"),
	],
	targets: [
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
