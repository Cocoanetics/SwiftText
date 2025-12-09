# Agent Guidelines

- **Platform Target**: Ship features for iOS 26 and newer; avoid relying on deprecated APIs.
- **Concurrency**: Prefer modern Swift structured concurrency (`async`/`await`, `Task`, actors) over legacy completion handlers whenever possible.
- **Unit Testing**: Use Swift Testing exclusively. Do not introduce or reference XCTest-based tests.
- **Pluralization**: For any text that needs plural-aware output, rely on Swift's `(inflect: true)` syntax—never the manual `parts == 1 ? "part" : "parts"` pattern.  
  - Example: `Text("Missing ^[\(missingCount) part](inflect: true)")`


Testing

- Use `swift test` for BrickCore changes; target specific work with `swift test --filter SomeSuite/yourTest` to iterate quickly.
- When touching only a handful of files, prefer `swift test --filter FileNameTests` or `swift test --filter SuiteName` to avoid running the entire suite.
- For UI or app-level changes, build the SwiftUI target with `xcodebuild -project SwiftLEGO.xcodeproj -scheme SwiftLEGO -destination "platform=iOS Simulator,name=iPad (10th generation),OS=latest"` to match the iOS 26 minimum.
- If you need logs or timing, add `-showBuildTimingSummary` or `-quiet` depending on whether you are triaging failures or doing green runs.
