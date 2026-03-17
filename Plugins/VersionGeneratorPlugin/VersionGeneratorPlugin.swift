import PackagePlugin
import Foundation

@main
struct VersionGeneratorPlugin: BuildToolPlugin {
	func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
		let outputPath = context.pluginWorkDirectoryURL.appending(path: "GeneratedVersion.swift")

		return [
			.prebuildCommand(
				displayName: "Generate version from git tag",
				executable: .init(filePath: "/bin/sh"),
				arguments: [
					"-c",
					"""
					if [ -f "\(context.package.directoryURL.path())/.version" ]; then
						VERSION=$(cat "\(context.package.directoryURL.path())/.version")
					else
						VERSION=$(git -C "\(context.package.directoryURL.path())" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
					fi
					if [ -z "$VERSION" ]; then VERSION="0.0.0"; fi
					echo '// Auto-generated from git tag or .version file — do not edit' > "\(outputPath.path())"
					echo 'public let swiftTextVersion = "'"$VERSION"'"' >> "\(outputPath.path())"
					"""
				],
				outputFilesDirectory: context.pluginWorkDirectoryURL
			)
		]
	}
}
