import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?
    private let profilesMenu = NSMenu(title: "Profil")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await StateStore.shared.purgePendingDeletions()
            let controller = MainWindowController()
            controller.onWorkspacesChanged = { [weak self] in self?.rebuildProfilesMenu() }
            self.controller = controller
            self.installMainMenu()
            controller.showWindow(nil)
            NSApp.activate()
            self.runSnapshotIfRequested()
        }
    }

    /// `XSpace --snapshot <file.png> [seconds]`: wait for pages to load, save a snapshot, then quit.
    private func runSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return }
        let path = args[index + 1]
        let seconds = index + 2 < args.count ? (Double(args[index + 2]) ?? 12) : 12
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self?.controller?.writeSnapshot(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controller?.showWindow(nil) }
        return true
    }

    private var isFlushingBeforeQuit = false

    /// Before quitting, save the layout and make WebKit write every profile's cookies to disk,
    /// so a session created moments ago survives the restart.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, !isFlushingBeforeQuit else { return .terminateNow }
        controller.persistAll()
        guard WebKitSupport.canFlushCookies, !controller.profiles.isEmpty else { return .terminateNow }
        isFlushingBeforeQuit = true
        // Callback based on purpose: AppKit now waits in a nested run loop, where Swift Tasks
        // and main-queue blocks may not run (e.g. when terminate was called from a Task).
        WebKitSupport.flushCookies(controller.profiles.map(\.store)) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.persistAll()
        StateStore.shared.save()
    }

    @objc func showMainWindow(_ sender: Any?) {
        controller?.showWindow(nil)
    }

    // MARK: Menu

    private func installMainMenu() {
        guard let controller else { return }
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "XSpace")
        appMenu.addItem(item("Tentang XSpace", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", []))
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Layanan", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Layanan")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(item("Sembunyikan XSpace", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Sembunyikan Lainnya", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Tampilkan Semua", #selector(NSApplication.unhideAllApplications(_:)), "", []))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Keluar dari XSpace", #selector(NSApplication.terminate(_:)), "q"))
        add(appMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Tutup Jendela", #selector(NSWindow.performClose(_:)), "w"))
        add(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Urungkan", Selector(("undo:")), "z"))
        editMenu.addItem(item("Ulangi", Selector(("redo:")), "z", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Potong", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(item("Salin", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Tempel", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(item("Tempel dan Cocokkan Gaya", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        editMenu.addItem(item("Hapus", #selector(NSText.delete(_:)), "", []))
        editMenu.addItem(item("Pilih Semua", #selector(NSText.selectAll(_:)), "a"))
        add(editMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "Tampilan")
        viewMenu.addItem(item("Tampilkan Semua Profil", #selector(MainWindowController.toggleShowAll(_:)), "g", [.command, .control], target: controller))
        let ramMenu = NSMenu(title: "Hemat RAM")
        ramMenu.addItem(item("Bekukan Profil Tersembunyi Sekarang", #selector(MainWindowController.hibernateHiddenNow(_:)), "", [], target: controller))
        ramMenu.addItem(.separator())
        for policy in HibernatePolicy.allCases {
            let entry = item(policy.title, #selector(MainWindowController.setHibernatePolicy(_:)), "", [], target: controller)
            entry.representedObject = policy.rawValue
            ramMenu.addItem(entry)
        }
        let ramHolder = NSMenuItem(title: "Hemat RAM", action: nil, keyEquivalent: "")
        ramHolder.submenu = ramMenu
        viewMenu.addItem(ramHolder)
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Muat Ulang Pane", #selector(PaneView.reloadPane(_:)), "r"))
        viewMenu.addItem(item("Kembali", #selector(PaneView.backPane(_:)), "["))
        viewMenu.addItem(item("Maju", #selector(PaneView.forwardPane(_:)), "]"))
        viewMenu.addItem(item("Buka Lokasi…", #selector(PaneView.openLocation(_:)), "l"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Perbesar", #selector(PaneView.zoomInPane(_:)), "="))
        viewMenu.addItem(item("Perkecil", #selector(PaneView.zoomOutPane(_:)), "-"))
        viewMenu.addItem(item("Ukuran Asli", #selector(PaneView.actualSizePane(_:)), "0"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Layar Penuh", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        add(viewMenu, to: mainMenu)

        rebuildProfilesMenu()
        add(profilesMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "Jendela")
        windowMenu.addItem(item("Minimalkan", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), "", []))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Jendela Utama XSpace", #selector(showMainWindow(_:)), "0", [.command, .option], target: self))
        windowMenu.addItem(item("Bawa Semua ke Depan", #selector(NSApplication.arrangeInFront(_:)), "", []))
        add(windowMenu, to: mainMenu)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func rebuildProfilesMenu() {
        guard let controller else { return }
        profilesMenu.removeAllItems()
        profilesMenu.addItem(item("Tambah Profil…", #selector(MainWindowController.addProfile(_:)), "n", [.command, .shift], target: controller))
        profilesMenu.addItem(item("Ganti Nama Profil…", #selector(MainWindowController.renameProfile(_:)), "", [], target: controller))
        profilesMenu.addItem(item("Ganti Warna Profil", #selector(MainWindowController.cycleProfileColor(_:)), "", [], target: controller))
        profilesMenu.addItem(item("Tukar Posisi Pane", #selector(MainWindowController.swapPanes(_:)), "x", [.command, .control], target: controller))
        profilesMenu.addItem(item("Atur Ulang Pane ke Default", #selector(MainWindowController.resetPanes(_:)), "", [], target: controller))
        profilesMenu.addItem(item("Hapus Profil…", #selector(MainWindowController.deleteProfile(_:)), "", [], target: controller))
        profilesMenu.addItem(.separator())
        // The workspaces, like the switcher in the toolbar (⌘1–⌘9).
        for (index, workspace) in controller.workspaces.enumerated() {
            let entry = item(controller.title(of: workspace), #selector(MainWindowController.selectWorkspaceFromMenu(_:)),
                             index < 9 ? "\(index + 1)" : "", [.command], target: controller)
            entry.tag = index
            entry.image = Palette.dot(controller.color(of: workspace), diameter: 10)
            profilesMenu.addItem(entry)
        }
    }

    private func item(_ title: String, _ action: Selector?, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = target
        return menuItem
    }

    private func add(_ menu: NSMenu, to mainMenu: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        mainMenu.addItem(holder)
    }
}
