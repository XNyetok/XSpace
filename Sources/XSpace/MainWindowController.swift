import AppKit
import WebKit

/// Main window: toolbar (workspaces, add profile, profile options, RAM indicator, Focus/All mode)
/// and the workspaces. Every profile from 0.5.0 became a workspace with its panes, and a new
/// profile gets one too, so for now the toolbar still reads as a list of profiles.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                  NSMenuItemValidation, NSMenuDelegate {
    private let state = StateStore.shared
    private(set) var profiles: [Profile] = []
    private var workspaceViews: [UUID: WorkspaceView] = [:]
    /// Since when each workspace has been off screen; drives automatic freezing.
    private var hiddenSince: [UUID: Date] = [:]
    private let workspacesContainer = WorkspacesContainerView()
    private let workspaceSwitcher = NSSegmentedControl()
    private let modeSwitcher = NSSegmentedControl(labels: ["Fokus", "Semua"], trackingMode: .selectOne, target: nil, action: nil)
    private let memoryMenu = NSMenu(title: "Memori")
    private var memoryItem: NSMenuToolbarItem?
    private let pressureWatcher = MemoryPressureWatcher()
    private var housekeepingTimer: Timer?

    var onWorkspacesChanged: (() -> Void)?

    private enum ToolbarID {
        static let workspaces = NSToolbarItem.Identifier("xspace.workspaces")
        static let add = NSToolbarItem.Identifier("xspace.add")
        static let more = NSToolbarItem.Identifier("xspace.more")
        static let memory = NSToolbarItem.Identifier("xspace.memory")
        static let mode = NSToolbarItem.Identifier("xspace.mode")
    }

    /// The workspaces in toolbar order.
    var workspaces: [WorkspaceState] { state.data.workspaces }

    var selectedWorkspace: WorkspaceState? {
        workspaces.first { $0.id == state.data.selectedWorkspaceID } ?? workspaces.first
    }

    /// The profile the profile commands act on: the one of the pane you are in (see targetPane).
    var selectedProfile: Profile? {
        targetPane?.profile ?? selectedWorkspace?.root.panes.first.flatMap { profile($0.profileID) } ?? profiles.first
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

    /// The pane the pane and profile commands act on: the one you are in, otherwise the first
    /// pane of the selected workspace.
    private var targetPane: PaneView? {
        focusedPane ?? defaultPane
    }

    /// The workspace that shows `pane`, and the pane's ID in its layout.
    private func locate(_ pane: PaneView) -> (workspace: WorkspaceView, paneID: UUID)? {
        for view in workspaceViews.values {
            if let id = view.paneID(of: pane) { return (view, id) }
        }
        return nil
    }

    func profile(_ id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// A workspace without a name of its own is named after the profiles of its panes.
    func title(of workspace: WorkspaceState) -> String {
        if let name = workspace.name, !name.isEmpty { return name }
        var seen = Set<UUID>()
        return workspace.root.panes
            .filter { seen.insert($0.profileID).inserted }
            .compactMap { profile($0.profileID)?.name }
            .joined(separator: " + ")
    }

    /// The color of the profile in the workspace's first pane.
    func color(of workspace: WorkspaceState) -> NSColor {
        workspace.root.panes.first.flatMap { profile($0.profileID)?.color } ?? Palette.color(0)
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
        loadWorkspaces()

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
        workspacesContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(workspacesContainer)
        NSLayoutConstraint.activate([
            workspacesContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            workspacesContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            workspacesContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            workspacesContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        window?.contentView = content
    }

    private func loadWorkspaces() {
        if state.data.profiles.isEmpty {
            state.data.addProfile(name: "Akun 1", colorIndex: 0)
            state.save()
        }
        profiles = state.data.profiles.map { Profile(state: $0) }
        for workspace in workspaces {
            attach(workspace)
        }
        modeSwitcher.selectedSegment = state.data.showAll ? 1 : 0
        rebuildSwitcher()
        applyVisibility()
    }

    private func attach(_ workspace: WorkspaceState) {
        let view = WorkspaceView(id: workspace.id, layout: workspace.root) { [weak self] id in self?.profile(id) }
        let id = workspace.id
        view.onLayoutChanged = { [weak self] root in
            self?.state.updateWorkspace(id) { $0.root = root }
        }
        view.isHidden = true
        workspaceViews[id] = view
        workspacesContainer.addWorkspace(view)
    }

    /// Brings the workspace views in line with the saved workspaces after these changed: the
    /// views of removed workspaces are destroyed, the others take over their new layout, and new
    /// workspaces get a view.
    private func syncWorkspaceViews() {
        let saved = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.root) })
        for (id, view) in workspaceViews {
            if let root = saved[id] {
                if root != view.layout { view.update(layout: root) }
            } else {
                view.destroy()
                workspacesContainer.removeWorkspace(view)
                workspaceViews[id] = nil
                hiddenSince[id] = nil
            }
        }
        for workspace in workspaces where workspaceViews[workspace.id] == nil {
            attach(workspace)
        }
    }

    /// Focus: only the selected workspace is shown. All: every workspace is stacked (grid).
    /// Off-screen workspaces are not rendered and are throttled by WebKit; when they get frozen
    /// (web views destroyed) is decided by the HibernatePolicy.
    private func applyVisibility() {
        let selectedID = selectedWorkspace?.id
        let now = Date()
        for workspace in workspaces {
            guard let view = workspaceViews[workspace.id] else { continue }
            let visible = state.data.showAll || workspace.id == selectedID
            view.isHidden = !visible
            if visible {
                hiddenSince[workspace.id] = nil
                view.wake()
            } else {
                if hiddenSince[workspace.id] == nil { hiddenSince[workspace.id] = now }
                if state.data.hibernatePolicy == .immediately { view.hibernate() }
            }
        }
        workspacesContainer.needsLayout = true
        let name = selectedWorkspace.map { title(of: $0) } ?? ""
        window?.title = state.data.showAll ? "XSpace — Semua profil" : "XSpace — \(name)"
        refreshMemoryIndicator()
    }

    private func rebuildSwitcher() {
        let workspaces = self.workspaces
        workspaceSwitcher.segmentCount = workspaces.count
        for (index, workspace) in workspaces.enumerated() {
            let name = title(of: workspace)
            workspaceSwitcher.setLabel(name, forSegment: index)
            workspaceSwitcher.setImage(Palette.dot(color(of: workspace)), forSegment: index)
            workspaceSwitcher.setImageScaling(.scaleNone, forSegment: index)
            workspaceSwitcher.setWidth(0, forSegment: index)
            workspaceSwitcher.setToolTip(index < 9 ? "\(name) (⌘\(index + 1))" : name, forSegment: index)
        }
        if let selected = selectedWorkspace, let index = workspaces.firstIndex(where: { $0.id == selected.id }) {
            workspaceSwitcher.selectedSegment = index
        }
        workspaceSwitcher.sizeToFit()
        workspaceSwitcher.invalidateIntrinsicContentSize()
        onWorkspacesChanged?()
    }

    func select(_ workspace: WorkspaceState) {
        state.data.selectedWorkspaceID = workspace.id
        state.scheduleSave()
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaceSwitcher.selectedSegment = index
        }
        applyVisibility()
    }

    func persistAll() {
        for (id, view) in workspaceViews {
            let root = view.currentLayout()
            state.updateWorkspace(id) { $0.root = root }
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
                self?.hibernateIdleWorkspaces()
                self?.refreshMemoryIndicator()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
        refreshMemoryIndicator()
    }

    /// Freezes workspaces that have been hidden for longer than the policy allows.
    func hibernateIdleWorkspaces(now: Date = Date()) {
        guard let limit = state.data.hibernatePolicy.idleSeconds else { return }
        for (id, since) in hiddenSince where now.timeIntervalSince(since) >= limit {
            guard let view = workspaceViews[id], view.isHidden, view.isAwake else { continue }
            view.hibernate()
        }
    }

    /// macOS reports memory pressure → freeze every workspace that is not on screen.
    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        guard state.data.hibernatePolicy.respondsToMemoryPressure else { return }
        let frozen = hibernateAllHidden()
        if frozen > 0 {
            NSLog("XSpace: memory pressure (%@) → froze %d hidden workspace(s)",
                  event.contains(.critical) ? "critical" : "warning", frozen)
        }
    }

    @discardableResult
    private func hibernateAllHidden() -> Int {
        var count = 0
        for view in workspaceViews.values where view.isHidden && view.isAwake {
            view.hibernate()
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
        hibernateIdleWorkspaces()
    }

    /// Memory per profile, over the panes it has in every workspace and its popups.
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
        let views = Array(workspaceViews.values)
        for profile in profiles {
            var panes: [PaneView] = []
            var onScreen = false
            for view in views {
                let own = view.panes.filter { $0.profile.id == profile.id }
                panes += own
                if !own.isEmpty && !view.isHidden { onScreen = true }
            }
            let webViews = panes.map(\.webView) + PopupWindowController.webViews(for: profile.id)
            var bytes: UInt64 = 0
            for webView in webViews {
                if anyWebView == nil { anyWebView = webView }
                bytes += measure(MemoryProbe.pid(of: webView, "_webProcessIdentifier"))
            }
            report.profiles.append(.init(name: profile.name, color: profile.color, bytes: bytes,
                                         panes: panes.count, hidden: !onScreen))
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
        freeze.isEnabled = workspaceViews.values.contains { $0.isHidden && $0.isAwake }
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
        for workspace in workspaces {
            guard let view = workspaceViews[workspace.id] else { continue }
            print("Workspace “\(title(of: workspace))”: \(view.isHidden ? "hidden" : "visible"), live panes: \(view.panes.count)")
            for pane in view.panes where !view.isHidden {
                let rect = pane.webView.convert(pane.webView.bounds, to: frameView)
                print("  pane (\(pane.profile.name)) \(Int(rect.width))×\(Int(rect.height)) — \(pane.webView.url?.absoluteString ?? "-")")
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
        [ToolbarID.workspaces, ToolbarID.add, ToolbarID.more, .flexibleSpace, ToolbarID.memory, .space, ToolbarID.mode]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.workspaces:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            workspaceSwitcher.trackingMode = .selectOne
            workspaceSwitcher.target = self
            workspaceSwitcher.action = #selector(workspaceSwitcherChanged(_:))
            item.view = workspaceSwitcher
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

    // MARK: Workspace and profile actions

    @objc func workspaceSwitcherChanged(_ sender: NSSegmentedControl) {
        guard workspaces.indices.contains(sender.selectedSegment) else { return }
        select(workspaces[sender.selectedSegment])
    }

    @objc func selectWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard workspaces.indices.contains(sender.tag) else { return }
        select(workspaces[sender.tag])
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

    /// Adds a profile with the default panes in a workspace of its own, and shows it.
    @discardableResult
    func createProfile(name: String) -> Profile {
        let usedColors = Set(profiles.map(\.colorIndex))
        let color = (0..<Palette.colors.count).first { !usedColors.contains($0) } ?? profiles.count
        let added = state.data.addProfile(name: name, colorIndex: color)
        let profile = Profile(state: added.profile)
        profiles.append(profile)
        attach(added.workspace)
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
            self.workspaceViews.values.forEach { $0.refreshAppearance() }
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
        workspaceViews.values.forEach { $0.refreshAppearance() }
        PopupWindowController.refreshAppearance(for: profile.id)
        rebuildSwitcher()
    }

    /// Swaps the pane you are in with its neighbor: the next one, or the previous one for the last.
    @objc func swapPanes(_ sender: Any?) {
        guard let pane = targetPane, let located = locate(pane) else { return }
        located.workspace.swapPaneWithNeighbor(located.paneID)
    }

    /// Gives the workspace of the pane you are in the default panes, in that pane's profile.
    @objc func resetPanes(_ sender: Any?) {
        guard let pane = targetPane, let located = locate(pane) else { return }
        located.workspace.resetToDefaults(profileID: pane.profile.id)
        rebuildSwitcher()
        applyVisibility()
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
        let removal = profile(id).map { DataStoreRemoval($0.store) }
        PopupWindowController.closeAll(for: id)
        state.data.removeProfile(id)
        // Its panes go from every workspace: WebKit releases a data store only after all of its
        // web views are gone.
        syncWorkspaceViews()
        profiles.removeAll { $0.id == id }
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
        guard let workspace = selectedWorkspace else { return nil }
        return workspaceViews[workspace.id]?.panes.first
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
            return workspaceViews.values.contains { $0.isHidden && $0.isAwake }
        case #selector(selectWorkspaceFromMenu(_:)):
            let isSelected = workspaces.indices.contains(menuItem.tag) && workspaces[menuItem.tag].id == selectedWorkspace?.id
            menuItem.state = isSelected ? .on : .off
        case #selector(deleteProfile(_:)):
            return profiles.count > 1
        case #selector(swapPanes(_:)):
            guard let pane = targetPane, let located = locate(pane) else { return false }
            return located.workspace.layout.parent(of: located.paneID) != nil
        case #selector(resetPanes(_:)):
            return targetPane != nil
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

    func testWorkspace(_ title: String) -> WorkspaceView? {
        workspaces.first { self.title(of: $0) == title }.flatMap { workspaceViews[$0.id] }
    }

    func testSelect(_ title: String) {
        if let workspace = workspaces.first(where: { self.title(of: $0) == title }) { select(workspace) }
    }

    func testWorkspace(id: UUID) -> WorkspaceView? {
        workspaceViews[id]
    }

    func testSelectWorkspace(id: UUID) {
        if let workspace = workspaces.first(where: { $0.id == id }) { select(workspace) }
    }

    /// Adds a workspace with the given layout and shows it (the window cannot create one yet).
    @discardableResult
    func testAddWorkspace(_ root: LayoutNode) -> UUID {
        let workspace = WorkspaceState(id: UUID(), name: nil, root: root)
        state.data.workspaces.append(workspace)
        attach(workspace)
        state.data.selectedWorkspaceID = workspace.id
        state.save()
        rebuildSwitcher()
        applyVisibility()
        return workspace.id
    }

    /// A profile's live panes, in every workspace.
    func testPanes(of profileID: UUID) -> [PaneView] {
        workspaces.compactMap { workspaceViews[$0.id] }.flatMap { view in
            view.panes.filter { $0.profile.id == profileID }
        }
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

    /// Destroys every workspace and profile without dialogs. The UI self-test then deletes the
    /// profiles' data stores.
    func testDestroyAll() {
        for id in profiles.map(\.id) {
            PopupWindowController.closeAll(for: id)
        }
        for view in workspaceViews.values {
            view.destroy()
            workspacesContainer.removeWorkspace(view)
        }
        workspaceViews.removeAll()
        profiles.removeAll()
        hiddenSince.removeAll()
        housekeepingTimer?.invalidate()
        state.data.profiles.removeAll()
        state.data.workspaces.removeAll()
        state.save()
    }
}
