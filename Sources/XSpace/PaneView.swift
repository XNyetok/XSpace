import AppKit
import WebKit

/// One browser pane: a mini toolbar (profile, back/forward/reload/home, address) + a WKWebView,
/// with the start page over it while the pane has no page yet or after Beranda. The border uses the
/// profile color so it is always clear which account a pane belongs to.
@MainActor
final class PaneView: NSView, WKNavigationDelegate, WKUIDelegate {
    /// Height of the mini toolbar above the page.
    static let toolbarHeight: CGFloat = 32
    /// A narrower pane leaves the zoom controls out of its toolbar, so that the profile's name and
    /// the address field keep some room; ⌘= and ⌘- still work there.
    static let minimumWidthForZoomControls: CGFloat = 320
    /// The hint in an empty address field (and in the start page's search box), as in browsers:
    /// what is not an address is searched for with Google (see resolve).
    static let addressPlaceholder = "Telusuri Google atau ketik URL"
    /// The note a pane shows when a page asks for a new tab.
    static let newTabNote = "Membuka tab baru belum didukung"

    let profile: Profile
    let webView: WKWebView

    var onURLChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onRequestClose: (() -> Void)?
    /// Builds the menu that the profile name opens: the profiles to show in this pane. Set for the
    /// panes of the main window; a popup has none, and there the name is only a label.
    var menuProvider: (() -> NSMenu?)? {
        didSet { refreshProfileAppearance() }
    }
    /// The profile's shortcuts, for the start page. Set for the panes of the main window.
    var shortcutsProvider: (() -> [Shortcut])? {
        didSet { refreshShortcuts() }
    }
    /// Adding, changing or removing one of the profile's shortcuts; without it the start page offers
    /// no way to.
    var onEditShortcuts: ((ShortcutEdit) -> Void)? {
        didSet { refreshShortcuts() }
    }
    /// Whether the page's zoom follows the size of the pane (see PageZoom); otherwise it is 100%.
    /// Either way the profile's own zoom comes on top. Set for the panes of the main window.
    var automaticZoom = false {
        didSet { if automaticZoom != oldValue { updateZoom() } }
    }
    /// The profile's own zoom (⌘+ / ⌘−): percentage points on top of the automatic zoom.
    var zoomOffset = 0 {
        didSet { if zoomOffset != oldValue { updateZoom() } }
    }
    /// ⌘+, ⌘− or ⌘0 changed the profile's own zoom. Set for the panes of the main window, which
    /// keep it for the profile.
    var onZoomOffsetChange: ((Int) -> Void)?

    private let toolbar = NSView()
    /// The profile's dot and name; opens the menu of menuProvider.
    private let profileButton = NSButton()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let homeButton = NSButton()
    private let urlField = NSTextField()
    /// − and + zoom the pane out and in. Between them its zoom, which a click takes back to the
    /// automatic one.
    private let zoomControls = NSStackView()
    private let zoomOutButton = NSButton()
    private let zoomButton = NSButton()
    private let zoomInButton = NSButton()
    private let progressBar = NSView()
    private var progressWidth: NSLayoutConstraint?
    private var observations: [NSKeyValueObservation] = []
    private var failedURL: URL?
    /// The web content process died while the pane was hidden. It is reloaded when the pane
    /// becomes visible, not in the background, so the memory is not immediately used again.
    private(set) var needsReloadWhenVisible = false
    /// Shown over the page while the pane has no page yet, or after Beranda; nil otherwise.
    private var startPage: StartPageView?
    /// A short note at the bottom of the pane, such as that new tabs are not supported.
    private let noteView = PaneNoteView()
    /// Waits for the mouse button to be released before the zoom follows a new size (see
    /// setFrameSize).
    private var zoomTimer: Timer?

    /// - Parameters:
    ///   - configuration: supplied by WebKit for popups and must be used as is, so a sign-in popup
    ///     stays in the same profile data store; nil for regular panes.
    ///   - initialURL: the page to open. Without one, a regular pane shows its start page (an
    ///     address field) and loads nothing.
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
        if let initialURL {
            webView.load(URLRequest(url: initialURL))
        } else if configuration == nil {
            showStartPage()
        }
        refreshProfileAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whether the pane shows its start page: over its page after Beranda, or because it has no page
    /// yet (and nothing is loaded).
    var isShowingStartPage: Bool { startPage != nil }

    /// What gets the keyboard focus when the pane does: the start page's address field, or the page.
    var focusTarget: NSView { startPage?.field ?? webView }

    /// URL worth restoring later (not a sign-in or error page).
    var persistableURL: String? {
        guard let url = webView.url, Self.isWorthRestoring(url) else { return nil }
        return url.absoluteString
    }

    /// Pages worth restoring: http and https, except sign-in pages.
    static func isWorthRestoring(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if let host = url.host, host.hasPrefix("accounts.") { return false }
        return true
    }

