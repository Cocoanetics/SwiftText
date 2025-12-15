// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "SwiftText",
	products: [
		.library(
			name: "SwiftTextOCR",
			targets: ["SwiftTextOCR"]
		),
		.executable(
			name: "swifttext",
			targets: ["SwiftTextCLI"]
		),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
	],
	targets: [
		.target(
			name: "SwiftTextOCR",
			path: "Sources/SwiftTextOCR"
		),
		.executableTarget(
			name: "SwiftTextCLI",
			dependencies: [
				"SwiftTextOCR",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			],
			path: "Sources/SwiftTextCLI"
		),
		.testTarget(
			name: "SwiftTextOCRTests",
			dependencies: ["SwiftTextOCR"],
			path: "Tests/SwiftTextOCRTests"
		),
	]
)
