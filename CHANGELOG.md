# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.1] - 2026-10-31

### Added
- App icon.
- Releases: pushing a version tag builds a universal app (Apple silicon and Intel), runs the
  self-tests and publishes it on GitHub Releases with a SHA-256 checksum. Release builds are
  ad-hoc signed and not notarized yet.
- `scripts/build.sh --universal`, and `XSPACE_WARNINGS_AS_ERRORS=1` to fail on compiler warnings.
- Unit tests (`swift test`) for the address bar, the saved state (including the v0.1 format),
  the pane splitter, download file names, the error page and the web view configuration.

### Changed
- Cookies are flushed to disk when the app quits, as a safeguard for sessions created moments
  before quitting (usually instant, at most 2 s). The quit sequence does not depend on Swift
  Tasks or the main queue, so it cannot hang.
- File names that a website suggests for a download are reduced to a plain file name, so a
  download always lands directly in Downloads.
- `scripts/build.sh` signs with a secure timestamp when it uses a Developer ID identity, as
  notarization requires.
- CI runs on macOS 15 and macOS 26 (GitHub retired its macOS 14 runners), treats compiler
  warnings as errors, and also runs the unit tests and the UI self-test.

### Fixed
- Typing `localhost:3000` or an IP address in the address bar opens it over http, like Safari
  does, instead of https (which local servers rarely support).
- A corrupted color index in the saved state can no longer crash the app.
- The UI self-test skipped its check for a hidden pane whose page process died when it ran
  inside the App Sandbox (where it may not kill that process). It now simulates the crash
  there, and also checks that the pane reloads once it is shown again.
- Persistence self-test on macOS 15: WebKit loads a profile's saved cookies lazily, on the
  first page that uses the profile, so the cookie store API looked empty right after launch.
  The test now checks cookies the way pages see them. Cookies were not actually being lost;
  this was the cause of the first CI failures.

## [0.3.0] - 2026-10-31

### Added
- App Sandbox and Hardened Runtime. `scripts/build.sh` signs with an Apple Development or
  Developer ID identity when available, otherwise ad-hoc.
- Open-source project files: MIT license, contributing guide, code of conduct, security policy,
  issue and pull request templates, CI workflow.
- `XSPACE_SELFTEST_OFFLINE=1` to run the self-tests without network access.

### Changed
- Bundle identifier is now `io.github.xnyetok.xspace`. Data lives in the sandbox container, so
  profiles start fresh and need to sign in again after upgrading from 0.2.
- Inside the sandbox the RAM indicator falls back to the resident size of WebKit processes and
  marks the total as approximate (≈).
- Code comments, build output and self-test output are in English.

## [0.2.0] - 2026-10-31

### Added
- Automatic freezing of hidden profiles: after 15 minutes off screen (default), immediately,
  only on memory pressure, or never.
- RAM indicator in the toolbar with a per-profile breakdown.
- UI self-test (`--selftest-ui`).

### Changed
- A hidden pane whose page process died is reloaded only when it becomes visible again.

## [0.1.0] - 2026-10-31

### Added
- First prototype: isolated profiles, AI Studio | Sheets panes, Focus and All modes, resizable
  panes, popups that stay in their profile, downloads, uploads, camera/microphone prompts.
- Self-tests for profile isolation and persistence.

[Unreleased]: https://github.com/XNyetok/XSpace/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/XNyetok/XSpace/releases/tag/v0.3.1
