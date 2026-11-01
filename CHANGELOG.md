# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- A welcome screen on the first start: choose a layout, and XSpace makes a profile for each of its
  panes. Nothing loads before you open a page.
- A start page for a pane without a page, like a browser's new tab page: the profile's name and a
  search box. Search Google or type an address there (or in the address bar) and press Return; the
  profile keeps that page.

### Changed
- A new profile shows the start page instead of opening Google AI Studio.
- The last profile can be deleted too: XSpace then shows the welcome screen again.

## [0.6.0] - 2026-11-01

### Added
- Layouts: the **Tata Letak** button arranges the profiles as **Otomatis** (every profile in a
  grid), 1, 2 side by side, 2 stacked, 3 side by side, 2 × 2, 1 + 2 or 1 + 3, for example one
  tall pane on the left and three stacked on the right. Every layout remembers its profiles and
  the sizes of its panes.
- The toolbar highlights the profiles on screen. Clicking another one (or ⌘1–⌘9) shows it in
  the pane you are in. The profile name in a pane lists the profiles to show there; one shown
  elsewhere trades places with it. An empty slot offers the hidden profiles or a new one.

### Changed
- Every profile is now one pane, with one page, instead of two panes (Google AI Studio | Google
  Sheets). Existing profiles keep the page of their first pane; you stay signed in. If you want
  two pages of one account side by side, add a second profile and sign in there too.
- **Fokus / Semua** became the layouts 1 and Otomatis; ⌃⌘G switches between one profile (the one
  you are in) and the layout before. **Tukar Posisi Pane** (⌃⌘X) is in the **Tampilan** menu
  and swaps the pane you are in with the next one; **Atur Ulang Pane ke Default** is gone.
- A new profile fills an empty slot of the layout, or the pane you are in, and opens Google AI
  Studio. The profile commands act on the profile you are in.
- XSpace 0.5.0 can still open the saved state: it shows every profile with one pane.

### Fixed
- A page that is not on screen could take the keyboard focus, for example a sign-in page loading
  in the background that focuses its email field, so typed text went to a page you could not see.
  Now only pages on screen get the focus, and after switching, the first pane shown has it.
- If XSpace cannot read its saved state (`state.json`), for example because the file is damaged,
  it now moves the file aside as `state-unreadable-<date>.json` before starting over. Before, it
  overwrote the file, and the profiles in it could no longer be opened.

## [0.5.0] - 2026-11-01

### Changed
- Deleting a profile removes its data from disk as soon as WebKit lets go of it, usually within a
  few seconds. Before, XSpace retried after 1, 4 and 10 seconds. If WebKit holds on to the data
  for more than 30 seconds, it is deleted at the next launch, as before.

### Removed
- Support for macOS 14 and 15: XSpace now requires macOS 26 or later, and CI and release builds
  run on macOS 26 only. XSpace 0.4.0 remains available for macOS 14 and 15.

## [0.4.0] - 2026-10-31

### Added
- Swap the two panes of a profile with the ⇄ button between them, ⌃⌘X, or **Profil → Tukar
  Posisi Pane**. Pages keep running (nothing reloads), each pane keeps its width, and the new
  order is saved.

### Fixed
- Pane widths went back to equal after a frozen profile was opened again (until the next
  launch).
- The RAM indicator in the toolbar touched the Fokus/Semua switch; they are now apart.

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

[Unreleased]: https://github.com/XNyetok/XSpace/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/XNyetok/XSpace/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/XNyetok/XSpace/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/XNyetok/XSpace/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/XNyetok/XSpace/releases/tag/v0.3.1
