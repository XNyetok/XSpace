import AppKit
import WebKit

/// Headless self-tests:
///   XSpace --selftest           profile isolation, Google pages, User-Agent, write persistence data
///   XSpace --selftest-persist   read the persistence data back in a new process, then clean up
/// Set XSPACE_SELFTEST_OFFLINE=1 to skip the network part (used in CI).
/// Every test profile has its own UUID and is deleted at the end; real profiles are never touched.
@MainActor
final class SelfTest: NSObject, NSApplicationDelegate {
    enum Mode {
        case full
        case persistRead

        init?(arguments: [String]) {
            if arguments.contains("--selftest-persist") {
                self = .persistRead
            } else if arguments.contains("--selftest") {
                self = .full
            } else {
                return nil
            }
        }
    }

    private static let persistID = UUID(uuidString: "6B1F0C9E-5A7D-4E1B-9C2A-58F3D0A1B2C3")!
    private static let testHTML = "<!doctype html><title>xspace-selftest</title><p>xspace</p>"
    private static let testBase = URL(string: "https://example.com/")!
    /// The Google pages XSpace is mostly used for.
    private static let googlePages = ["https://aistudio.google.com/", "https://docs.google.com/spreadsheets/"]

    private let mode: Mode
    private var failures = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            switch mode {
            case .full: await runFull()
            case .persistRead: await runPersistRead()
            }
            log(failures == 0 ? "\nRESULT: ALL PASSED" : "\nRESULT: \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: Main test

    private func runFull() async {
        log("XSpace self-test — \(ProcessInfo.processInfo.operatingSystemVersionString), Safari \(WebKitSupport.safariVersion)")

        // [1] Isolation
        log("\n[1] Isolation between profiles (cookies, localStorage, cookie store)")
        let idA = UUID(), idB = UUID()
        var storeA: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: idA)
        var storeB: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: idB)
        let cookie = HTTPCookie(properties: [
            .domain: "example.com", .path: "/", .name: "xspace", .value: "A",
            .expires: Date().addingTimeInterval(3600),
        ])!
        await storeA!.httpCookieStore.setCookie(cookie)

        var webA: WKWebView? = makeWebView(storeA!)
        var webB: WKWebView? = makeWebView(storeB!)
        webA!.loadHTMLString(Self.testHTML, baseURL: Self.testBase)
        webB!.loadHTMLString(Self.testHTML, baseURL: Self.testBase)
        _ = await waitUntilLoaded(webA!)
        _ = await waitUntilLoaded(webB!)
        _ = await js(webA!, "localStorage.setItem('xspace', 'A'); return 'ok'")

        let readA = await js(webA!, "return JSON.stringify({localStorage: localStorage.getItem('xspace'), cookie: document.cookie})")
        let readB = await js(webB!, "return JSON.stringify({localStorage: localStorage.getItem('xspace'), cookie: document.cookie})")
        log("   Profile A sees: \(readA)")
        log("   Profile B sees: \(readB)")
        check(readA.contains("\"localStorage\":\"A\"") && readA.contains("xspace=A"),
              "Profile A can read its own cookie and localStorage")
        check(readB.contains("\"localStorage\":null") && !readB.contains("xspace=A"),
              "Profile B can NOT see profile A's data")
        let cookiesA = await storeA!.httpCookieStore.allCookies()
        let cookiesB = await storeB!.httpCookieStore.allCookies()
        check(cookiesA.contains { $0.name == "xspace" } && !cookiesB.contains { $0.name == "xspace" },
              "Cookie stores are separate at the WebKit level (A: \(cookiesA.count) cookie(s), B: \(cookiesB.count))")

        // [2] Google pages
        if ProcessInfo.processInfo.environment["XSPACE_SELFTEST_OFFLINE"] == "1" {
            log("\n[2] Google pages: skipped (XSPACE_SELFTEST_OFFLINE=1)")
        } else {
            log("\n[2] Loading Google pages without signing in (test profile A)")
            for target in Self.googlePages {
                webA!.load(URLRequest(url: URL(string: target)!))
                let loaded = await waitUntilLoaded(webA!, timeout: 45)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let final = webA!.url?.absoluteString ?? "-"
                let title = webA!.title ?? "-"
                check(loaded && final.hasPrefix("https://"), "\(target)\n      → \(final)  [title: \(title)]")
            }
            let userAgent = await js(webA!, "return navigator.userAgent")
            log("   User-Agent: \(userAgent)")
            check(userAgent.contains("Version/") && userAgent.contains("Safari/"), "User-Agent has Safari's format")
            let webAuthn = await js(webA!, """
                if (typeof PublicKeyCredential === 'undefined') return 'PublicKeyCredential missing';
                try {
                  const ok = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
                  return ok ? 'platform authenticator reported AVAILABLE' : 'platform authenticator reported NOT available';
                } catch (e) { return 'error: ' + e; }
                """)
            log("   Passkeys (hint only; the real proof is signing in): \(webAuthn)")
        }

