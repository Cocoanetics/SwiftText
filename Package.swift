// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "SwiftText",
	products: [
		.library(
			name: "SwiftTextPDF",
			targets: ["SwiftTextPDF"]
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
			name: "SwiftTextPDF",
			path: "Sources/SwiftTextPDF"
		),
		.executableTarget(
			name: "SwiftTextCLI",
			dependencies: [
				"SwiftTextPDF",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			],
			path: "Sources/SwiftTextCLI"
		),
		.testTarget(
			name: "SwiftTextPDFTests",
			dependencies: ["SwiftTextPDF"],
			path: "Tests/SwiftTextPDFTests"
		),
	]
)

