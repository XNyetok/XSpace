# XSpace

Native macOS app (Swift + AppKit + system WebKit) that shows several isolated browser profiles
in one window. Open source (MIT): treat every commit, comment, log and document as public,
even while the GitHub repository is private.

## Layout

- `Sources/XSpace/`: the app (file overview in README.md → Development)
- `Tests/XSpaceTests/`: unit tests
- `Support/`: Info.plist, entitlements, `AppIcon.icns` (drawn by `scripts/make-icon.swift`)
- `scripts/build.sh`: builds and signs `build/XSpace.app`
- `.github/workflows/`: `ci.yml` (macOS 15 and 26), `release.yml` (runs on `v*` tags)

## Ground rules (from CONTRIBUTING.md)

- Isolation: every web view uses its profile's data store through
  `WebKitSupport.makeConfiguration(store:)`, never `WKWebsiteDataStore.default()`. Popups use
  the configuration WebKit passes in, unchanged.
- Stay light: AppKit + system WebKit only, no third-party dependencies.
- Privacy: no telemetry, analytics or remote logging; no JavaScript injected into pages.
- Least privilege: no new sandbox entitlements without a stated reason.
- No personal data (email addresses, account names, cookies, private screenshots) in code,
  tests, docs, logs or commit messages.

## Language

- English: code, comments, identifiers, logs, test output, commit messages, CHANGELOG.
- Indonesian: app UI strings (until localization lands), consistent with the existing ones.
- `README.md` and `README.id.md` describe the same things: update both in the same change.

## Build and test

```bash
swift test                                       # unit tests
XSPACE_WARNINGS_AS_ERRORS=1 ./scripts/build.sh   # app bundle; warnings fail the build, as in CI
APP=build/XSpace.app/Contents/MacOS/XSpace
$APP --selftest && $APP --selftest-persist       # isolation, persistence (in this order)
$APP --selftest-ui                               # opens a window for about 20 seconds
```

- Self-tests use throwaway profiles and never touch real ones. `XSPACE_SELFTEST_OFFLINE=1`
  skips the parts that need the network.
- Run the app bundle that `build.sh` makes. The bare executable in `.build/` runs without the
  sandbox and writes into `~/Library` outside the app's container.
- Keep the signing identity `build.sh` picks. Switching between signed and ad-hoc builds
  (`XSPACE_SIGN_IDENTITY=-`) can make macOS ask for access to the app's data.
- A bug fix gets a unit test, or a self-test check when it needs WebKit, the sandbox or a
  window.

## Changes and commits

- User-visible changes go into `CHANGELOG.md` under "Unreleased" (Keep a Changelog).
- One topic per commit; imperative subject line, and a body that explains why.
- Commit with the address from `git config --local user.email` (chosen for this project). If
  it is unset, ask instead of falling back to the global address.
- Work on a branch and open a pull request. When CI is green, merge by fast-forwarding main
  (`git push origin <branch>:main`; GitHub then marks the PR as merged). Don't use GitHub's
  merge buttons: they create or rewrite commits with the merging account's email.
- Ask before anything outward-facing: pushing, tags, releases, repository settings.

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist` by editing
   those lines (PlistBuddy reorders the whole file).
2. In `CHANGELOG.md`, turn "Unreleased" into `## [x.y.z] - YYYY-MM-DD`, add a new empty
   "Unreleased" section and update the links at the bottom.
3. Commit and merge, then `git tag -a vX.Y.Z -m "XSpace X.Y.Z" && git push origin vX.Y.Z`.
   `release.yml` checks the tag against Info.plist, builds a universal app, runs the self-tests
   and publishes the GitHub release (zip, SHA-256, notes from the CHANGELOG section).

Releases are ad-hoc signed; notarization needs a Developer ID (steps in CONTRIBUTING.md).
Don't move or delete a published tag or release.
