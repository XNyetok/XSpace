import AppKit
import WebKit

enum WebKitSupport {
    /// Safari version used in the User-Agent, so pages see exactly what Safari sends.
    /// Google rejects sign-ins from "embedded browsers", and the default WKWebView
    /// User-Agent lacks the "Version/x Safari/y" token that makes it look like Safari.
    static let safariVersion: String = {
        let candidates = [
            "/Applications/Safari.app/Contents/Info.plist",
            "/System/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist",
        ]
        for path in candidates {
            if let dict = NSDictionary(contentsOfFile: path),
               let version = dict["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        // Safari's Info.plist may be unreadable (sandbox). Since 2025 Safari's version matches
        // the OS version (Safari 26 on macOS 26, ...); older systems get a matching guess.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        switch os.majorVersion {
        case 26...: return "\(os.majorVersion).\(os.minorVersion)"
        case 15: return "18.0"
        default: return "17.0"
        }
    }()

    static var userAgentSuffix: String { "Version/\(safariVersion) Safari/605.1.15" }

    /// The static WKWebsiteDataStore APIs (allDataStoreIdentifiers / remove) crash with SIGSEGV
    /// in WTF::RunLoop::dispatch when called before WebKit is initialized. Creating any WebKit
    /// object first avoids it, so call this before using those APIs.
    @MainActor
    static func warmUp() {
        _ = WKWebsiteDataStore.nonPersistent()
    }

    /// Deletes a data store. WebKit refuses while the store is still in use, so this retries.
    @MainActor
    static func removeDataStore(_ id: UUID, attempts: Int = 6) async -> Bool {
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    /// Asks WebKit to write the cookies of the given stores to disk now, waiting at most
    /// `timeout` seconds. A safeguard on quit, so a session created moments before quitting is
    /// on disk. (Note: older WebKit loads saved cookies lazily, on the first page that uses a
    /// profile, so the cookie store API can look empty right after launch.) Uses the SPI
    /// `-[WKHTTPCookieStore _flushCookiesToDiskWithCompletionHandler:]` (also used by Safari);
    /// it is checked first, and without it this returns immediately.
    @MainActor
    static func flushCookies(_ stores: [WKWebsiteDataStore], timeout: TimeInterval = 2) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            flushCookies(stores, timeout: timeout) { continuation.resume() }
        }
    }

    private static let flushSelector = NSSelectorFromString("_flushCookiesToDiskWithCompletionHandler:")

    /// Whether this WebKit offers the cookie flush SPI.
    @MainActor
    static var canFlushCookies: Bool {
        WKWebsiteDataStore.nonPersistent().httpCookieStore.responds(to: flushSelector)
    }

    /// Callback form, safe to use while AppKit waits for `applicationShouldTerminate` in a nested
    /// run loop: it relies only on WebKit callbacks and a run-loop timer, never on Swift
    /// concurrency or the main dispatch queue (which may be blocked at that moment).
    /// `completion` is called exactly once, asynchronously, on the main thread.
    @MainActor
    static func flushCookies(_ stores: [WKWebsiteDataStore], timeout: TimeInterval = 2,
                             completion: @escaping @MainActor () -> Void) {
        let cookieStores = stores.map(\.httpCookieStore).filter { $0.responds(to: flushSelector) }
        let waiter = FlushWaiter(remaining: cookieStores.count, completion: completion)
        // The block is stored by WebKit and called later, so it must be declared escaping;
        // otherwise the Swift runtime traps ("closure ... passed as @noescape ... has escaped").
        typealias FlushFunction = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        for store in cookieStores {
            let flush = unsafeBitCast(store.method(for: flushSelector), to: FlushFunction.self)
            flush(store, flushSelector) {
                RunLoop.main.perform { MainActor.assumeIsolated { waiter.oneDone() } }
            }
        }
        let timer = Timer(timeInterval: cookieStores.isEmpty ? 0 : timeout, repeats: false) { _ in
            MainActor.assumeIsolated { waiter.finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        waiter.timer = timer
    }

    @MainActor
    private final class FlushWaiter {
        private var remaining: Int
        private var completion: (@MainActor () -> Void)?
        var timer: Timer?

        init(remaining: Int, completion: @escaping @MainActor () -> Void) {
            self.remaining = remaining
            self.completion = completion
        }

        func oneDone() {
            remaining -= 1
            if remaining <= 0 { finish() }
        }

        func finish() {
            timer?.invalidate()
            timer = nil
            let completion = self.completion
            self.completion = nil
            completion?()
        }
    }

    /// Configuration for a new pane. RULE: always use the profile's own data store,
    /// never WKWebsiteDataStore.default().
    @MainActor
    static func makeConfiguration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.applicationNameForUserAgent = userAgentSuffix
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = .all   // no autoplay: lighter
        return config
    }
}

// MARK: - Downloads

@MainActor
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    static let shared = DownloadCoordinator()
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let candidate = Self.destination(in: folder, suggestedFilename: suggestedFilename)
        destinations[ObjectIdentifier(download)] = candidate
        completionHandler(candidate)
    }

    /// Where a download is saved: the name the site suggests without any folder part, so the
    /// file always lands directly in `folder`, and "name 2.ext", "name 3.ext", ... instead of
    /// overwriting an existing file, like Safari.
    static func destination(in folder: URL, suggestedFilename: String,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        var name = suggestedFilename.components(separatedBy: "/").last ?? ""
        if name.isEmpty || name == "." || name == ".." { name = "download" }
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2
        while exists(candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Bounces the Downloads stack in the Dock, like Safari. In the sandbox the Downloads
        // folder is a symlink inside the container, so report the real path.
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"),
                                                     object: url.resolvingSymlinksInPath().path)
        _ = NSApp.requestUserAttention(.informationalRequest)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        let alert = NSAlert()
        alert.messageText = "Unduhan gagal"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

// MARK: - Error page

enum ErrorPage {
    static func html(message: String, url: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>
        body{font:14px -apple-system,system-ui;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;color:GrayText}
        .box{max-width:460px;padding:24px;text-align:center}
        h1{font-size:17px;color:CanvasText}
        code{word-break:break-all;font-size:12px}
        a{color:LinkText}
        </style></head>
        <body><div class="box">
        <h1>Halaman tidak bisa dimuat</h1>
        <p>\(esc(message))</p>
        <p><code>\(esc(url))</code></p>
        <p><a href="\(esc(url))">Coba lagi</a> · atau tekan ⌘R</p>
        </div></body></html>
        """
    }
}
