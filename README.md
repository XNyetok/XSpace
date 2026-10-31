# XSpace

**Several isolated browser profiles in one macOS window. Native, lightweight, private.**

XSpace puts several "browsers" side by side in a single window. Every profile has its own
cookies, logins and website data, completely separate from the other profiles. A typical
setup: Google AI Studio next to Google Sheets, for several Google accounts, without the
accounts ever mixing and without a pile of browser windows spread across Spaces.

> **Status:** early prototype (v0.3). macOS 14+. The app UI is in Indonesian for now —
> localization is planned and contributions are welcome.
>
> 🇮🇩 Baca dalam Bahasa Indonesia: [README.id.md](README.id.md)

## Why XSpace

- **One window** instead of several full browser windows.
- **Truly separate profiles.** Each profile is its own persistent WebKit data store, not just a
  tab group.
- **Light on memory.** Native Swift + AppKit on top of the system WebKit: no Electron, no
  bundled Chromium. On an Apple M2 Mac with 8 GB RAM, the same two pages (AI Studio + Sheets,
  signed out) used about **536 MB** in XSpace versus **964 MB** in Chrome with a fresh profile
  and no extensions (physical footprint, measured with an unsandboxed build).

## Features

- Profiles with fully isolated website data (one `WKWebsiteDataStore(forIdentifier:)` each)
- Panes side by side within a profile (default: Google AI Studio | Google Sheets), resizable
- **Focus** mode (one profile) and **All** mode (every profile stacked in a grid)
- Color-coded profiles and pane borders, so you always know which account you are in
- Popups and sign-in windows stay inside their profile
- Memory saving: lazy loading, automatic freezing of hidden profiles, RAM indicator
- Downloads, file uploads, camera/microphone prompts, page zoom, back/forward
- App Sandbox + Hardened Runtime, no telemetry, no third-party dependencies

## Requirements

- macOS 14 Sonoma or later
- To build: Xcode 16 or later (or the Command Line Tools with Swift 5.10+)

## Build and run

```bash
git clone https://github.com/XNyetok/XSpace.git
cd XSpace
./scripts/build.sh             # → build/XSpace.app
open build/XSpace.app
./scripts/build.sh --install   # optional: copy to ~/Applications
```

**Code signing.** `build.sh` signs with the first valid *Apple Development* or *Developer ID
Application* identity in your keychain, or the one named in `XSPACE_SIGN_IDENTITY`. Without an
identity the app is ad-hoc signed: it still works, but because the sandboxed app's signature
changes on every rebuild, macOS may ask for confirmation after rebuilding. A free Apple
Development certificate (Xcode → Settings → Accounts → Manage Certificates) avoids that.

## Using XSpace

| Action | How |
|---|---|
| Switch profile | click it in the toolbar, or ⌘1–⌘9 |
| Add a profile | **+** button or ⇧⌘N |
| Rename, recolor, reset panes, delete | **⋯** button or the **Profil** menu |
| One profile / all profiles | **Fokus / Semua** (top right) or ⌃⌘G |
| Address bar of the focused pane | ⌘L |
| Reload / back / forward | ⌘R / ⌘[ / ⌘] |
| Zoom a pane | ⌘= / ⌘- / ⌘0 |
| Resize panes | drag the divider; double-click it to equalize |
| Memory usage and saving | the **RAM …** indicator, or **Tampilan → Hemat RAM** |

### Memory saving

Profiles you have not opened yet are not loaded at all. Profiles that are off screen are not
rendered and are throttled by WebKit, and they can be **frozen**: their web views are destroyed
so the memory goes back to the system, and the pages reload when you open the profile again.
You stay signed in, but unsaved input on a page may be lost. Choose when this happens in the
RAM indicator menu:

- **After 15 minutes off screen** (default, also on memory pressure)
- **Immediately when hidden** (lightest)
- **Only on memory pressure** (when macOS reports low memory)
- **Never**

The profile on screen is never frozen automatically. Inside the sandbox, macOS only lets the
app read the *resident size* of WebKit's helper processes, so the indicator shows an
approximate total (≈), which is usually a little higher than Activity Monitor's numbers.

### Signing in to Google

Signing in with a password (plus 2-step verification) works, and Google does not show the
"This browser or app may not be secure" block, because XSpace sends Safari's User-Agent.
**Passkeys do not work** in XSpace: WebAuthn in a third-party WKWebView app requires a
browser entitlement from Apple. If Google offers a passkey, choose **Try another way**. You only
sign in once per profile; the session is kept.

## Privacy and security

- Runs in the **App Sandbox** with **Hardened Runtime**. Entitlements: outgoing network,
  user-selected files, Downloads, camera, microphone (see `Support/XSpace.entitlements`).
- All data stays on your Mac, inside the app's container:
  `~/Library/Containers/io.github.xnyetok.xspace/`.
- No telemetry, analytics or crash reporting. No network requests besides the pages you open.
- No JavaScript is injected into pages.
- Two private WebKit APIs (SPI) are used, both checked before use so a future macOS change
  cannot crash the app: reading WebKit helper process IDs for the RAM indicator, and flushing
  cookies to disk when quitting (the same call Safari uses), so a fresh sign-in survives a
  restart on older macOS versions.
- Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## Development

```bash
APP=build/XSpace.app/Contents/MacOS/XSpace
$APP --selftest            # profile isolation, Google pages, User-Agent, persistence (write)
$APP --selftest-persist    # persistence (read back) + cleanup
$APP --selftest-ui         # real window with throwaway state: freezing + RAM indicator
```

All self-tests use their own throwaway profiles and never touch your real ones. Set
`XSPACE_SELFTEST_OFFLINE=1` to skip the parts that need the network (CI does this).

| File | Contents |
|---|---|
| `Sources/XSpace/Models.swift` | persisted state; one profile = one `WKWebsiteDataStore` |
| `Sources/XSpace/WebKitSupport.swift` | web view configuration, Safari User-Agent, downloads, error page |
| `Sources/XSpace/PaneView.swift` | one pane: mini toolbar + `WKWebView` + navigation/UI delegates |
| `Sources/XSpace/ProfileRowView.swift` | profile row, pane splitter, grid container |
| `Sources/XSpace/MainWindowController.swift` | main window, toolbar, profile actions, memory saving |
| `Sources/XSpace/MemoryMonitor.swift` | memory measurement and macOS memory-pressure watcher |
| `Sources/XSpace/PopupWindowController.swift` | popups that stay in their profile |
| `Sources/XSpace/AppDelegate.swift` | menus and app lifecycle |
| `Sources/XSpace/SelfTest.swift`, `UISelfTest.swift` | self-tests |

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Roadmap

- English UI and proper localization (Indonesian + English)
- Flexible layouts: number of panes per profile, presets per workspace
- Signed and notarized releases (Developer ID)
- Optional per-profile proxy
- Web notifications bridged to macOS notifications

## License

[MIT](LICENSE). Not affiliated with Google or Apple. Google AI Studio and Google Sheets are
trademarks of Google LLC.
