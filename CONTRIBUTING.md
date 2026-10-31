# Contributing to XSpace

Thanks for helping! Issues and pull requests are welcome in **English or Bahasa Indonesia**.

## Ground rules

These keep XSpace what it is. Changes that break them are unlikely to be merged.

1. **Isolation is sacred.** Every web view must use its profile's own data store
   (`WebKitSupport.makeConfiguration(store:)`). Never use `WKWebsiteDataStore.default()`.
   Popups must use the `WKWebViewConfiguration` WebKit passes to
   `webView(_:createWebViewWith:for:windowFeatures:)`, unchanged.
2. **Stay light.** Native AppKit + system WebKit only: no Electron, no bundled browser engine,
   no heavy dependencies. Prefer freeing memory over keeping things alive "just in case".
3. **Privacy first.** No telemetry, analytics or remote logging. No JavaScript injected into
   pages unless a feature truly needs it and the PR explains why.
4. **Least privilege.** Do not add sandbox entitlements without a clear reason in the PR.

## Development setup

- macOS 14 or later, Xcode 16 or later.
- Build and run:

  ```bash
  ./scripts/build.sh && open build/XSpace.app
  ```

- You can edit the code in Xcode with `open Package.swift`, but run the app through
  `scripts/build.sh`: it creates the `.app` bundle (Info.plist, sandbox entitlements,
  signature). Running the bare executable from Xcode skips the bundle and the sandbox.
- A free *Apple Development* certificate gives a stable signature, so macOS does not ask for
  confirmation after every rebuild. Without one, `build.sh` falls back to ad-hoc signing.

## Tests

Run these before opening a pull request:

```bash
APP=build/XSpace.app/Contents/MacOS/XSpace
$APP --selftest && $APP --selftest-persist   # isolation, User-Agent, persistence
$APP --selftest-ui                           # freezing + RAM indicator (opens a window briefly)
```

They use throwaway profiles and never touch your own. CI runs the first two with
`XSPACE_SELFTEST_OFFLINE=1`. If you fix a bug, add a check to the relevant self-test when it is
practical.

## Code style

- Swift 5 language mode, AppKit, 4-space indentation, no warnings.
- Comments, identifiers, logs and test output in English.
- The UI is currently in Indonesian. Until localization lands, keep new UI strings in
  Indonesian and consistent with the existing ones (adding localization is a welcome
  contribution of its own).
- Keep types small and focused; follow the existing file layout described in the README.

## Pull requests

- One topic per pull request; describe what changed, why, and how you tested it.
- Update `CHANGELOG.md` (under "Unreleased") for user-visible changes.
- Screenshots are welcome for UI changes, but **never include personal data** (email
  addresses, account names, private documents).

## Security issues

Please do not open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
