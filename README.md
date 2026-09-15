# Harbor

Native macOS menubar app for observing listening ports and managing local dev servers.

## Status

Empty repository scaffold. Implementation tasks and acceptance criteria are in the project plan / `docs/ACCEPTANCE.md`.

## Planned stack

- Swift 5.10+ / SwiftUI
- macOS 13.0+
- XcodeGen

## Build (once implemented)

```bash
xcodegen generate
xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Debug build
```

## Config

Projects are defined with `harbor.toml` in the project root. See `fixtures/sample-harbor.toml` for an example.
