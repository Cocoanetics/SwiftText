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
		// cmd.exe batch is too fragile for paths (a trailing `\` before a quote
		// escapes it). Use PowerShell driven by a base64 `-EncodedCommand`, which
		// sidesteps all shell quoting. The script always writes the file and exits 0,
		// so a shallow checkout with no tags degrades to "0.0.0" rather than failing.
		let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
		let executable = URL(filePath: "\(root)\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
		let pkg = windowsPath(context.package.directoryURL)
		let out = windowsPath(outputURL)
		let psScript = """
		$ErrorActionPreference = 'SilentlyContinue'
		$pkg = '\(pkg)'
		$out = '\(out)'
		$v = '0.0.0'
		try {
		  $verFile = Join-Path $pkg '.version'
		  if (Test-Path $verFile) {
		    $t = (Get-Content -Raw $verFile).Trim()
		    if ($t) { $v = $t }
		  } else {
		    $t = (& git -C $pkg describe --tags --abbrev=0 2>$null | Out-String).Trim()
		    if ($t) { $v = ($t -replace '^v','') }
		  }
		} catch { }
		Set-Content -Path $out -Encoding utf8 -Value ('// Auto-generated from git tag or .version file - do not edit' + [Environment]::NewLine + 'public let swiftTextVersion = "' + $v + '"')
		exit 0
		"""
		let encoded = (psScript.data(using: .utf16LittleEndian) ?? Data()).base64EncodedString()
		let arguments = ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded]
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
/// Converts a file URL to a native Windows path (backslashes, no leading slash,
/// no trailing slash), tolerating the `/C:/…` and `C:/…` forms Foundation may
/// hand back for a directory URL.
private func windowsPath(_ url: URL) -> String {
	var path = url.path()
	if path.hasPrefix("/") { path.removeFirst() }
	path = path.replacingOccurrences(of: "/", with: "\\")
	while path.hasSuffix("\\") { path.removeLast() }
	return path
}
#endif
