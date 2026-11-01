import AppKit
import WebKit

/// One browser pane: a mini toolbar (profile, back/forward/reload, address) + a WKWebView.
/// The border uses the profile color so it is always clear which account a pane belongs to.
@MainActor
final class PaneView: NSView, WKNavigationDelegate, WKUIDelegate {
    /// Height of the mini toolbar above the page.
    static let toolbarHeight: CGFloat = 32

    let profile: Profile
    let webView: WKWebView

    var onURLChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onRequestClose: (() -> Void)?
    /// Builds the menu that the profile name opens (show this pane in another profile, split it,
    /// close it). Set by the pane's workspace; a popup has none, and there the name is a label.
    var menuProvider: (() -> NSMenu?)? {
        didSet { refreshProfileAppearance() }
    }

    private let toolbar = NSView()
    /// The profile's dot and name; opens the menu of menuProvider.
    private let profileButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let urlField = NSTextField()
    private let progressBar = NSView()
    private var progressWidth: NSLayoutConstraint?
    private var observations: [NSKeyValueObservation] = []
    private var failedURL: URL?
    /// The web content process died while the pane was hidden. It is reloaded when the pane
    /// becomes visible, not in the background, so the memory is not immediately used again.
    private(set) var needsReloadWhenVisible = false

