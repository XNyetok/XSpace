# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
