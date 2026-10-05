# Contributing

Use Windows PowerShell 5.1 compatibility and dependency-free modules. Run `scripts/Test.ps1` before submitting a change. Submit a pull request with the problem, resulting behavior, and validation performed.

New selections need a primary source for their behavior, a clear description of the tradeoff, a capability check, an exact original-state backup, read-back verification, Undo, and mocked failure-path tests. Preferences should not be advertised as proven FPS or latency improvements.

Driver offers require the exact supported hardware IDs and Windows architecture/build, an official Microsoft HTTPS package, a pinned SHA-256, Network-class INF validation, catalog signature and membership checks, and tests for incompatible packages. Do not publish machine-specific diagnostic logs, backup snapshots, access tokens, or downloaded driver binaries in source commits.

Use `scripts/Build.ps1` to generate the portable EXE and release checksums. The standalone executable embeds the source modules instead of downloading executable code on launch. Keep version numbers in the entry script, XAML, launcher assembly, and core module manifest consistent when preparing a new release.

Real adapter/registry mutations should be tested only in a controlled environment with a known recovery path. The ordinary automated suites use fake platform providers and temporary files.
