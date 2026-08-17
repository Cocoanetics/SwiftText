# Agent Guidelines

- **Platform Target**: Minimum deployment targets are **macOS 13 / iOS 15 / tvOS 15 / watchOS 10**, declared package-wide in `Package.swift`. They are forced by swift-archive (the libarchive-backed Zip support), not chosen, and `platforms:` applies to every target — so the pure-Swift modules inherit them too. Don't raise them without a reason: every consumer inherits the floor. Avoid relying on deprecated APIs.
- **Cross-platform**: SwiftText builds on Linux, Windows and Android as well as Apple platforms, and CI covers all of them. Apple-only frameworks (Vision, PDFKit, AppKit, WebKit, `Compression`) belong in macOS-gated targets or behind `#if canImport(…)` — never in the portable core (`SwiftTextCore`, `SwiftTextMarkdown`, `SwiftTextAttributedString`, `SwiftTextPDFWriter`, `SwiftTextOpenType`, `SwiftTextCSS`).
- **Toolchain**: the manifest declares `swift-tools-version:6.3`; older toolchains can't parse it. It relies on 6.3's any-of `.when(traits:)` semantics.
- **Concurrency**: Prefer modern Swift structured concurrency (`async`/`await`, `Task`, actors) over legacy completion handlers whenever possible.
- **Unit Testing**: Use Swift Testing exclusively. Do not introduce or reference XCTest-based tests.
- **Dependencies**: Prefer implementing format internals in-target over adding a package — Snappy, Protocol Buffers, DEFLATE and the stored-Zip writer are all in-house for this reason. Anything unavoidable is gated behind a per-format trait (`DOCX`/`EPUB`/`PAGES`/`HTML`), so a consumer enabling only some traits never resolves it.

## Testing

- This is a pure SwiftPM package — there is no Xcode project. Use `swift test`; target specific work with `swift test --filter SomeSuite/yourTest` to iterate quickly.
- When touching only a handful of files, prefer `swift test --filter FileNameTests` or `swift test --filter SuiteName` to avoid running the entire suite.
- To exercise the Foundation-only subset that the Linux/Windows/Android CI jobs run: `SWIFTTEXT_PORTABLE_ONLY=1 swift test`. Note this rewrites `Package.resolved` down to the portable dependency set, so `git checkout Package.resolved` afterwards or the pruned lockfile gets committed.
- To check that the Apple platform graph still compiles: `xcodebuild build -scheme SwiftText-Package -destination 'generic/platform=iOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO`.
