import PackagePlugin
import Foundation

// Generates `public let swiftTextVersion` for the CLI's `--version`.
//
// The version comes from a committed `.version` file if present, otherwise from
// the latest git tag (`git describe`), otherwise "0.0.0". The plugin is a prebuild
// command, so it runs on the build *host* — which may be macOS, Linux, or Windows.
// POSIX hosts drive the logic through `/bin/sh`; Windows has no `/bin/sh`, so it
// runs the equivalent through `cmd.exe` instead. Any failure falls back to
// "0.0.0" so a missing git checkout never breaks the build.
@main
struct VersionGeneratorPlugin: BuildToolPlugin {
	func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
		let outputURL = context.pluginWorkDirectoryURL.appending(path: "GeneratedVersion.swift")

		#if os(Windows)
		let executable = URL(filePath: windowsCmdPath())
		let pkg = windowsPath(context.package.directoryURL)
		let out = windowsPath(outputURL)
		// One-liner cmd script with delayed expansion (/v:on): prefer `.version`,
		// then the latest git tag, then "0.0.0"; write the two-line Swift source.
		let script = """
		set "VER=" & \
		if exist "\(pkg)\\.version" ( set /p VER=<"\(pkg)\\.version" ) \
		else ( for /f "usebackq delims=" %A in (`git -C "\(pkg)" describe --tags --abbrev=0 2^>nul`) do set "VER=%A" ) & \
		if not defined VER set "VER=0.0.0" & \
		> "\(out)" echo // Auto-generated from git tag or .version file - do not edit & \
		>> "\(out)" echo public let swiftTextVersion = "!VER!"
		"""
		let arguments = ["/v:on", "/c", script]
		#else
		let executable = URL(filePath: "/bin/sh")
		let pkg = context.package.directoryURL.path()
		let out = outputURL.path()
		let arguments = [
			"-c",
			"""
			if [ -f "\(pkg)/.version" ]; then
				VERSION=$(cat "\(pkg)/.version")
			else
				VERSION=$(git -C "\(pkg)" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
			fi
			if [ -z "$VERSION" ]; then VERSION="0.0.0"; fi
			echo '// Auto-generated from git tag or .version file — do not edit' > "\(out)"
			echo 'public let swiftTextVersion = "'"$VERSION"'"' >> "\(out)"
			"""
		]
		#endif

		return [
			.prebuildCommand(
				displayName: "Generate version from git tag",
				executable: executable,
				arguments: arguments,
				outputFilesDirectory: context.pluginWorkDirectoryURL
			)
		]
	}
}

#if os(Windows)
/// Resolves cmd.exe via %SystemRoot% (falls back to the conventional location).
private func windowsCmdPath() -> String {
	let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
	return "\(root)\\System32\\cmd.exe"
}

/// Converts a file URL to a native Windows path (backslashes, no leading slash),
/// tolerating the `/C:/…` and `C:/…` forms Foundation may hand back.
private func windowsPath(_ url: URL) -> String {
	var path = url.path()
	if path.hasPrefix("/") { path.removeFirst() }
	return path.replacingOccurrences(of: "/", with: "\\")
}
#endif
