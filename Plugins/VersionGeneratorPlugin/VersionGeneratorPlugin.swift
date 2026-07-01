import PackagePlugin
import Foundation

// Generates `public let swiftTextVersion` for the CLI's `--version`.
//
// The version comes from a committed `.version` file if present, otherwise from
// the latest git tag (`git describe`), otherwise "0.0.0". The plugin is a prebuild
// command, so it runs on the build *host* — macOS, Linux, or Windows.
//
// The same POSIX shell script drives every platform. On macOS/Linux it runs via
// `/bin/sh`. On Windows there is no `/bin/sh`, and the two native alternatives
// don't work here: cmd.exe's quoting mangles the `for /f`/redirect one-liner, and
// PowerShell fails to load inside the SwiftPM plugin sandbox (0x8009001d). Git for
// Windows, however, ships `bash.exe` — a native exe that runs fine in the sandbox
// and understands POSIX quoting — so the Windows branch just points at that with
// the paths in forward-slash (`D:/…`) form. Any failure falls back to "0.0.0", so
// a shallow checkout with no tags never breaks the build.
@main
struct VersionGeneratorPlugin: BuildToolPlugin {
	func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
		let outputURL = context.pluginWorkDirectoryURL.appending(path: "GeneratedVersion.swift")

		#if os(Windows)
		let programFiles = ProcessInfo.processInfo.environment["ProgramFiles"] ?? "C:\\Program Files"
		let executable = URL(filePath: "\(programFiles)\\Git\\bin\\bash.exe")
		let pkg = bashPath(context.package.directoryURL)
		let out = bashPath(outputURL)
		#else
		let executable = URL(filePath: "/bin/sh")
		let pkg = context.package.directoryURL.path()
		let out = outputURL.path()
		#endif

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
/// Converts a file URL to a Git-bash-friendly path: forward slashes and a bare
/// drive letter (`D:/…`), tolerating the `/D:/…`, `D:/…`, and `D:\…` forms
/// Foundation may hand back.
private func bashPath(_ url: URL) -> String {
	var path = url.path().replacingOccurrences(of: "\\", with: "/")
	let chars = Array(path)
	// Strip a leading slash before a drive letter: "/D:/…" -> "D:/…".
	if chars.count >= 3, chars[0] == "/", chars[1].isLetter, chars[2] == ":" {
		path.removeFirst()
	}
	return path
}
#endif