        // [3] Persistence (write phase)
        log("\n[3] Persistence — write phase")
        let persistStore = WKWebsiteDataStore(forIdentifier: Self.persistID)
        let persistCookie = HTTPCookie(properties: [
            .domain: "example.com", .path: "/", .name: "xspace_persist", .value: "ok",
            .expires: Date().addingTimeInterval(3600),
        ])!
        await persistStore.httpCookieStore.setCookie(persistCookie)
        let persistWeb = makeWebView(persistStore)
        persistWeb.loadHTMLString(Self.testHTML, baseURL: Self.testBase)
        _ = await waitUntilLoaded(persistWeb)
        let wrote = await js(persistWeb, "localStorage.setItem('xspace_persist', 'ok'); return localStorage.getItem('xspace_persist')")
        let writtenPageCookie = await js(persistWeb, "return document.cookie")
        let writtenStoreCookies = await persistStore.httpCookieStore.allCookies().map(\.name)
        log("   before quitting — document.cookie: \"\(writtenPageCookie)\", cookie store: \(writtenStoreCookies)")
        check(wrote == "ok" && writtenPageCookie.contains("xspace_persist=ok"),
              "Test data written (run --selftest-persist next to read it back)")

        // [4] Clean up test profiles A and B
        log("\n[4] Deleting test profiles A and B")
        let removals = [DataStoreRemoval(storeA!), DataStoreRemoval(storeB!)]
        webA = nil
        webB = nil
        storeA = nil
        storeB = nil
        for removal in removals {
            await checkRemoval(removal, "Test profile \(removal.shortID)… deleted")
        }

        // Same as quitting the app: flush cookies explicitly, then give WebKit a moment to
        // write localStorage before the process ends.
        let flushStart = Date()
        await WebKitSupport.flushCookies([persistStore])
        let flushMilliseconds = Int(Date().timeIntervalSince(flushStart) * 1000)
        log("   Cookie flush: \(flushMilliseconds) ms (\(WebKitSupport.canFlushCookies ? "WebKit SPI" : "SPI missing, timeout only"))")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        withExtendedLifetime(persistWeb) {}
    }

    // MARK: Persistence test (read phase)

    private func runPersistRead() async {
        log("XSpace self-test — persistence, read phase (new process)")
        WebKitSupport.warmUp()
        let ids = await WKWebsiteDataStore.allDataStoreIdentifiers
        check(ids.contains(Self.persistID), "Test profile still exists after the app quit")
        var store: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: Self.persistID)
        // What matters to users is what pages see after a restart, so read the cookie from the
        // page; the cookie store API is logged before and after loading a page for diagnostics
        // (older WebKit may load the persisted cookie file only once a page uses the store).
        let storeBefore = await store!.httpCookieStore.allCookies().map(\.name)
        var web: WKWebView? = makeWebView(store!)
        web!.loadHTMLString(Self.testHTML, baseURL: Self.testBase)
        _ = await waitUntilLoaded(web!)
        let pageCookie = await js(web!, "return document.cookie")
        let storeAfter = await store!.httpCookieStore.allCookies().map(\.name)
        log("   cookie store before page load: \(storeBefore); after: \(storeAfter); document.cookie: \"\(pageCookie)\"")
        check(pageCookie.contains("xspace_persist=ok"), "Cookie survives a restart (as seen by the page)")
        if !storeBefore.contains("xspace_persist") && storeAfter.contains("xspace_persist") {
            log("   note: this WebKit loads persisted cookies lazily, on first use of the profile")
        }
        let value = await js(web!, "return String(localStorage.getItem('xspace_persist'))")
        check(value == "ok", "localStorage survives a restart (value: \(value))")

        let removal = DataStoreRemoval(store!)
        web = nil
        store = nil
        await checkRemoval(removal, "Persistence test profile deleted")
        let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
        log("   Data stores owned by the app now: \(remaining.count)")
    }

    // MARK: Helpers

    private func makeWebView(_ store: WKWebsiteDataStore) -> WKWebView {
        WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                  configuration: WebKitSupport.makeConfiguration(store: store))
    }

    private func waitUntilLoaded(_ webView: WKWebView, timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(nanoseconds: 300_000_000)
        while Date() < deadline {
            if !webView.isLoading { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func js(_ webView: WKWebView, _ body: String) async -> String {
        do {
            let result = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            return result.map { "\($0)" } ?? "nil"
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    private func check(_ ok: Bool, _ label: String) {
        log("\(ok ? "  PASS" : "  FAIL")  \(label)")
        if !ok { failures += 1 }
    }

    /// Deletes a test profile's data store once WebKit has released it, and checks the result.
    private func checkRemoval(_ removal: DataStoreRemoval, _ label: String) async {
        let failure = await removal.remove()
        check(failure == nil, failure.map { "\(label) (\($0))" } ?? label)
    }

    private func log(_ text: String) {
        print(text)
        fflush(stdout)
    }
}
