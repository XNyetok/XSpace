# Security Policy

XSpace holds signed-in web sessions, so security reports are taken seriously.

## Supported versions

Only the latest release and the `main` branch receive security fixes.

## Reporting a vulnerability

**Please do not open a public issue.** Report privately through GitHub:
**Security → Advisories → Report a vulnerability** on this repository. If that option is not
available, contact the maintainers privately through GitHub and we will set up a private channel.

Please include the XSpace version or commit, your macOS version, steps to reproduce, and the
impact. We aim to acknowledge reports within a week and will credit you in the fix unless you
prefer otherwise.

## In scope

- Data leaking between profiles (cookies, storage, cache, credentials, popups opening in the
  wrong profile)
- Ways to escape or weaken the App Sandbox, or entitlements broader than needed
- Exposure of session data (for example through logs, snapshots or files outside the container)
- Unsafe handling of URL schemes, downloads or file uploads

## Out of scope

- Vulnerabilities in WebKit or macOS themselves: please report them to Apple
  (https://security.apple.com).
- Problems with third-party websites or accounts (for example Google sign-in policies).

## Security design (summary)

- One persistent `WKWebsiteDataStore(forIdentifier:)` per profile; the default data store is
  never used.
- App Sandbox + Hardened Runtime; entitlements are listed in `Support/XSpace.entitlements`.
- No telemetry, no remote logging, no third-party dependencies, no JavaScript injected into pages.
- Non-web URL schemes (`mailto:`, ...) are handed to macOS only after a user click.
- Private WebKit API usage is limited to reading helper process IDs for the RAM indicator, and
  is checked with `responds(to:)` before use.
