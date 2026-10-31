## What does this change?

## Why?

## How was it tested?

- [ ] `swift test` passes
- [ ] `XSPACE_WARNINGS_AS_ERRORS=1 ./scripts/build.sh` builds (no warnings)
- [ ] `XSpace --selftest` and `XSpace --selftest-persist` pass
- [ ] `XSpace --selftest-ui` passes (for UI or memory changes)
- [ ] Checked manually in the app:

## Checklist

- [ ] Every new web view uses its profile's data store (never `WKWebsiteDataStore.default()`)
- [ ] No telemetry, tracking or new third-party dependencies
- [ ] Sandbox entitlements unchanged, or the change is explained above
- [ ] `CHANGELOG.md` and docs updated for user-visible changes
- [ ] No personal data in code, screenshots or logs
