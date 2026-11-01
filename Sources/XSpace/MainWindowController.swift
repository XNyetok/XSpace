import AppKit
import WebKit

/// Main window: toolbar (profiles, add, options, RAM indicator, Focus/All mode) + profile rows.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                  NSMenuItemValidation, NSMenuDelegate {
    private let state = StateStore.shared
    private(set) var profiles: [Profile] = []
    private var rows: [UUID: ProfileRowView] = [:]
    /// Since when each profile has been off screen; drives automatic freezing.
    private var hiddenSince: [UUID: Date] = [:]
    private let rowsContainer = RowsContainerView()
    private let profileSwitcher = NSSegmentedControl()
    private let modeSwitcher = NSSegmentedControl(labels: ["Fokus", "Semua"], trackingMode: .selectOne, target: nil, action: nil)
    private let memoryMenu = NSMenu(title: "Memori")
    private var memoryItem: NSMenuToolbarItem?
    private let pressureWatcher = MemoryPressureWatcher()
    private var housekeepingTimer: Timer?

    var onProfilesChanged: (() -> Void)?

    private enum ToolbarID {
        static let profiles = NSToolbarItem.Identifier("xspace.profiles")
        static let add = NSToolbarItem.Identifier("xspace.add")
        static let more = NSToolbarItem.Identifier("xspace.more")
        static let memory = NSToolbarItem.Identifier("xspace.memory")
        static let mode = NSToolbarItem.Identifier("xspace.mode")
    }

    var selectedProfile: Profile? {
        if let id = state.data.selectedProfileID, let profile = profiles.first(where: { $0.id == id }) {
            return profile
        }
        return profiles.first
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
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
        rowsContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rowsContainer)
        NSLayoutConstraint.activate([
            rowsContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            rowsContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            rowsContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            rowsContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        window?.contentView = content
    }

    private func loadProfiles() {
        if state.data.profiles.isEmpty {
            let first = ProfileState(id: UUID(), name: "Akun 1", colorIndex: 0,
                                     panes: Defaults.paneURLs.map { PaneState(url: $0) })
            state.data.profiles = [first]
            state.data.selectedProfileID = first.id
            state.save()
        }
        for profileState in state.data.profiles {
            attach(Profile(state: profileState), urls: profileState.panes.map(\.url), ratios: profileState.splitRatios)
        }
        if state.data.selectedProfileID == nil || !profiles.contains(where: { $0.id == state.data.selectedProfileID }) {
            state.data.selectedProfileID = profiles.first?.id
        }
        modeSwitcher.selectedSegment = state.data.showAll ? 1 : 0
        rebuildSwitcher()
        applyVisibility()
    }

    private func attach(_ profile: Profile, urls: [String], ratios: [Double]? = nil) {
        profiles.append(profile)
        let row = ProfileRowView(profile: profile, urls: urls, ratios: ratios)
        let id = profile.id
        row.onURLsChanged = { [weak self] urls in
            self?.state.updateProfile(id) { $0.panes = urls.map { PaneState(url: $0) } }
        }
        row.onRatiosChanged = { [weak self] ratios in
            self?.state.updateProfile(id) { $0.splitRatios = ratios }
        }
        row.isHidden = true
        rows[id] = row
        rowsContainer.addRow(row)
    }

    /// Focus: only the selected profile is shown. All: every profile is stacked (grid).
    /// Off-screen profiles are not rendered and are throttled by WebKit; when they get frozen
    /// (web views destroyed) is decided by the HibernatePolicy.
    private func applyVisibility() {
        let selectedID = selectedProfile?.id
        let now = Date()
        for profile in profiles {
            guard let row = rows[profile.id] else { continue }
            let visible = state.data.showAll || profile.id == selectedID
            row.isHidden = !visible
            if visible {
                hiddenSince[profile.id] = nil
                row.wake()
            } else {
                if hiddenSince[profile.id] == nil { hiddenSince[profile.id] = now }
                if state.data.hibernatePolicy == .immediately { row.hibernate() }
            }
        }
        rowsContainer.needsLayout = true
        window?.title = state.data.showAll ? "XSpace — Semua profil" : "XSpace — \(selectedProfile?.name ?? "")"
        refreshMemoryIndicator()
    }

    private func rebuildSwitcher() {
        profileSwitcher.segmentCount = profiles.count
        for (index, profile) in profiles.enumerated() {
            profileSwitcher.setLabel(profile.name, forSegment: index)
            profileSwitcher.setImage(Palette.dot(profile.color), forSegment: index)
            profileSwitcher.setImageScaling(.scaleNone, forSegment: index)
            profileSwitcher.setWidth(0, forSegment: index)
            profileSwitcher.setToolTip(index < 9 ? "\(profile.name) (⌘\(index + 1))" : profile.name, forSegment: index)
        }
        if let selected = selectedProfile, let index = profiles.firstIndex(where: { $0.id == selected.id }) {
            profileSwitcher.selectedSegment = index
        }
        profileSwitcher.sizeToFit()
        profileSwitcher.invalidateIntrinsicContentSize()
        onProfilesChanged?()
    }

    func select(_ profile: Profile) {
        state.data.selectedProfileID = profile.id
        state.scheduleSave()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profileSwitcher.selectedSegment = index
        }
        applyVisibility()
    }

    func persistAll() {
        for profile in profiles {
            guard let row = rows[profile.id] else { continue }
            let urls = row.currentURLs()
            state.updateProfile(profile.id) { $0.panes = urls.map { PaneState(url: $0) } }
        }
        state.save()
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

    /// Freezes profiles that have been hidden for longer than the policy allows.
    func hibernateIdleProfiles(now: Date = Date()) {
        guard let limit = state.data.hibernatePolicy.idleSeconds else { return }
        for (id, since) in hiddenSince where now.timeIntervalSince(since) >= limit {
            guard let row = rows[id], row.isHidden, row.isAwake else { continue }
            row.hibernate()
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
        var count = 0
        for row in rows.values where row.isHidden && row.isAwake {
            row.hibernate()
            count += 1
        }
        refreshMemoryIndicator()
        return count
    }

    @objc func hibernateHiddenNow(_ sender: Any?) {
        hibernateAllHidden()
    }

    @objc func setHibernatePolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = HibernatePolicy(rawValue: raw) else { return }
        state.data.hibernatePolicy = policy
        state.scheduleSave()
        applyVisibility()
        hibernateIdleProfiles()
    }

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
            guard let row = rows[profile.id] else { continue }
            let webViews = row.panes.map(\.webView) + PopupWindowController.webViews(for: profile.id)
            var bytes: UInt64 = 0
            for webView in webViews {
                if anyWebView == nil { anyWebView = webView }
                bytes += measure(MemoryProbe.pid(of: webView, "_webProcessIdentifier"))
            }
            report.profiles.append(.init(name: profile.name, color: profile.color, bytes: bytes,
                                         panes: row.panes.count, hidden: row.isHidden))
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
                status = "\(MemoryProbe.format(usage.bytes)) · \(usage.panes) pane" + (usage.hidden ? " · tersembunyi" : "")
            }
            info("\(usage.name): \(status)", image: Palette.dot(usage.color, diameter: 10), indent: 1)
        }

        menu.addItem(.separator())
        let freeze = NSMenuItem(title: "Bekukan Profil Tersembunyi Sekarang", action: #selector(hibernateHiddenNow(_:)), keyEquivalent: "")
        freeze.target = self
        freeze.isEnabled = rows.values.contains { $0.isHidden && $0.isAwake }
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

        print("Window: \(Int(window.frame.width))×\(Int(window.frame.height)), mode: \(state.data.showAll ? "All" : "Focus")")
        var shots: [(NSImage, NSRect)] = []
        for profile in profiles {
            guard let row = rows[profile.id] else { continue }
            print("Profile “\(profile.name)”: \(row.isHidden ? "hidden" : "visible"), live panes: \(row.panes.count)")
            for pane in row.panes where !row.isHidden {
                let rect = pane.webView.convert(pane.webView.bounds, to: frameView)
                print("  pane \(Int(rect.width))×\(Int(rect.height)) — \(pane.webView.url?.absoluteString ?? "-")")
                if let image = try? await pane.webView.takeSnapshot(configuration: nil) {
                    shots.append((image, rect))
                }
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
            print("  \(usage.name): \(MemoryProbe.format(usage.bytes)), \(usage.panes) pane(s)\(usage.hidden ? ", hidden" : "")")
        }
        print("  TOTAL: \(report.totalText)")
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The space keeps the RAM indicator from touching the Focus/All switch.
        [ToolbarID.profiles, ToolbarID.add, ToolbarID.more, .flexibleSpace, ToolbarID.memory, .space, ToolbarID.mode]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.profiles:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            profileSwitcher.trackingMode = .selectOne
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
            menu.addItem(menuItem("Tukar Posisi Pane", #selector(swapPanes(_:))))
            menu.addItem(menuItem("Atur Ulang Pane ke Default", #selector(resetPanes(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("Hapus Profil…", #selector(deleteProfile(_:))))
            item.menu = menu
            item.showsIndicator = true
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
        case ToolbarID.mode:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            modeSwitcher.target = self
            modeSwitcher.action = #selector(modeChanged(_:))
            modeSwitcher.toolTip = "Fokus: satu profil. Semua: semua profil sekaligus (⌃⌘G)"
            item.view = modeSwitcher
            item.label = "Tampilan"
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

    @objc func profileSwitcherChanged(_ sender: NSSegmentedControl) {
        guard profiles.indices.contains(sender.selectedSegment) else { return }
        select(profiles[sender.selectedSegment])
    }

    @objc func selectProfileFromMenu(_ sender: NSMenuItem) {
        guard profiles.indices.contains(sender.tag) else { return }
        select(profiles[sender.tag])
    }

    @objc func modeChanged(_ sender: NSSegmentedControl) {
        setShowAll(sender.selectedSegment == 1)
    }

    @objc func toggleShowAll(_ sender: Any?) {
        setShowAll(!state.data.showAll)
    }

    private func setShowAll(_ value: Bool) {
        state.data.showAll = value
        state.scheduleSave()
        modeSwitcher.selectedSegment = value ? 1 : 0
        applyVisibility()
    }

    @objc func addProfile(_ sender: Any?) {
        guard let window else { return }
        askForText(title: "Tambah profil baru",
                   message: "Setiap profil punya login, cookie, dan data situs sendiri yang terpisah total dari profil lain.",
                   defaultValue: "Akun \(profiles.count + 1)", confirm: "Tambah", in: window) { [weak self] name in
            guard let self, let name else { return }
            self.createProfile(name: name)
        }
    }

    @discardableResult
    func createProfile(name: String) -> Profile {
        let usedColors = Set(profiles.map(\.colorIndex))
        let color = (0..<Palette.colors.count).first { !usedColors.contains($0) } ?? profiles.count
        let profileState = ProfileState(id: UUID(), name: name, colorIndex: color,
                                        panes: Defaults.paneURLs.map { PaneState(url: $0) })
        state.data.profiles.append(profileState)
        let profile = Profile(state: profileState)
        attach(profile, urls: profileState.panes.map(\.url))
        state.data.selectedProfileID = profileState.id
        state.save()
        rebuildSwitcher()
        applyVisibility()
        return profile
    }

    @objc func renameProfile(_ sender: Any?) {
        guard let window, let profile = selectedProfile else { return }
        askForText(title: "Ganti nama profil", message: "Nama hanya label; tidak mengubah akun Google-nya.",
                   defaultValue: profile.name, confirm: "Simpan", in: window) { [weak self] name in
            guard let self, let name else { return }
            profile.name = name
            self.state.updateProfile(profile.id) { $0.name = name }
            self.rows[profile.id]?.refreshAppearance()
            PopupWindowController.refreshAppearance(for: profile.id)
            self.rebuildSwitcher()
            self.applyVisibility()
        }
    }

    @objc func cycleProfileColor(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        profile.colorIndex = (profile.colorIndex + 1) % Palette.colors.count
        let colorIndex = profile.colorIndex
        state.updateProfile(profile.id) { $0.colorIndex = colorIndex }
        rows[profile.id]?.refreshAppearance()
        PopupWindowController.refreshAppearance(for: profile.id)
        rebuildSwitcher()
    }

    /// Swaps the two panes of the selected profile (the first two, should it have more).
    @objc func swapPanes(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        rows[profile.id]?.swapPanes(at: 0)
    }

    @objc func resetPanes(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        rows[profile.id]?.resetToDefaults()
    }

    @objc func deleteProfile(_ sender: Any?) {
        guard let window, let profile = selectedProfile else { return }
        guard profiles.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Profil terakhir tidak bisa dihapus"
            alert.informativeText = "Tambahkan profil lain dulu."
            alert.beginSheetModal(for: window)
            return
        }
        let id = profile.id
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hapus profil “\(profile.name)”?"
        alert.informativeText = "Semua login, cookie, dan data situs di profil ini akan dihapus permanen dari Mac ini. Akun Google-nya sendiri tidak terpengaruh."
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
        let removal = profiles.first { $0.id == id }.map { DataStoreRemoval($0.store) }
        PopupWindowController.closeAll(for: id)
        if let row = rows.removeValue(forKey: id) {
            row.destroy()
            rowsContainer.removeRow(row)
        }
        hiddenSince[id] = nil
        profiles.removeAll { $0.id == id }
        state.data.profiles.removeAll { $0.id == id }
        if state.data.selectedProfileID == id {
            state.data.selectedProfileID = profiles.first?.id
        }
        state.data.pendingDeletion.append(id)
        state.save()
        rebuildSwitcher()
        applyVisibility()
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

    // MARK: Pane actions (fallback when keyboard focus is not inside a pane)

    private var defaultPane: PaneView? {
        guard let profile = selectedProfile else { return nil }
        return rows[profile.id]?.panes.first
    }

    @objc func reloadPane(_ sender: Any?) { defaultPane?.reloadPane(sender) }
    @objc func backPane(_ sender: Any?) { defaultPane?.backPane(sender) }
    @objc func forwardPane(_ sender: Any?) { defaultPane?.forwardPane(sender) }
    @objc func openLocation(_ sender: Any?) { defaultPane?.openLocation(sender) }
    @objc func zoomInPane(_ sender: Any?) { defaultPane?.zoomInPane(sender) }
    @objc func zoomOutPane(_ sender: Any?) { defaultPane?.zoomOutPane(sender) }
    @objc func actualSizePane(_ sender: Any?) { defaultPane?.actualSizePane(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleShowAll(_:)):
            menuItem.state = state.data.showAll ? .on : .off
        case #selector(setHibernatePolicy(_:)):
            menuItem.state = (menuItem.representedObject as? String) == state.data.hibernatePolicy.rawValue ? .on : .off
        case #selector(hibernateHiddenNow(_:)):
            return rows.values.contains { $0.isHidden && $0.isAwake }
        case #selector(selectProfileFromMenu(_:)):
            let isSelected = profiles.indices.contains(menuItem.tag) && profiles[menuItem.tag].id == selectedProfile?.id
            menuItem.state = isSelected ? .on : .off
        case #selector(deleteProfile(_:)):
            return profiles.count > 1
        case #selector(swapPanes(_:)):
            return (selectedProfile.flatMap { rows[$0.id] }?.urls.count ?? 0) > 1
        case #selector(reloadPane(_:)), #selector(backPane(_:)), #selector(forwardPane(_:)),
             #selector(openLocation(_:)), #selector(zoomInPane(_:)), #selector(zoomOutPane(_:)),
             #selector(actualSizePane(_:)):
            return defaultPane != nil
        default:
            break
        }
        return true
    }

    // MARK: Hooks for the automated UI test (--selftest-ui)

    func testRow(_ name: String) -> ProfileRowView? {
        profiles.first { $0.name == name }.flatMap { rows[$0.id] }
    }

    func testSelect(_ name: String) {
        if let profile = profiles.first(where: { $0.name == name }) { select(profile) }
    }

    func testSetPolicy(_ policy: HibernatePolicy) {
        state.data.hibernatePolicy = policy
        applyVisibility()
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
            if let row = rows.removeValue(forKey: id) {
                row.destroy()
                rowsContainer.removeRow(row)
            }
        }
        profiles.removeAll()
        hiddenSince.removeAll()
        housekeepingTimer?.invalidate()
        state.data.profiles.removeAll()
        state.save()
    }
}
