# whalegirl v1.0 public handoff

This is the first public snapshot of the current WhaleGirl implementation. Local development history, machine logs, account state, screenshots of private desktops, temporary workspaces and historical build packages are not part of the public repository.

## Source and runtime

- Swift 6, AppKit and Core Animation; testable pure logic in Packages/WhaleCore.
- Presentation modes remain separate from mood. Sprite manifests keep schemaVersion1 and existing geometry/hitbox rules.
- Runtime art, provenance, licenses, integration scripts and quota helper resources are included.
- Current release limitations are stated in README.md and docs/releases/v1.0.md. Gemini desktop uses authorized Accessibility page reading; Grok Bot live quota remains unavailable. Credentials and raw conversations are not packaged.

## Validation

The previous unchanged functional build passed native settings/quota rendering (2 tests) and quota/integration Core regressions (4 tests) on macOS26.6.2 arm64. This release changes the application version to1.0 and rebuilds from a clean publication directory. The public snapshot passed49 Core tests,16 Python tests, both Node fixtures,2 native UI tests, a Universal Release build, ZIP/signature checks and mounted-DMG validation. Exact checksums and limits are recorded in docs/releases/v1.0.md.

Native component tests, local event replay and fixtures do not establish every provider's real-model E2E behavior. Intel hardware, multimonitor transitions and high pet-count performance remain unverified.

## Rebuild

Use the README xcodebuild and test commands. Original art licenses, source revisions and character credit must be preserved. No machine-specific absolute paths, accounts, credentials or raw prompts belong in future commits or logs.

## Rollback

Quit the app and restore a previously retained installation or archive. User configuration and CSV live separately under Application Support; rollback should preserve those files.