    /// - Parameter configuration: supplied by WebKit for popups and must be used as is, so a
    ///   sign-in popup stays in the same profile data store; nil for regular panes.
    init(profile: Profile, configuration: WKWebViewConfiguration?, initialURL: URL?) {
        self.profile = profile
        let config = configuration ?? WebKitSupport.makeConfiguration(store: profile.store)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        setUpViews()
        observeWebView()
        refreshProfileAppearance()
        if let initialURL {
            webView.load(URLRequest(url: initialURL))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// URL worth restoring later (not a sign-in or error page).
    var persistableURL: String? {
        guard let url = webView.url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        if let host = url.host, host.hasPrefix("accounts.") { return nil }
        return url.absoluteString
    }

    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        onURLChange = nil
        onTitleChange = nil
        onRequestClose = nil
    }

    // MARK: Views

    private func setUpViews() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 2

        toolbar.wantsLayer = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.wantsLayer = true
        progressBar.isHidden = true

        profileButton.isBordered = false
        profileButton.imagePosition = .imageLeading
        profileButton.imageHugsTitle = true
        profileButton.lineBreakMode = .byTruncatingTail
        profileButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profileButton.setContentHuggingPriority(.required, for: .horizontal)
        profileButton.target = self
        profileButton.action = #selector(showPaneMenu(_:))

        configure(backButton, symbol: "chevron.left", tip: "Kembali (⌘[)", action: #selector(backPane(_:)))
        configure(forwardButton, symbol: "chevron.right", tip: "Maju (⌘])", action: #selector(forwardPane(_:)))
        configure(reloadButton, symbol: "arrow.clockwise", tip: "Muat ulang (⌘R)", action: #selector(reloadOrStop(_:)))

        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.font = .systemFont(ofSize: 12)
        urlField.isBezeled = true
        urlField.bezelStyle = .roundedBezel
        urlField.usesSingleLineMode = true
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.isScrollable = true
        urlField.cell?.wraps = false
        urlField.cell?.sendsActionOnEndEditing = false
        urlField.placeholderString = "Ketik alamat atau kata kunci"
        urlField.target = self
        urlField.action = #selector(urlFieldSubmitted(_:))
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [profileButton, backButton, forwardButton, reloadButton, urlField])
        bar.orientation = .horizontal
        bar.spacing = 6
        // 8 pt on both sides keeps the controls clear of the swap button between two panes.
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.setCustomSpacing(10, after: profileButton)
        bar.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(bar)
        toolbar.addSubview(progressBar)
        addSubview(toolbar)
        addSubview(webView)

        let progressWidth = progressBar.widthAnchor.constraint(equalToConstant: 0)
        self.progressWidth = progressWidth
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            bar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            bar.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            profileButton.widthAnchor.constraint(lessThanOrEqualToConstant: 170),
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

            progressBar.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
            progressWidth,

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
    }

    func refreshProfileAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.borderColor = self.profile.color.cgColor
            self.progressBar.layer?.backgroundColor = self.profile.color.cgColor
            self.toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        profileButton.image = Palette.dot(profile.color, diameter: 10)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString(string: profile.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: profile.color,
            .paragraphStyle: paragraph,
        ])
        if menuProvider != nil {
            title.append(NSAttributedString(string: " ▾", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .baselineOffset: 1,
                .paragraphStyle: paragraph,
            ]))
        }
        profileButton.attributedTitle = title
        profileButton.toolTip = menuProvider == nil
            ? profile.name
            : "\(profile.name): tampilkan pane ini di profil lain, bagi, atau tutup"
        profileButton.setAccessibilityLabel("Profil \(profile.name)")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshProfileAppearance()
    }

    // MARK: State sync

    private func observeWebView() {
        observations = [
            webView.observe(\.url, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncLocation() }
            },
            webView.observe(\.canGoBack, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncButtons() }
            },
            webView.observe(\.canGoForward, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncButtons() }
            },
            webView.observe(\.isLoading, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.syncButtons()
                    self?.syncProgress()
                }
            },
            webView.observe(\.estimatedProgress, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncProgress() }
            },
            webView.observe(\.title, options: []) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.onTitleChange?(webView.title ?? "") }
            },
        ]
        syncButtons()
    }

    private func syncLocation() {
        guard urlField.currentEditor() == nil else { return }
        if webView.url?.scheme == "about", let failedURL {
            urlField.stringValue = failedURL.absoluteString
        } else {
            urlField.stringValue = webView.url?.absoluteString ?? ""
        }
    }

    private func syncButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        let loading = webView.isLoading
        reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise",
                                     accessibilityDescription: loading ? "Berhenti" : "Muat ulang")
    }

    private func syncProgress() {
        let loading = webView.isLoading
        progressBar.isHidden = !loading
        progressWidth?.constant = loading ? max(0.05, webView.estimatedProgress) * toolbar.bounds.width : 0
    }

    // MARK: Actions (also reached from menus through the responder chain)

    @objc func reloadPane(_ sender: Any?) {
        if webView.url?.scheme == "about", let failedURL {
            webView.load(URLRequest(url: failedURL))
        } else if webView.url == nil {
            if let url = PaneView.resolve(urlField.stringValue) {
                webView.load(URLRequest(url: url))
            }
        } else {
            webView.reload()
        }
    }

    @objc private func showPaneMenu(_ sender: NSButton) {
        guard let menu = menuProvider?() else { return }
        let below = sender.isFlipped ? sender.bounds.maxY + 4 : sender.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: sender)
    }

    @objc func reloadOrStop(_ sender: Any?) {
        if webView.isLoading { webView.stopLoading() } else { reloadPane(sender) }
    }

    @objc func backPane(_ sender: Any?) { webView.goBack() }
    @objc func forwardPane(_ sender: Any?) { webView.goForward() }

    @objc func openLocation(_ sender: Any?) {
        window?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }

    @objc func zoomInPane(_ sender: Any?) { webView.pageZoom = min(3.0, ((webView.pageZoom * 10).rounded() + 1) / 10) }
    @objc func zoomOutPane(_ sender: Any?) { webView.pageZoom = max(0.3, ((webView.pageZoom * 10).rounded() - 1) / 10) }
    @objc func actualSizePane(_ sender: Any?) { webView.pageZoom = 1.0 }

    @objc private func urlFieldSubmitted(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = PaneView.resolve(text) else { return }
        webView.load(URLRequest(url: url))
        window?.makeFirstResponder(webView)
    }

    /// Turns address-bar input into a URL: full URLs as is, "example.com" as https,
    /// "localhost:3000" and IP addresses as http (local servers rarely have TLS; Safari does the
    /// same), anything else as a Google search.
    static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about"].contains(scheme) {
            return url
        }
        if !trimmed.contains(" "), trimmed.contains(".") || trimmed.hasPrefix("localhost") {
            let host = trimmed.prefix { !":/?#".contains($0) }
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            let isLocal = host == "localhost" || (octets.count == 4 && octets.allSatisfy { UInt8($0) != nil })
            return URL(string: (isLocal ? "http://" : "https://") + trimmed)
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            // mailto:, tel:, zoommtg:, ... go to macOS, but only when the user clicked a link.
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        if navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadCoordinator.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadCoordinator.shared
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.scheme != "about" { failedURL = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = persistableURL { onURLChange?(url) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return } // download / plug-in
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? webView.url?.absoluteString ?? ""
        failedURL = URL(string: failing)
        webView.loadHTMLString(ErrorPage.html(message: ns.localizedDescription, url: failing), baseURL: nil)
        urlField.stringValue = failing
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page process crashed or was killed by the system to reclaim memory.
        if window == nil || isHiddenOrHasHiddenAncestor {
            needsReloadWhenVisible = true
        } else {
            webView.reload()
        }
    }

    func reloadIfNeeded() {
        guard needsReloadWhenVisible else { return }
        needsReloadWhenVisible = false
        reloadPane(nil)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // IMPORTANT: use WebKit's `configuration` as is, so the popup (sign-in, "open in new
        // tab", ...) keeps the same profile data store and the window.opener relationship.
        let popup = PopupWindowController(profile: profile, configuration: configuration,
                                          features: windowFeatures, relativeTo: window)
        popup.showWindow(nil)
        return popup.pane.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        onRequestClose?()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Batal")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = makeAlert(message: prompt, frame: frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Batal")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window {
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)   // let the user decide (camera/microphone)
    }

    private func makeAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "Pesan dari halaman" : host
        alert.informativeText = message
        return alert
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in completion(response) }
        } else {
            completion(alert.runModal())
        }
    }
}
