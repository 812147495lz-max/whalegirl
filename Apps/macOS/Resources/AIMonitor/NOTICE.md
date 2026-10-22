# Quota backend attribution

CodexBarCLI and its SwiftPM resource bundles are built from [steipete/CodexBar](https://github.com/steipete/CodexBar) commit `9093308f0b79645f6794c2f28f020d87fe06386b`, MIT, Copyright (c) 2026 Peter Steinberger. Full license and dependency license texts are in `Licenses/`. Provider plugins and Acknowledgements.json remain in the unmodified Core resource bundle.

Build: `swift build -c release --product CodexBarCLI --jobs 2`; strip local symbols, then ad-hoc sign. Requires Apple Silicon and macOS 14+. This is a read-only quota backend, not the CodexBar menu bar app. Background usage commands preserve upstream's no-prompt Keychain policy. Only an explicit “连接浏览器” action requests interactive cookie import. Quota results are filtered to percentages, actual periods, reset dates and fetch timestamps; account identities/history/diagnostic text are discarded.

WhaleGirl's Python wrapper and DSH adapter are original integration code. DSH adapter protocol was checked against deepseek-ai/deepseek-harness commit `687f282e8625c6b8d11ff58211a90524be2e4317` (MIT); no DSH credential or source file is bundled. Credentials remain in the original local account store and are sent only to the original issuer's fixed account-summary endpoint.
