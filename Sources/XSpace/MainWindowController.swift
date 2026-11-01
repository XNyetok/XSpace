import AppKit
import WebKit

/// Main window: toolbar (profiles, add, profile options, layout, RAM indicator) and the panes.
/// Every profile is one pane, its own browser with its own login. The layout (see GridPreset)
/// decides which profiles are shown and where; the others are hidden, and frozen in time. Without
/// profiles (the first start) the window shows the welcome screen instead.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                  NSMenuItemValidation, NSMenuDelegate {
    private let state = StateStore.shared
    private(set) var profiles: [Profile] = []
    /// The panes of the profiles that are loaded: shown, or hidden and not frozen yet.
    private var panes: [UUID: PaneView] = [:]
    /// Since when each profile has been off screen; drives automatic freezing.
    private var hiddenSince: [UUID: Date] = [:]
    private let grid = GridView()
    /// While there are no profiles.
    private var welcome: WelcomeView?
    /// The empty slots of the current layout, by slot.
    private var emptySlots: [Int: EmptySlotView] = [:]
    private let profileSwitcher = NSSegmentedControl()
    private let layoutMenu = NSMenu(title: "Tata Letak")
    private let memoryMenu = NSMenu(title: "Memori")
    private var layoutItem: NSMenuToolbarItem?
    private var memoryItem: NSMenuToolbarItem?
    private let pressureWatcher = MemoryPressureWatcher()
    private var housekeepingTimer: Timer?

    var onProfilesChanged: (() -> Void)?

    private enum ToolbarID {
        static let profiles = NSToolbarItem.Identifier("xspace.profiles")
        static let add = NSToolbarItem.Identifier("xspace.add")
        static let more = NSToolbarItem.Identifier("xspace.more")
        static let layout = NSToolbarItem.Identifier("xspace.layout")
        static let memory = NSToolbarItem.Identifier("xspace.memory")
    }

    func profile(_ id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    /// The pane with the keyboard focus (its page or its address field), if it is on screen.
    var focusedPane: PaneView? {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if let pane = current as? PaneView {
                return pane.isHiddenOrHasHiddenAncestor ? nil : pane
            }
            view = current.superview
        }
        return nil
    }

    /// The profile you are in: the one whose pane has the keyboard focus, otherwise the active
    /// profile if it is shown, otherwise the first one shown. The profile commands act on it, and a
    /// profile shown from the toolbar takes the place of its pane.
    var activeProfile: Profile? {
        if let pane = focusedPane { return pane.profile }
        let shown = state.data.shownProfiles.compactMap { $0 }
        if let selected = state.data.selectedProfileID, shown.contains(selected) { return profile(selected) }
        return profile(shown.first) ?? profiles.first
    }

    /// The slot of the active profile; the first slot if it is not shown.
    private var activeSlot: Int {
        activeProfile.flatMap { state.data.shownProfiles.firstIndex(of: $0.id) } ?? 0
    }

    /// The active profile's pane, if it is shown.
    private var activePane: PaneView? {
        guard let profile = activeProfile, state.data.isShown(profile.id) else { return nil }
        return panes[profile.id]
    }

    init() {
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        window.title = "XSpace"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        buildLayoutMenu()
        buildToolbar()
        buildContent()
        loadProfiles()

        if !window.setFrameUsingName("XSpaceMainWindow"), let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame.insetBy(dx: 24, dy: 18), display: false)
        }
        window.setFrameAutosaveName("XSpaceMainWindow")
        startHousekeeping()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "XSpaceMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func buildContent() {
        let content = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        window?.contentView = content
    }

    /// The layouts, also in Tampilan → Tata Letak (see AppDelegate).
    private func buildLayoutMenu() {
        for preset in GridPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(chooseLayout(_:)), keyEquivalent: "")
            item.target = self
            item.image = preset.icon
            item.representedObject = preset.rawValue
            layoutMenu.addItem(item)
        }
    }

    private func loadProfiles() {
        profiles = state.data.profiles.map { Profile(state: $0) }
        grid.onSizesChanged = { [weak self] sizes in
            guard let self else { return }
            self.state.data.layoutSizes[self.state.data.sizesKey] = sizes
            self.state.scheduleSave()
        }
        grid.onSwapRequested = { [weak self] first, second in self?.swapSlots(first, second) }
        rebuildSwitcher()
        applyLayout()
    }

    /// Shows the profiles of the layout and hides the others. Hidden profiles are not rendered and
    /// are throttled by WebKit; when they get frozen (web views destroyed) is decided by the
    /// HibernatePolicy. A profile that has not been shown yet is not loaded at all.
    private func applyLayout() {
        showWelcome(profiles.isEmpty)
        let paneHadFocus = focusedPane != nil
        let shown = state.data.shownProfiles
        let shownIDs = Set(shown.compactMap { $0 })
        let now = Date()
        // The hidden ones first, so that a pane leaving its slot stays in the window.
        for profile in profiles where !shownIDs.contains(profile.id) {
            if hiddenSince[profile.id] == nil { hiddenSince[profile.id] = now }
            guard let pane = panes[profile.id] else { continue }
            if state.data.hibernatePolicy == .immediately {
                hibernate(profile.id)
            } else {
                grid.hide(pane)
            }
        }
        var views: [NSView] = []
        for (slot, id) in shown.enumerated() {
            if let profile = profile(id) {
                hiddenSince[profile.id] = nil
                views.append(loadedPane(for: profile))
            } else {
                views.append(emptySlotView(slot))
            }
        }
        emptySlots = emptySlots.filter { slot, _ in slot < shown.count && shown[slot] == nil }
        grid.show(state.data.tree, views: views, sizes: state.data.layoutSizes[state.data.sizesKey])

        // A pane that had the keyboard focus and is hidden now loses it to the window (or keeps
        // it, if AppKit did not take it): the focus goes to the active profile's pane.
        let responderHidden = (window?.firstResponder as? NSView)?.isHiddenOrHasHiddenAncestor == true
        if responderHidden || (paneHadFocus && focusedPane == nil) {
            window?.makeFirstResponder(activePane?.focusTarget)
        }
        refreshSwitcherSelection()
        layoutItem?.image = state.data.layout.icon
        let name = state.data.layout == .single ? (activeProfile?.name ?? "") : state.data.layout.title
        window?.title = profiles.isEmpty ? "XSpace" : "XSpace — \(name)"
        refreshMemoryIndicator()
    }

    /// The welcome screen takes the place of the panes while there are no profiles, and the toolbar
    /// items wait too. (The items are hidden, not the toolbar: that would change the window's height.)
    private func showWelcome(_ shown: Bool) {
        guard shown != (welcome != nil) else { return }
        window?.toolbar?.items.forEach { $0.isHidden = shown }
        grid.isHidden = shown
        if shown, let content = window?.contentView {
            let view = WelcomeView()
            view.onChoose = { [weak self] preset in self?.start(with: preset) }
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            welcome = view
        } else if !shown, let welcome {
            welcome.removeFromSuperview()
            self.welcome = nil
        }
    }

    /// Leaves the welcome screen with the layout chosen there: a new profile in each of its panes
    /// (see AppStateData.start), every one on its start page, the first one with the keyboard focus.
    private func start(with preset: GridPreset) {
        guard profiles.isEmpty else { return }
        state.data.start(with: preset)
        profiles = state.data.profiles.map { Profile(state: $0) }
        state.save()
        rebuildSwitcher()
        applyLayout()
        if let first = profiles.first { focus(first.id) }
    }

    /// When the window opens on a start page, its address field gets the keyboard focus, so you can
    /// type right away.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if focusedPane == nil, let pane = activePane, pane.isShowingStartPage {
            window?.makeFirstResponder(pane.focusTarget)
        }
    }

    /// The pane of a profile, made the first time the profile is shown or after it was frozen.
    private func loadedPane(for profile: Profile) -> PaneView {
        if let pane = panes[profile.id] {
            pane.reloadIfNeeded()
            return pane
        }
        let url = state.data.profiles.first { $0.id == profile.id }?.url
        let pane = PaneView(profile: profile, configuration: nil, initialURL: url.flatMap { URL(string: $0) })
        let id = profile.id
        pane.onURLChange = { [weak self] url in self?.state.updateProfile(id) { $0.url = url } }
        pane.menuProvider = { [weak self] in self?.paneMenu(for: id) }
        pane.shortcutsProvider = { [weak self] in self?.state.data.profiles.first { $0.id == id }?.shortcuts ?? [] }
        pane.onEditShortcuts = { [weak self] edit in self?.editShortcuts(of: id, edit) }
        panes[id] = pane
        return pane
    }

    private func emptySlotView(_ slot: Int) -> EmptySlotView {
        if let view = emptySlots[slot] { return view }
        let view = EmptySlotView()
        view.menuProvider = { [weak self] in self?.emptySlotMenu(slot) }
        emptySlots[slot] = view
        return view
    }

    private func rebuildSwitcher() {
        // Without profiles (the welcome screen) one empty segment stays: the toolbar measures the
        // control even while its item is hidden, and warns about one without width.
        profileSwitcher.segmentCount = max(profiles.count, 1)
        if profiles.isEmpty {
            profileSwitcher.setLabel("", forSegment: 0)
            profileSwitcher.setImage(nil, forSegment: 0)
            profileSwitcher.setToolTip(nil, forSegment: 0)
            profileSwitcher.setSelected(false, forSegment: 0)
        }
        for (index, profile) in profiles.enumerated() {
            profileSwitcher.setLabel(profile.name, forSegment: index)
            profileSwitcher.setImage(Palette.dot(profile.color), forSegment: index)
            profileSwitcher.setImageScaling(.scaleNone, forSegment: index)
            profileSwitcher.setWidth(0, forSegment: index)
            profileSwitcher.setToolTip(index < 9 ? "\(profile.name) (⌘\(index + 1))" : profile.name, forSegment: index)
        }
        refreshSwitcherSelection()
        profileSwitcher.sizeToFit()
        profileSwitcher.invalidateIntrinsicContentSize()
        onProfilesChanged?()
    }

    /// The profiles on screen are selected in the toolbar.
    private func refreshSwitcherSelection() {
        for (index, profile) in profiles.enumerated() where index < profileSwitcher.segmentCount {
            profileSwitcher.setSelected(state.data.isShown(profile.id), forSegment: index)
        }
    }

    private func focus(_ id: UUID) {
        guard state.data.isShown(id), let pane = panes[id] else { return }
        window?.makeFirstResponder(pane.focusTarget)
    }

    func persistAll() {
        for (id, pane) in panes {
            if let url = pane.persistableURL { state.updateProfile(id) { $0.url = url } }
        }
        state.save()
    }

    // MARK: Showing profiles

    @objc func profileSwitcherChanged(_ sender: NSSegmentedControl) {
        // The segment clicked is the one whose selection no longer matches what is on screen.
        let clicked = profiles.indices.first { index in
            index < sender.segmentCount && sender.isSelected(forSegment: index) != state.data.isShown(profiles[index].id)
        }
        refreshSwitcherSelection()
        if let clicked { show(profiles[clicked]) }
    }

    @objc func selectProfileFromMenu(_ sender: NSMenuItem) {
        guard profiles.indices.contains(sender.tag) else { return }
        show(profiles[sender.tag])
    }

    /// Shows a profile: one on screen gets the keyboard focus; another one takes the place of the
    /// pane you are in (in the single-profile layout: the one shown).
    func show(_ profile: Profile) {
        if !state.data.isShown(profile.id) {
            state.data.show(profile.id, inSlot: activeSlot)
        }
        state.data.selectedProfileID = profile.id
        state.scheduleSave()
        applyLayout()
        focus(profile.id)
    }

    private func show(_ id: UUID, inSlot slot: Int) {
        state.data.show(id, inSlot: slot)
        state.scheduleSave()
        rebuildSwitcher()   // the automatic layout follows the toolbar order, which may change
        applyLayout()
        focus(id)
    }

    /// The menu that the profile name in a pane opens: the profiles to show in that pane. A profile
    /// shown elsewhere trades places with it; one that is not shown takes its place.
    func paneMenu(for profileID: UUID) -> NSMenu? {
        guard let slot = state.data.shownProfiles.firstIndex(of: profileID) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Tampilkan di pane ini"))
        for profile in profiles {
            let id = profile.id
            let item = NSMenuItem(title: profile.name) { [weak self] in self?.show(id, inSlot: slot) }
            item.image = Palette.dot(profile.color, diameter: 10)
            item.state = id == profileID ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// The menu of an empty slot: the profiles that are not shown, and a new profile.
    func emptySlotMenu(_ slot: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hidden = profiles.filter { !state.data.isShown($0.id) }
        if !hidden.isEmpty {
            menu.addItem(.sectionHeader(title: "Tampilkan di sini"))
            for profile in hidden {
                let id = profile.id
                let item = NSMenuItem(title: profile.name) { [weak self] in self?.show(id, inSlot: slot) }
                item.image = Palette.dot(profile.color, diameter: 10)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Tambah Profil…") { [weak self] in self?.askForNewProfile(inSlot: slot) })
        return menu
    }

    // MARK: Layouts

    @objc func chooseLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = GridPreset(rawValue: raw) else { return }
        setLayout(preset)
    }

    /// Without profiles, a layout chosen from the menu starts like one chosen on the welcome screen.
    func setLayout(_ preset: GridPreset) {
        if profiles.isEmpty { return start(with: preset) }
        guard preset != state.data.layout else { return }
        let active = activeProfile?.id
        state.data.switchLayout(to: preset, active: active)
        state.scheduleSave()
        applyLayout()
        if let active { focus(active) }
    }

    /// Ctrl-Cmd-G: only the profile you are in, or back to the layout before.
    @objc func toggleSingleProfile(_ sender: Any?) {
        setLayout(state.data.layout == .single ? (state.data.previousLayout ?? .automatic) : .single)
    }

    private func swapSlots(_ first: Int, _ second: Int) {
        state.data.swapSlots(first, second)
        state.scheduleSave()
        rebuildSwitcher()   // in the automatic layout, the toolbar order is the order on screen
        applyLayout()
    }

    /// Tukar Posisi Pane: the pane you are in trades places with the next one (the last one with
    /// the one before). It keeps the keyboard focus.
    @objc func swapPanes(_ sender: Any?) {
        let count = state.data.shownProfiles.count
        guard count > 1 else { return }
        let slot = activeSlot
        let active = activeProfile?.id
        swapSlots(slot, slot + 1 < count ? slot + 1 : slot - 1)
        if let active { focus(active) }
    }

    // MARK: Memory saving

    private func startHousekeeping() {
        pressureWatcher.start { [weak self] event in
            self?.handleMemoryPressure(event)
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hibernateIdleProfiles()
                self?.refreshMemoryIndicator()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
        refreshMemoryIndicator()
    }

    /// Freezes a profile: its web view is destroyed (its processes exit, memory is returned), and
    /// its page is kept for when it is shown again.
    private func hibernate(_ id: UUID) {
        guard let pane = panes.removeValue(forKey: id) else { return }
        if let url = pane.persistableURL { state.updateProfile(id) { $0.url = url } }
        pane.tearDown()
        pane.removeFromSuperview()
    }

    /// Freezes the profiles that have been hidden for longer than the policy allows.
    func hibernateIdleProfiles(now: Date = Date()) {
        guard let limit = state.data.hibernatePolicy.idleSeconds else { return }
        for (id, since) in hiddenSince where now.timeIntervalSince(since) >= limit && !state.data.isShown(id) {
            hibernate(id)
        }
    }

    /// macOS reports memory pressure → freeze every profile that is not on screen.
    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        guard state.data.hibernatePolicy.respondsToMemoryPressure else { return }
        let frozen = hibernateAllHidden()
        if frozen > 0 {
            NSLog("XSpace: memory pressure (%@) → froze %d hidden profile(s)",
                  event.contains(.critical) ? "critical" : "warning", frozen)
        }
    }

    @discardableResult
    private func hibernateAllHidden() -> Int {
        let hidden = panes.keys.filter { !state.data.isShown($0) }
        hidden.forEach { hibernate($0) }
        refreshMemoryIndicator()
        return hidden.count
    }

    @objc func hibernateHiddenNow(_ sender: Any?) {
        hibernateAllHidden()
    }

    @objc func setHibernatePolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = HibernatePolicy(rawValue: raw) else { return }
        state.data.hibernatePolicy = policy
        state.scheduleSave()
        applyLayout()
        hibernateIdleProfiles()
    }

    /// Memory per profile: its pane and its popups.
    func memoryReport() -> MemoryReport {
        var report = MemoryReport()
        var seen = Set<pid_t>()
        func measure(_ pid: pid_t?) -> UInt64 {
            guard let pid, !seen.contains(pid), let sample = MemoryProbe.sample(of: pid) else { return 0 }
            seen.insert(pid)
            if !sample.isExact { report.isApproximate = true }
            return sample.bytes
        }
        report.app = measure(getpid())
        var anyWebView: WKWebView?
        for profile in profiles {
            let pane = panes[profile.id]
            let webViews = (pane.map { [$0.webView] } ?? []) + PopupWindowController.webViews(for: profile.id)
            var bytes: UInt64 = 0
            for webView in webViews {
                if anyWebView == nil { anyWebView = webView }
                bytes += measure(MemoryProbe.pid(of: webView, "_webProcessIdentifier"))
            }
            report.profiles.append(.init(name: profile.name, color: profile.color, bytes: bytes,
                                         panes: pane == nil ? 0 : 1, hidden: !state.data.isShown(profile.id)))
            report.network += measure(MemoryProbe.pid(of: profile.store, "_networkProcessIdentifier"))
        }
        if let pool = anyWebView?.configuration.value(forKey: "processPool") as? NSObject {
            report.gpu += measure(MemoryProbe.pid(of: pool, "_gpuProcessIdentifier"))
            report.network += measure(MemoryProbe.pid(of: pool, "_networkProcessIdentifier"))
        }
        return report
    }

    private func refreshMemoryIndicator() {
        guard let memoryItem else { return }
        memoryItem.title = "RAM \(memoryReport().totalText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === memoryMenu else { return }
        let report = memoryReport()
        menu.removeAllItems()

        func info(_ title: String, image: NSImage? = nil, indent: Int = 0) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = image
            item.indentationLevel = indent
            menu.addItem(item)
        }

        info("Total XSpace: \(report.totalText)")
        if report.isApproximate {
            info("≈ perkiraan: sandbox macOS hanya mengizinkan membaca resident memory proses WebKit", indent: 1)
        }
        info("UI app: \(MemoryProbe.format(report.app))", indent: 1)
        info("GPU: \(MemoryProbe.format(report.gpu)) · Jaringan: \(MemoryProbe.format(report.network))", indent: 1)
        for usage in report.profiles {
            let status: String
            if usage.panes == 0 {
                status = "beku / belum dimuat"
            } else {
                status = MemoryProbe.format(usage.bytes) + (usage.hidden ? " · tersembunyi" : "")
            }
            info("\(usage.name): \(status)", image: Palette.dot(usage.color, diameter: 10), indent: 1)
        }

        menu.addItem(.separator())
        let freeze = NSMenuItem(title: "Bekukan Profil Tersembunyi Sekarang", action: #selector(hibernateHiddenNow(_:)), keyEquivalent: "")
        freeze.target = self
        freeze.isEnabled = panes.keys.contains { !state.data.isShown($0) }
        menu.addItem(freeze)

        menu.addItem(.separator())
        info("Bekukan otomatis profil tersembunyi:")
        for policy in HibernatePolicy.allCases {
            let item = NSMenuItem(title: policy.title, action: #selector(setHibernatePolicy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = policy.rawValue
            item.state = policy == state.data.hibernatePolicy ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
    }

    // MARK: Debug: window snapshot (no screen-recording permission needed)

    /// Draws the app's own window plus every web view into a PNG and prints layout and memory.
    /// Used through `XSpace --snapshot <file.png>` to verify the UI.
    func writeSnapshot(to url: URL) async {
        guard let window, let frameView = window.contentView?.superview else { return }
        printMemoryReport()   // measured before drawing so the numbers are not inflated
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)

        print("Window: \(Int(window.frame.width))×\(Int(window.frame.height)), "
              + (profiles.isEmpty ? "welcome screen" : "layout: \(state.data.layout.rawValue)"))
        var shots: [(NSImage, NSRect)] = []
        let shown = profiles.isEmpty ? [] : state.data.shownProfiles
        for (slot, id) in shown.enumerated() {
            guard let profile = profile(id), let pane = panes[profile.id] else {
                print("Slot \(slot + 1): empty")
                continue
            }
            let rect = pane.webView.convert(pane.webView.bounds, to: frameView)
            // The start page is part of the window; the web view behind it is empty.
            let page = pane.isShowingStartPage ? "start page" : pane.webView.url?.absoluteString ?? "-"
            print("Slot \(slot + 1): “\(profile.name)” \(Int(rect.width))×\(Int(rect.height)) — \(page)")
            guard !pane.isShowingStartPage else { continue }
            if let image = try? await pane.webView.takeSnapshot(configuration: nil) {
                shots.append((image, rect))
            }
        }
        fflush(stdout)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (image, rect) in shots {
            image.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
            print("Snapshot saved: \(url.path)")
        } catch {
            print("Could not write snapshot to \(url.path): \(error.localizedDescription). "
                  + "Sandboxed builds can only write inside their container or ~/Downloads.")
        }
    }

    private func printMemoryReport() {
        let report = memoryReport()
        print(report.isApproximate ? "Memory (≈ resident size; footprint not readable in the sandbox):" : "Memory (physical footprint):")
        print("  XSpace (native UI): \(MemoryProbe.format(report.app))")
        print("  GPU: \(MemoryProbe.format(report.gpu)) · Networking: \(MemoryProbe.format(report.network))")
        for usage in report.profiles {
            print("  \(usage.name): \(MemoryProbe.format(usage.bytes))\(usage.panes == 0 ? ", frozen" : "")\(usage.hidden ? ", hidden" : "")")
        }
        print("  TOTAL: \(report.totalText)")
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.profiles, ToolbarID.add, ToolbarID.more, ToolbarID.layout, .flexibleSpace, ToolbarID.memory]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = makeToolbarItem(itemIdentifier)
        item?.isHidden = welcome != nil
        return item
    }

    private func makeToolbarItem(_ itemIdentifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.profiles:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            profileSwitcher.trackingMode = .selectAny
            profileSwitcher.target = self
            profileSwitcher.action = #selector(profileSwitcherChanged(_:))
            item.view = profileSwitcher
            item.label = "Profil"
            return item
        case ToolbarID.add:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Tambah profil")
            item.label = "Tambah Profil"
            item.toolTip = "Tambah profil baru (⇧⌘N)"
            item.isBordered = true
            item.target = self
            item.action = #selector(addProfile(_:))
            return item
        case ToolbarID.more:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Opsi profil")
            item.label = "Opsi Profil"
            item.toolTip = "Opsi untuk profil yang sedang aktif"
            let menu = NSMenu()
            menu.addItem(menuItem("Ganti Nama Profil…", #selector(renameProfile(_:))))
            menu.addItem(menuItem("Ganti Warna Profil", #selector(cycleProfileColor(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("Hapus Profil…", #selector(deleteProfile(_:))))
            item.menu = menu
            item.showsIndicator = true
            return item
        case ToolbarID.layout:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = state.data.layout.icon
            item.label = "Tata Letak"
            item.toolTip = "Tata letak: berapa profil yang tampil dan di mana"
            item.menu = layoutMenu
            item.showsIndicator = true
            layoutItem = item
            return item
        case ToolbarID.memory:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.title = "RAM …"
            item.label = "Memori"
            item.toolTip = "Total memori XSpace (UI, halaman, GPU, jaringan). Klik untuk rincian & pengaturan hemat RAM."
            memoryMenu.delegate = self
            memoryMenu.autoenablesItems = false
            item.menu = memoryMenu
            item.showsIndicator = true
            memoryItem = item
            refreshMemoryIndicator()
            return item
        default:
            return nil
        }
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Profile actions

    @objc func addProfile(_ sender: Any?) {
        askForNewProfile(inSlot: activeSlot)
    }

    private func askForNewProfile(inSlot slot: Int) {
        guard let window else { return }
        askForText(title: "Tambah profil baru",
                   message: "Setiap profil tampil sebagai satu pane dengan login, cookie, dan data situs sendiri yang terpisah total dari profil lain.",
                   defaultValue: "Akun \(profiles.count + 1)", confirm: "Tambah", in: window) { [weak self] name in
            guard let self, let name else { return }
            self.createProfile(name: name, inSlot: slot)
        }
    }

    /// Adds a profile and shows it (see AppStateData.addProfile).
    @discardableResult
    func createProfile(name: String, inSlot slot: Int? = nil) -> Profile {
        let usedColors = Set(profiles.map(\.colorIndex))
        let color = (0..<Palette.colors.count).first { !usedColors.contains($0) } ?? profiles.count
        let added = state.data.addProfile(name: name, colorIndex: color, inSlot: slot ?? activeSlot)
        let profile = Profile(state: added)
        profiles.append(profile)
        state.save()
        rebuildSwitcher()
        applyLayout()
        focus(profile.id)
        return profile
    }

    @objc func renameProfile(_ sender: Any?) {
        guard let window, let profile = activeProfile else { return }
        askForText(title: "Ganti nama profil", message: "Nama hanya label; tidak mengubah akun di situs mana pun.",
                   defaultValue: profile.name, confirm: "Simpan", in: window) { [weak self] name in
            guard let self, let name else { return }
            profile.name = name
            self.state.updateProfile(profile.id) { $0.name = name }
            self.panes[profile.id]?.refreshProfileAppearance()
            PopupWindowController.refreshAppearance(for: profile.id)
            self.rebuildSwitcher()
            self.applyLayout()
        }
    }

    @objc func cycleProfileColor(_ sender: Any?) {
        guard let profile = activeProfile else { return }
        profile.colorIndex = (profile.colorIndex + 1) % Palette.colors.count
        let colorIndex = profile.colorIndex
        state.updateProfile(profile.id) { $0.colorIndex = colorIndex }
        panes[profile.id]?.refreshProfileAppearance()
        PopupWindowController.refreshAppearance(for: profile.id)
        rebuildSwitcher()
    }

    /// Deleting the last profile brings back the welcome screen.
    @objc func deleteProfile(_ sender: Any?) {
        guard let window, let profile = activeProfile else { return }
        let id = profile.id
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hapus profil “\(profile.name)”?"
        alert.informativeText = "Semua login, cookie, dan data situs di profil ini akan dihapus permanen dari Mac ini. "
            + "Akun di situs-situsnya sendiri tidak terpengaruh."
            + (profiles.count == 1 ? " Ini profil terakhir: XSpace kembali ke layar sambutan." : "")
        alert.addButton(withTitle: "Hapus")
        alert.addButton(withTitle: "Batal")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(id)
        }
    }

    /// Removes the profile from the window and the saved state, then deletes its data store in
    /// the background. Returns that deletion, so the UI self-test can wait for it.
    @discardableResult
    private func performDelete(_ id: UUID) -> Task<Void, Never>? {
        // Watch the data store before the last references to it go away (see DataStoreRemoval).
        let removal = profile(id).map { DataStoreRemoval($0.store) }
        PopupWindowController.closeAll(for: id)
        if let pane = panes.removeValue(forKey: id) {
            pane.tearDown()
            pane.removeFromSuperview()
        }
        hiddenSince[id] = nil
        state.data.removeProfile(id)
        profiles.removeAll { $0.id == id }
        state.save()
        rebuildSwitcher()
        applyLayout()   // also lets the layout's splits go of the pane
        guard let removal else { return nil }
        return Task { @MainActor in
            await StateStore.shared.removeDataStore(removal)
        }
    }

    private func askForText(title: String, message: String, defaultValue: String, confirm: String,
                            in window: NSWindow, completion: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Batal")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(response == .alertFirstButtonReturn && !text.isEmpty ? text : nil)
        }
    }

    // MARK: Shortcuts

    /// The start page of a profile asks to add, change or remove one of its shortcuts. Adding and
    /// changing ask for the name and address first; a new shortcut can go to every profile at once.
    private func editShortcuts(of id: UUID, _ edit: ShortcutEdit) {
        switch edit {
        case .add(let suggestion):
            askForShortcut(suggestion, adding: true) { [weak self] shortcut, everywhere in
                self?.changeShortcuts { $0.addShortcut(shortcut, to: id, everywhere: everywhere) }
            }
        case .change(let old):
            askForShortcut(old, adding: false) { [weak self] shortcut, _ in
                self?.changeShortcuts { $0.replaceShortcut(old, of: id, with: shortcut) }
            }
        case .remove(let shortcut):
            changeShortcuts { $0.removeShortcut(shortcut, from: id) }
        }
    }

    /// Changes shortcuts in the saved state and on the start pages.
    private func changeShortcuts(_ change: (inout AppStateData) -> Void) {
        change(&state.data)
        state.scheduleSave()
        panes.values.forEach { $0.refreshShortcuts() }
    }

    /// The dialog of a shortcut: its name and address and, for a new one, whether every other profile
    /// gets it too. What is not the address of a website is asked for again.
    private func askForShortcut(_ shortcut: Shortcut?, adding: Bool, retry: Bool = false, everywhere: Bool = false,
                                completion: @escaping @MainActor (Shortcut, Bool) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = adding ? "Tambah pintasan" : "Ubah pintasan"
        alert.informativeText = retry
            ? "Itu bukan alamat situs. Ketik alamatnya, misalnya example.com."
            : "Pintasan tampil di halaman awal profil. Tanpa nama, pintasan memakai nama situsnya."
        alert.addButton(withTitle: adding ? "Tambah" : "Simpan")
        alert.addButton(withTitle: "Batal")
        let name = NSTextField(string: shortcut?.title ?? "")
        let address = NSTextField(string: shortcut?.url ?? "")
        address.placeholderString = "example.com"
        for field in [name, address] {
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Nama:"), name],
            [NSTextField(labelWithString: "Alamat:"), address],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowAlignment = .firstBaseline
        form.rowSpacing = 8
        form.columnSpacing = 8
        let toAll = NSButton(checkboxWithTitle: "Tambahkan juga ke semua profil lain", target: nil, action: nil)
        toAll.state = everywhere ? .on : .off
        if adding && profiles.count > 1 {
            form.addRow(with: [NSGridCell.emptyContentView, toAll])
        }
        form.frame = NSRect(origin: .zero, size: form.fittingSize)
        alert.accessoryView = form
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let everywhere = toAll.state == .on
            guard let result = Shortcut(name: name.stringValue, address: address.stringValue) else {
                // Once this sheet is gone, with what was typed.
                let typed = Shortcut(title: name.stringValue, url: address.stringValue)
                Task { @MainActor in
                    self?.askForShortcut(typed, adding: adding, retry: true, everywhere: everywhere, completion: completion)
                }
                return
            }
            completion(result, everywhere)
        }
    }

    // MARK: Pane actions (fallback when keyboard focus is not inside a pane)

    @objc func reloadPane(_ sender: Any?) { activePane?.reloadPane(sender) }
    @objc func backPane(_ sender: Any?) { activePane?.backPane(sender) }
    @objc func forwardPane(_ sender: Any?) { activePane?.forwardPane(sender) }
    @objc func homePane(_ sender: Any?) { activePane?.homePane(sender) }
    @objc func openLocation(_ sender: Any?) { activePane?.openLocation(sender) }
    @objc func zoomInPane(_ sender: Any?) { activePane?.zoomInPane(sender) }
    @objc func zoomOutPane(_ sender: Any?) { activePane?.zoomOutPane(sender) }
    @objc func actualSizePane(_ sender: Any?) { activePane?.actualSizePane(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(chooseLayout(_:)):
            let isCurrent = !profiles.isEmpty && (menuItem.representedObject as? String) == state.data.layout.rawValue
            menuItem.state = isCurrent ? .on : .off
        case #selector(toggleSingleProfile(_:)):
            menuItem.state = state.data.layout == .single ? .on : .off
            return !profiles.isEmpty
        case #selector(renameProfile(_:)), #selector(cycleProfileColor(_:)), #selector(deleteProfile(_:)):
            return activeProfile != nil
        case #selector(setHibernatePolicy(_:)):
            menuItem.state = (menuItem.representedObject as? String) == state.data.hibernatePolicy.rawValue ? .on : .off
        case #selector(hibernateHiddenNow(_:)):
            return panes.keys.contains { !state.data.isShown($0) }
        case #selector(selectProfileFromMenu(_:)):
            let isShown = profiles.indices.contains(menuItem.tag) && state.data.isShown(profiles[menuItem.tag].id)
            menuItem.state = isShown ? .on : .off
        case #selector(swapPanes(_:)):
            return state.data.shownProfiles.count > 1
        case #selector(reloadPane(_:)), #selector(backPane(_:)), #selector(forwardPane(_:)),
             #selector(homePane(_:)), #selector(openLocation(_:)), #selector(zoomInPane(_:)),
             #selector(zoomOutPane(_:)), #selector(actualSizePane(_:)):
            return activePane != nil
        default:
            break
        }
        return true
    }

    // MARK: Hooks for the automated UI test (--selftest-ui)

    func testPane(_ name: String) -> PaneView? {
        profiles.first { $0.name == name }.flatMap { panes[$0.id] }
    }

    /// The names of the profiles on screen, slot by slot (nil = an empty slot).
    var testShown: [String?] {
        state.data.shownProfiles.map { profile($0)?.name }
    }

    func testShow(_ name: String) {
        if let profile = profiles.first(where: { $0.name == name }) { show(profile) }
    }

    /// Clicks a profile in the toolbar: the segment's selection flips, as with the mouse.
    func testClickInToolbar(_ name: String) {
        guard let index = profiles.firstIndex(where: { $0.name == name }) else { return }
        profileSwitcher.setSelected(!profileSwitcher.isSelected(forSegment: index), forSegment: index)
        profileSwitcherChanged(profileSwitcher)
    }

    /// The names of the profiles selected in the toolbar.
    var testSelectedInToolbar: [String] {
        profiles.indices.filter { $0 < profileSwitcher.segmentCount && profileSwitcher.isSelected(forSegment: $0) }
            .map { profiles[$0].name }
    }

    var testGrid: GridView { grid }

    /// The welcome screen, while it is shown.
    var testWelcome: WelcomeView? { welcome }

    /// Changes shortcuts as the dialogs do, without them.
    func testChangeShortcuts(_ change: (inout AppStateData) -> Void) {
        changeShortcuts(change)
    }

    func testSetPolicy(_ policy: HibernatePolicy) {
        state.data.hibernatePolicy = policy
        applyLayout()
    }

    /// Deletes a profile like the delete-profile command, without the confirmation dialog, and waits
    /// until its data store is deleted (or left for the next launch).
    func testDelete(_ id: UUID) async {
        await performDelete(id)?.value
    }

    /// Destroys every profile without dialogs. The UI self-test then deletes their data stores.
    func testDestroyAll() {
        for id in profiles.map(\.id) {
            PopupWindowController.closeAll(for: id)
        }
        for pane in panes.values {
            pane.tearDown()
            pane.removeFromSuperview()
        }
        panes.removeAll()
        grid.show(.slot(0), views: [], sizes: nil)   // the splits let go of the panes
        emptySlots.removeAll()
        profiles.removeAll()
        hiddenSince.removeAll()
        housekeepingTimer?.invalidate()
        state.data.profiles.removeAll()
        state.data.layoutSlots.removeAll()
        state.save()
    }
}

/// The main window. A view that is not on screen cannot take the keyboard focus: hiding a profile
/// does not stop WebKit from focusing its page (a page that loads in the background can focus a
/// field), and keys typed then would go to a page you cannot see.
private final class MainWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, view.isHiddenOrHasHiddenAncestor { return false }
        return super.makeFirstResponder(responder)
    }
}

/// Runs a closure for a menu item. NSMenuItem.target is weak, so the item also keeps the action
/// as its representedObject.
@MainActor
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: Any?) {
        handler()
    }
}

@MainActor
private extension NSMenuItem {
    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
        let action = MenuAction(handler)
        target = action
        representedObject = action
    }
}