    func tearDown() {
        // A web view that still has the keyboard focus can outlive the pane, and keep its data
        // store in use: the focus goes first.
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
            window.makeFirstResponder(nil)
        }
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        zoomTimer?.invalidate()
        zoomTimer = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        startPage?.onSubmit = nil
        startPage?.onOpen = nil
        startPage?.onEdit = nil
        onURLChange = nil
        onTitleChange = nil
        onRequestClose = nil
        shortcutsProvider = nil
        onEditShortcuts = nil
        onZoomOffsetChange = nil
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
        configure(homeButton, symbol: "house", tip: "Halaman awal (⇧⌘H)", action: #selector(homePane(_:)))
        // A small, plain − and +, so that the zoom between them is what you see.
        let small = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        configure(zoomOutButton, symbol: "minus", tip: "Perkecil (⌘-)", action: #selector(zoomOutPane(_:)),
                  width: 18, symbolConfiguration: small)
        configure(zoomInButton, symbol: "plus", tip: "Perbesar (⌘=)", action: #selector(zoomInPane(_:)),
                  width: 18, symbolConfiguration: small)
        zoomButton.isBordered = false
        zoomButton.target = self
        zoomButton.action = #selector(resetZoomPane(_:))
        zoomButton.translatesAutoresizingMaskIntoConstraints = false
        zoomButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        zoomControls.setViews([zoomOutButton, zoomButton, zoomInButton], in: .leading)
        zoomControls.spacing = 0
        zoomControls.isHidden = true   // until the pane is wide enough (see setFrameSize)

        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.font = .systemFont(ofSize: 12)
        urlField.isBezeled = true
        urlField.bezelStyle = .roundedBezel
        urlField.usesSingleLineMode = true
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.isScrollable = true
        urlField.cell?.wraps = false
        urlField.cell?.sendsActionOnEndEditing = false
        urlField.placeholderString = Self.addressPlaceholder
        urlField.target = self
        urlField.action = #selector(urlFieldSubmitted(_:))
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [profileButton, backButton, forwardButton, reloadButton, homeButton, urlField,
                                      zoomControls])
        bar.orientation = .horizontal
        bar.spacing = 6
        // 8 pt on both sides keeps the controls clear of the swap button between two panes.
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        bar.setCustomSpacing(10, after: profileButton)
        bar.detachesHiddenViews = true   // the zoom controls in a narrow pane
        bar.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(bar)
        toolbar.addSubview(progressBar)
        addSubview(toolbar)
        addSubview(webView)
        noteView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noteView)

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

            noteView.centerXAnchor.constraint(equalTo: centerXAnchor),
            noteView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            noteView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        syncZoomControls()
    }

    // MARK: Start page

    /// The start page covers the page area, and the page behind it (if any) waits, hidden. The
    /// toolbar stays as it is, as in a browser: Kembali returns to that page, and the address field
    /// is empty.
    private func showStartPage() {
        let page = StartPageView()
        page.translatesAutoresizingMaskIntoConstraints = false
        page.onSubmit = { [weak self] text in self?.openFromStartPage(text) }
        page.onOpen = { [weak self] url in self?.open(url) }
        page.onEdit = { [weak self] edit in self?.onEditShortcuts?(edit) }
        addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        startPage = page
        page.show(profile)
        refreshShortcuts()
        webView.isHidden = true
        syncButtons()
        syncLocation()
    }

    /// The start page goes: a page opens, or Kembali returns to the one behind it.
    private func closeStartPage() {
        guard let page = startPage else { return }
        startPage = nil
        // Hidden now, removed after this event: this can run in the action of the page's own
        // field, which must outlive it.
        page.isHidden = true
        Task { @MainActor in page.removeFromSuperview() }
        webView.isHidden = false
        syncButtons()
        syncLocation()
    }

    /// Opens what was typed on the start page, or in the address field while it is shown.
    private func openFromStartPage(_ text: String) {
        guard let url = PaneView.resolve(text) else { return }
        open(url)
    }

    /// Opens a page from the start page. The profile keeps it as its page right away, so it comes
    /// back even if the site first sends you to a sign-in page.
    private func open(_ url: URL) {
        closeStartPage()
        webView.load(URLRequest(url: url))
        if Self.isWorthRestoring(url) { onURLChange?(url.absoluteString) }
        window?.makeFirstResponder(webView)
    }

    /// Shows the profile's shortcuts on the start page; a new one starts with the page behind it.
    func refreshShortcuts() {
        guard let startPage else { return }
        if let url = webView.url, Self.isWorthRestoring(url) {
            let title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? Shortcut.defaultTitle(for: url)
            startPage.suggestion = Shortcut(title: title, url: url.absoluteString)
        } else {
            startPage.suggestion = nil
        }
        startPage.show(shortcuts: shortcutsProvider?() ?? [], editable: onEditShortcuts != nil)
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector, width: CGFloat = 22,
                           symbolConfiguration: NSImage.SymbolConfiguration? = nil) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.image = symbolConfiguration.flatMap { image?.withSymbolConfiguration($0) } ?? image
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
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
            : "\(profile.name): klik untuk menampilkan profil lain di pane ini"
        profileButton.setAccessibilityLabel("Profil \(profile.name)")
        startPage?.show(profile)
    }

    // MARK: Zoom

    /// The area of the page: the pane below its toolbar.
    var pageArea: CGSize {
        CGSize(width: bounds.width, height: max(0, bounds.height - Self.toolbarHeight))
    }

    /// The zoom without the profile's own: automatic, or 100%.
    private var baseZoom: Int {
        automaticZoom ? PageZoom.automatic(for: pageArea) : 100
    }

    /// Gives the page the zoom it should have now, and shows it between − and +. With the automatic
    /// zoom, a pane that has no size yet waits for one.
    func updateZoom() {
        let area = pageArea
        if !automaticZoom || (area.width > 0 && area.height > 0) {
            let zoom = CGFloat(PageZoom.zoom(base: baseZoom, offset: zoomOffset)) / 100
            if webView.pageZoom != zoom { webView.pageZoom = zoom }
        }
        syncZoomControls()
    }

    /// The zoom between − and +: in the accent color while the profile has its own zoom, which a
    /// click on it takes away.
    private func syncZoomControls() {
        let zoom = Int((webView.pageZoom * 100).rounded())
        let own = zoomOffset != 0
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        zoomButton.attributedTitle = NSAttributedString(string: "\(zoom)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: own ? .semibold : .regular),
            .foregroundColor: own ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ])
        if own {
            zoomButton.toolTip = automaticZoom
                ? "Zoom \(zoom)%, diatur sendiri untuk pane ini (otomatis: \(baseZoom)%). Klik untuk kembali ke zoom otomatis (⌘0)."
                : "Zoom \(zoom)%, diatur sendiri untuk pane ini. Klik untuk kembali ke 100% (⌘0)."
        } else {
            zoomButton.toolTip = (automaticZoom ? "Zoom \(zoom)%, otomatis mengikuti ukuran pane." : "Zoom \(zoom)%.")
                + " − dan + mengubahnya untuk pane ini."
        }
        zoomButton.setAccessibilityLabel("Zoom \(zoom)%")
        zoomOutButton.isEnabled = zoom > PageZoom.range.lowerBound
        zoomInButton.isEnabled = zoom < PageZoom.range.upperBound
    }

    private func changeZoomOffset(to offset: Int) {
        guard offset != zoomOffset else { return }
        zoomOffset = offset
        onZoomOffsetChange?(offset)
    }

    /// While a divider or the window is being dragged, the page follows the new size at its zoom,
    /// and the zoom follows once the mouse button is released: a new zoom makes WebKit lay out the
    /// whole page again, and doing that on every step of a drag took about 40% more CPU (measured
    /// with a busy test page).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        zoomControls.isHidden = newSize.width < Self.minimumWidthForZoomControls
        guard automaticZoom else { return }
        if inLiveResize || NSEvent.pressedMouseButtons != 0 {
            updateZoomWhenMouseIsReleased()
        } else {
            updateZoom()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateZoom()
    }

    private func updateZoomWhenMouseIsReleased() {
        guard zoomTimer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                self?.zoomTimer = nil
                self?.updateZoom()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        zoomTimer = timer
    }

    // MARK: Hooks for the automated UI test (--selftest-ui)

    /// The note at the bottom of the pane, while one is shown.
    var testNote: String? {
        noteView.shownText
    }

    func testHideNote() {
        noteView.hide()
    }

    /// The page's zoom, in percent.
    var testZoom: Int {
        Int((webView.pageZoom * 100).rounded())
    }

    /// The zoom shown between − and + in the pane's toolbar, and whether they are on screen.
    var testZoomControls: (title: String, shown: Bool) {
        (zoomButton.title, zoomButton.window != nil && !zoomButton.isHiddenOrHasHiddenAncestor)
    }

    /// Whether the controls in the pane's toolbar fit in it, with room for the profile's name.
    var testToolbarFits: Bool {
        layoutSubtreeIfNeeded()
        let shown = [profileButton, urlField, zoomInButton].filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        return profileButton.frame.width >= 20
            && shown.allSatisfy { toolbar.bounds.contains($0.convert($0.bounds, to: toolbar)) }
    }

    /// Clicks − (-1), the zoom between them (0) or + (1) in the pane's toolbar.
    func testClickZoom(_ control: Int) {
        [zoomOutButton, zoomButton, zoomInButton][control + 1].performClick(nil)
    }

    /// The names on the start page's shortcut tiles that are shown, the tile to add one included.
    var testShortcutTitles: [String]? {
        window?.layoutIfNeeded()   // which tiles fit depends on the size of the pane
        return startPage?.testTileTitles
    }

    /// Clicks the shortcut tile with this name.
    func testClickShortcut(_ title: String) {
        startPage?.testTile(title)?.performClick(nil)
    }

    /// Removes a shortcut like its tile's menu does.
    func testRemoveShortcut(_ title: String) {
        startPage?.testTile(title)?.removeShortcut(nil)
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
        if isShowingStartPage {
            urlField.stringValue = ""   // as on a new tab: the page behind is not the one shown
        } else if webView.url?.scheme == "about", let failedURL {
            urlField.stringValue = failedURL.absoluteString
        } else {
            urlField.stringValue = webView.url?.absoluteString ?? ""
        }
    }

    /// On the start page Kembali returns to the page behind it, if there is one, and there is
    /// nothing to go forward to, reload, or go home to.
    private func syncButtons() {
        backButton.isEnabled = isShowingStartPage ? webView.url != nil : webView.canGoBack
        forwardButton.isEnabled = !isShowingStartPage && webView.canGoForward
        reloadButton.isEnabled = !isShowingStartPage
        homeButton.isEnabled = !isShowingStartPage
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
        guard !isShowingStartPage else { return }
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

    /// From the start page: back to the page behind it.
    @objc func backPane(_ sender: Any?) {
        guard isShowingStartPage else {
            webView.goBack()
            return
        }
        guard webView.url != nil else { return }
        closeStartPage()
        reloadIfNeeded()
        window?.makeFirstResponder(webView)
    }

    @objc func forwardPane(_ sender: Any?) {
        if !isShowingStartPage { webView.goForward() }
    }

    /// Beranda: the start page, over the page, which stays as it is behind it.
    @objc func homePane(_ sender: Any?) {
        if !isShowingStartPage { showStartPage() }
        window?.makeFirstResponder(focusTarget)
    }

    @objc func openLocation(_ sender: Any?) {
        window?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }

    /// ⌘+ and ⌘−: the profile's own zoom, on top of the automatic one.
    @objc func zoomInPane(_ sender: Any?) {
        changeZoomOffset(to: PageZoom.offset(zoomOffset, base: baseZoom, adding: PageZoom.step))
    }

    @objc func zoomOutPane(_ sender: Any?) {
        changeZoomOffset(to: PageZoom.offset(zoomOffset, base: baseZoom, adding: -PageZoom.step))
    }

    /// ⌘0, Atur Ulang Zoom: back to the automatic zoom (100% without it).
    @objc func resetZoomPane(_ sender: Any?) {
        changeZoomOffset(to: 0)
    }

    @objc private func urlFieldSubmitted(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if isShowingStartPage { return openFromStartPage(text) }
        guard !text.isEmpty, let url = PaneView.resolve(text) else { return }
        webView.load(URLRequest(url: url))
        window?.makeFirstResponder(webView)
    }

    /// Turns address-bar input into a URL: an address (see `address`), anything else as a Google
    /// search.
    nonisolated static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = address(trimmed) { return url }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    /// Typed text as an address, nil for anything else (search terms): full http, https and about
    /// URLs as they are, "example.com" as https, "localhost:3000" and IP addresses as http (local
    /// servers rarely have TLS; Safari does the same).
    nonisolated static func address(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about"].contains(scheme) {
            return url
        }
        guard !trimmed.contains(" "), trimmed.contains(".") || trimmed.hasPrefix("localhost") else { return nil }
        let host = trimmed.prefix { !":/?#".contains($0) }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        let isLocal = host == "localhost" || (octets.count == 4 && octets.allSatisfy { UInt8($0) != nil })
        return URL(string: (isLocal ? "http://" : "https://") + trimmed)
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
        // The page process crashed or was killed by the system to reclaim memory. A page behind
        // the start page waits too.
        if window == nil || isHiddenOrHasHiddenAncestor || webView.isHidden {
            needsReloadWhenVisible = true
        } else {
            webView.reload()
        }
    }

    func reloadIfNeeded() {
        guard needsReloadWhenVisible, !isShowingStartPage else { return }
        needsReloadWhenVisible = false
        reloadPane(nil)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // XSpace has no tabs yet: a link or page that asks for a new tab (target="_blank",
        // window.open without a size, Open Link in New Window) gets a note at the bottom of the
        // pane instead of a window. Popup windows, such as sign-in windows, still open.
        guard PopupWindowController.isPopupWindow(windowFeatures) else {
            noteView.show(Self.newTabNote)
            return nil
        }
        // IMPORTANT: use WebKit's `configuration` as is, so the popup (a sign-in window, ...) keeps
        // the same profile data store and the window.opener relationship.
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
