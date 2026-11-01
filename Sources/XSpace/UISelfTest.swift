import AppKit
import Darwin
import WebKit

/// `XSpace --selftest-ui [shot.png]`: runs the real XSpace window with THROWAWAY state
/// (temporary folder + new test profiles), checks upgrading from 0.5.0, freezing, the layouts and
/// the zoom, showing and swapping profiles, the keyboard focus, the RAM indicator, new tabs and
/// popups, deleting a profile and the first start (welcome screen, start pages, shortcuts,
/// Beranda, deleting the last profile), then deletes everything. Real profiles are never touched.
/// With a .png argument it also saves snapshots: shot.png of the 1 + 3 layout, shot-welcome.png
/// of the welcome screen and shot-start.png of the start pages.
@MainActor
final class UISelfTest: NSObject, NSApplicationDelegate {
    private static let aiStudio = "https://aistudio.google.com/"
    private static let sheets = "https://docs.google.com/spreadsheets/"

    private let stateDirectory: URL
    private var failures = 0

    init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            try? FileManager.default.removeItem(at: stateDirectory)
            log(failures == 0 ? "\nRESULT: ALL PASSED" : "\nRESULT: \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    private func run() async {
        log("XSpace UI self-test — upgrading, freezing, layouts, keyboard focus, RAM indicator, deleting, "
            + "first start (throwaway state, test profiles)")

        log("\n[0] Upgrading from 0.5.0")
        // The window opens on a state.json as 0.5.0 left it: two test profiles with two panes each
        // (Google AI Studio | Google Sheets), the second one shown in Fokus mode.
        let (firstID, secondID) = (UUID(), UUID())
        let (first, second) = ("Uji 1", "Uji 2")
        write050State(first: (firstID, first), second: (secondID, second))
        let controller = MainWindowController()
        controller.showWindow(nil)
        controller.testSetPolicy(.memoryPressureOnly)
        check(controller.profiles.map(\.name) == [first, second]
              && StateStore.shared.data.profiles.map(\.url) == [Self.aiStudio, Self.aiStudio],
              "Every profile becomes one pane, with the page of its first pane")
        check(StateStore.shared.data.layout == .single && controller.testShown == [second],
              "Fokus becomes the single-profile layout, with the profile that was selected")
        StateStore.shared.save()
        let saved = savedState()
        let savedProfiles = saved["profiles"] as? [[String: Any]] ?? []
        check(saved["version"] as? Int == 3 && saved["layout"] as? String == "single"
              && savedProfiles.map { $0["id"] as? String } == [firstID.uuidString, secondID.uuidString]
              && savedProfiles.allSatisfy { profile in
                  (profile["panes"] as? [[String: Any]])?.compactMap { $0["url"] as? String } == [Self.aiStudio]
              }
              && saved["selectedProfileID"] as? String == secondID.uuidString && saved["showAll"] as? Bool == false,
              "The saved file has the layout, and for 0.5.0 every profile with one pane")
        // The first profile has been on screen before (until then it is not loaded at all).
        controller.testShow(first)
        controller.testShow(second)
        await pause(5)

        log("\n[1] Policy: only on memory pressure")
        check(controller.testPane(first) != nil && controller.testShown == [second],
              "A hidden profile stays alive until memory runs low")
        if let pane = controller.testPane(first) {
            // Kill the page process for real when allowed (unsandboxed builds). The App Sandbox
            // does not allow it, so there WebKit's termination callback is delivered directly.
            let pid = MemoryProbe.pid(of: pane.webView, "_webProcessIdentifier")
            let killed = pid.map { kill($0, SIGKILL) == 0 } ?? false
            if !killed {
                pane.webViewWebContentProcessDidTerminate(pane.webView)
            }
            await pause(2)
            // The flag means XSpace chose "reload later" over reloading now. After a real kill the
            // page must also not be loading again; when simulated, the page is still alive and may
            // be busy loading on its own, so that part is only checked for a real kill.
            check(pane.needsReloadWhenVisible && (!killed || !pane.webView.isLoading),
                  "A hidden pane whose process died is not reloaded in the background (\(killed ? "process killed" : "simulated"))")
            controller.testShow(first)
            check(!pane.needsReloadWhenVisible, "That pane is reloaded once it is shown again")
            controller.testShow(second)
            await pause(2)
        } else {
            check(false, "The hidden profile has its pane")
        }

        controller.handleMemoryPressure(.warning)
        check(controller.testPane(first) == nil, "Memory pressure → hidden profile frozen")
        check(controller.testPane(second) != nil, "The profile on screen is left alone")

        controller.testShow(first)
        await pause(6)
        let restoredHost = controller.testPane(first)?.webView.url?.host ?? "-"
        check(controller.testPane(first) != nil && controller.testShown == [first], "A frozen profile comes back when shown")
        let offline = ProcessInfo.processInfo.environment["XSPACE_SELFTEST_OFFLINE"] == "1"
        if offline {
            log("  SKIP  Page restore check (offline)")
        } else {
            check(restoredHost.hasSuffix("google.com"), "Pages are restored after freezing (\(restoredHost))")
        }

        log("\n[2] Policy: immediately when hidden")
        controller.testSetPolicy(.immediately)
        controller.testShow(second)
        check(controller.testPane(first) == nil, "A profile is frozen as soon as it is hidden")

        log("\n[3] Policy: after 15 minutes off screen")
        controller.testSetPolicy(.after15Minutes)
        controller.testShow(first)
        await pause(3)
        controller.hibernateIdleProfiles(now: Date().addingTimeInterval(14 * 60))
        check(controller.testPane(second) != nil, "Not frozen before 15 minutes")
        controller.hibernateIdleProfiles(now: Date().addingTimeInterval(16 * 60))
        check(controller.testPane(second) == nil, "Frozen after 15 minutes off screen")

        log("\n[4] Layouts and zoom")
        await checkLayouts(controller, first: first, second: second)
        checkZoom(controller)

        log("\n[5] Keyboard focus")
        checkKeyboardFocus(controller)

        log("\n[6] RAM indicator")
        let report = controller.memoryReport()
        log("   total \(report.totalText) — UI \(MemoryProbe.format(report.app)), GPU \(MemoryProbe.format(report.gpu)), networking \(MemoryProbe.format(report.network))")
        for usage in report.profiles {
            log("   \(usage.name): \(MemoryProbe.format(usage.bytes))\(usage.panes == 0 ? ", frozen" : "")\(usage.hidden ? ", hidden" : "")")
        }
        check(report.app > 0 && report.total > report.app, "Indicator reads app + page memory")

        if let shot = snapshotURL() {
            controller.testSetPolicy(.never)
            await pause(6)
            await controller.writeSnapshot(to: shot)
        }

        log("\n[7] New tabs and popups")
        await checkNewTabs(controller)

        log("\n[8] Deleting a profile")
        // Uji 5 is shown and has the keyboard focus, as when you delete the profile you are in.
        // Only its ID is kept here: holding the Profile would keep its data store alive.
        let fifth = controller.profiles.first { $0.name == "Uji 5" }?.id ?? UUID()
        let watch = controller.profiles.first { $0.id == fifth }.map {
            DeletionWatch(profile: $0, pane: controller.testPane($0.name))
        }
        let deleteStart = Date()
        await controller.testDelete(fifth)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(deleteStart))
        let released = watch?.xspaceReleased ?? false
        check(released, "XSpace lets go of a deleted profile" + (released ? "" : " (still alive: \(watch?.alive ?? "-"))"))
        check(controller.testShown == [first, second, "Uji 3", "Uji 4"],
              "A profile that was hidden takes the deleted profile's place (\(controller.testShown.map { $0 ?? "-" }))")
        let stores = await WKWebsiteDataStore.allDataStoreIdentifiers
        let queued = StateStore.shared.data.pendingDeletion.contains(fifth)
        let heldByWebKit = queued && released && watch?.storeReleased == false
        if heldByWebKit {
            // WebKit can hold a store for longer than DataStoreRemoval waits (seen once on macOS 26,
            // cause unknown). The app then deletes it at the next launch, so this is no failure;
            // the note records what was still alive. The cleanup below deletes it.
            log("  NOTE  WebKit still held the data store after \(seconds) s, so the app deletes it at "
                + "the next launch (still alive: \(watch?.alive ?? "-"))")
        } else {
            check(!queued && !stores.contains(fifth), "Deleting a profile deletes its data store right away (\(seconds) s)")
        }

        // The data stores of the test profiles are deleted at the end ([10]).
        var removals = controller.profiles.map { DataStoreRemoval($0.store) }
        // The deleted profile's store is still there if WebKit held it (see the note above) or if
        // the checks above failed. It belongs to the throwaway state, so it must not stay behind.
        if stores.contains(fifth), let removal = watch?.removal { removals.append(removal) }
        controller.testDestroyAll()
        controller.close()

        log("\n[9] First start: welcome screen and start pages")
        removals += await checkFirstStart()

        log("\n[10] Clean up")
        for removal in removals {
            await checkRemoval(removal, "Test profile \(removal.shortID)… deleted")
        }
    }

    /// [9]: a window without saved state shows the welcome screen and makes no profile; choosing a
    /// layout there makes a profile for each pane, every one on its start page; typing an address
    /// opens it; deleting the last profile brings the welcome screen back. Returns the removals of
    /// the data stores of the profiles it made.
    private func checkFirstStart() async -> [DataStoreRemoval] {
        StateStore.shared.data = AppStateData()
        let controller = MainWindowController()
        controller.showWindow(nil)
        func finish() -> [DataStoreRemoval] {
            let removals = controller.profiles.map { DataStoreRemoval($0.store) }
            controller.testDestroyAll()
            controller.close()
            return removals
        }
        guard let welcome = controller.testWelcome else {
            check(false, "Without profiles the window shows the welcome screen")
            return finish()
        }
        let toolbarItems = { controller.window?.toolbar?.items.filter { $0.itemIdentifier != .flexibleSpace } ?? [] }
        check(controller.profiles.isEmpty && StateStore.shared.data.profiles.isEmpty && controller.testGrid.isHidden
              && !toolbarItems().isEmpty && toolbarItems().allSatisfy(\.isHidden),
              "Without profiles the window shows the welcome screen instead of the toolbar items, and makes no profile")
        let welcomeFrame = controller.window?.frame
        check(welcome.cards.map(\.preset) == GridPreset.allCases.filter { $0 != .automatic },
              "The welcome screen offers every fixed layout")
        if let shot = snapshotURL("welcome") {
            await pause(1)
            await controller.writeSnapshot(to: shot)
        }
        if let window = controller.window {
            // Content that does not fit would make the window larger than its minimum size.
            let frame = window.frame
            window.setFrame(NSRect(origin: frame.origin, size: window.minSize), display: true)
            window.layoutIfNeeded()
            await pause(0.5)
            check(window.frame.size == window.minSize,
                  "The welcome screen fits the smallest window (\(Int(window.frame.width))×\(Int(window.frame.height)))")
            window.setFrame(frame, display: true)
        }

        welcome.cards.first { $0.preset == .twoByTwo }?.performClick(nil)
        let names = ["Akun 1", "Akun 2", "Akun 3", "Akun 4"]
        check(controller.testWelcome == nil && !controller.testGrid.isHidden && toolbarItems().allSatisfy { !$0.isHidden }
              && StateStore.shared.data.layout == .twoByTwo && controller.testShown == names,
              "Choosing 2 × 2 makes four profiles, one in each pane (\(controller.testShown.map { $0 ?? "-" }))")
        check(controller.window?.frame == welcomeFrame, "The window keeps its size")
        // Only checkStartPages holds the panes: a pane keeps its profile's data store alive, and
        // deleting the profiles below waits until their stores are released.
        guard await checkStartPages(controller, names: names) else { return finish() }

        // Deleting every profile, the last one included, brings the welcome screen back. The app
        // deletes their data stores; [10] checks that they are gone.
        let removals = controller.profiles.map { DataStoreRemoval($0.store) }
        for id in controller.profiles.map(\.id) {
            await controller.testDelete(id)
        }
        check(controller.testWelcome != nil && controller.profiles.isEmpty && StateStore.shared.data.profiles.isEmpty
              && controller.testGrid.isHidden && toolbarItems().allSatisfy(\.isHidden),
              "Deleting the last profile brings the welcome screen back")
        controller.close()
        return removals
    }

    /// [9], continued: the panes of 2 × 2 on their start pages, the keyboard focus, shortcuts for every
    /// profile, an address typed in one pane and a shortcut clicked in another, Beranda and Kembali,
    /// and removing a shortcut. False if a pane is missing.
    private func checkStartPages(_ controller: MainWindowController, names: [String]) async -> Bool {
        let panes = names.compactMap { controller.testPane($0) }
        guard panes.count == 4 else {
            check(false, "Every new profile has its pane")
            return false
        }
        // The same room on every screen, small ones included (CI runners have 1024 × 768): a pane of
        // 2 × 2 then has space for the profile's name, the search box and a row of four shortcuts.
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: true)
        check(panes.allSatisfy { $0.isShowingStartPage && $0.webView.url == nil && !$0.webView.isLoading }
              && StateStore.shared.data.profiles.allSatisfy { $0.url == nil },
              "Every pane shows its start page and loads nothing")
        let firstField = panes[0].focusTarget as? NSTextField
        check(controller.focusedPane === panes[0] && firstField?.currentEditor() != nil,
              "The first pane's address field has the keyboard focus")
        check(panes.allSatisfy { $0.testShortcutTitles == ["Tambah pintasan"] },
              "Without shortcuts a start page offers to add one (\(panes[0].testShortcutTitles ?? []))")

        // Shortcuts for every profile at once, as the dialog's checkbox adds them.
        let examples = [Shortcut(title: "Example", url: "https://example.com/"),
                        Shortcut(title: "Example Org", url: "https://example.org/"),
                        Shortcut(title: "Example Net", url: "https://example.net/")]
        controller.testChangeShortcuts { state in
            for shortcut in examples { state.addShortcut(shortcut, to: state.profiles[0].id, everywhere: true) }
        }
        let tiles = examples.map(\.title) + ["Tambah pintasan"]
        check(panes.allSatisfy { $0.testShortcutTitles == tiles }
              && StateStore.shared.data.profiles.allSatisfy { $0.shortcuts == examples },
              "Shortcuts added to every profile show on every start page (\(panes[3].testShortcutTitles ?? []))")
        if let shot = snapshotURL("start") {
            await pause(1)
            await controller.writeSnapshot(to: shot)
        }

        // Typing an address in the second pane and pressing Return.
        let typed = panes[1]
        if let field = typed.focusTarget as? NSTextField {
            controller.window?.makeFirstResponder(field)
            let editor = field.currentEditor() as? NSTextView
            editor?.insertText("example.com", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor?.insertNewline(nil)
        }
        check(!typed.isShowingStartPage && !typed.webView.isHidden && typed.webView.url?.host == "example.com"
              && controller.focusedPane === typed,
              "An address typed on the start page opens in its pane (\(typed.webView.url?.absoluteString ?? "-"))")
        check(StateStore.shared.data.profiles[1].url == "https://example.com",
              "The profile keeps that address as its page right away")

        // A shortcut in the third pane.
        panes[2].testClickShortcut("Example Org")
        check(!panes[2].isShowingStartPage && panes[2].webView.url?.host == "example.org"
              && StateStore.shared.data.profiles[2].url == "https://example.org/",
              "A shortcut opens its site in its pane, as the profile's page")
        check(panes[0].isShowingStartPage && panes[3].isShowingStartPage, "The other panes stay on their start page")

        // Beranda over the page of the second pane, and back.
        typed.homePane(nil)
        check(typed.isShowingStartPage && typed.webView.isHidden && typed.webView.url?.host == "example.com"
              && controller.focusedPane === typed && typed.testShortcutTitles == tiles,
              "Beranda shows the start page, with the page waiting behind it (\(typed.testShortcutTitles ?? []))")
        typed.backPane(nil)
        check(!typed.isShowingStartPage && !typed.webView.isHidden && typed.webView.url?.host == "example.com",
              "Kembali on the start page returns to that page")

        // Removing a shortcut in the first pane, as its menu does.
        panes[0].testRemoveShortcut("Example")
        check(panes[0].testShortcutTitles == ["Example Org", "Example Net", "Tambah pintasan"]
              && panes[3].testShortcutTitles == tiles
              && StateStore.shared.data.profiles.map(\.shortcuts.count) == [2, 3, 3, 3],
              "Removing a shortcut removes it from that profile only (\(panes[0].testShortcutTitles ?? []))")
        await pause(1)
        return true
    }

    /// [4]: switching layouts, swapping, sizes, empty slots, new profiles, showing a hidden profile,
    /// the pane menu, Ctrl-Cmd-G and the automatic layout. Starts with the single-profile layout
    /// showing `first`, and ends with 1 + 3 showing Uji 1–4 (Uji 5 hidden).
    private func checkLayouts(_ controller: MainWindowController, first: String, second: String) async {
        let grid = controller.testGrid
        controller.setLayout(.twoColumns)
        await pause(1)
        grid.layoutSubtreeIfNeeded()
        guard let a = controller.testPane(first), let b = controller.testPane(second) else {
            return check(false, "2 berdampingan shows both profiles")
        }
        check(controller.testShown == [first, second] && a.frame.maxX < b.frame.minX
              && controller.testSelectedInToolbar == [first, second],
              "2 berdampingan: the profile shown, then the other, both selected in the toolbar")

        controller.window?.makeFirstResponder(a.focusTarget)
        controller.swapPanes(nil)
        grid.layoutSubtreeIfNeeded()
        check(controller.testShown == [second, first] && b.frame.maxX < a.frame.minX
              && controller.testPane(first) === a && controller.focusedPane === a,
              "Tukar Posisi Pane: the two trade places, nothing reloads, and the focus stays")
        if let button = grid.splitView(at: [])?.swapButtons.first {
            button.performClick(nil)
            grid.layoutSubtreeIfNeeded()
            check(controller.testShown == [first, second] && a.frame.maxX < b.frame.minX, "The ⇄ button swaps them back")
        } else {
            check(false, "A ⇄ button between the two panes")
        }

        if let split = grid.splitView(at: []) {
            split.dragDivider(at: 0, to: 300)
            split.dividerDragEnded()
            controller.setLayout(.single)
            controller.setLayout(.twoColumns)
            grid.layoutSubtreeIfNeeded()
            check(abs(a.frame.width - 300) <= 1 && controller.testShown == [first, second],
                  "A layout keeps its profiles and its sizes (\(Int(a.frame.width)) pt)")
            let reset = NSMenuItem(title: "", action: #selector(MainWindowController.resetPaneSizes(_:)), keyEquivalent: "")
            let offered = controller.validateMenuItem(reset)
            controller.resetPaneSizes(nil)
            grid.layoutSubtreeIfNeeded()
            check(offered && abs(a.frame.width - b.frame.width) <= 1 && !controller.validateMenuItem(reset)
                  && StateStore.shared.data.layoutSizes["twoColumns"] == nil,
                  "Atur Ulang Ukuran Pane gives the panes the layout's own sizes back "
                  + "(\(Int(a.frame.width)) and \(Int(b.frame.width)) pt)")
        }

        controller.setLayout(.oneAndThree)
        check(controller.testShown == [first, second, nil, nil]
              && controller.emptySlotMenu(2).items.map(\.title) == ["Tambah Profil…"],
              "1 + 3 with two profiles: two empty slots, which offer a new profile")
        let third = controller.createProfile(name: "Uji 3").id
        let fourth = controller.createProfile(name: "Uji 4").id
        await pause(2)
        grid.layoutSubtreeIfNeeded()
        let names = [first, second, "Uji 3", "Uji 4"]
        let panes = names.compactMap { controller.testPane($0) }
        guard controller.testShown == names, panes.count == 4 else {
            return check(false, "New profiles fill the empty slots (\(controller.testShown.map { $0 ?? "-" }))")
        }
        let frames = panes.map { $0.convert($0.bounds, to: grid) }
        check(abs(frames[0].height - grid.bounds.height) < 1 && frames.dropFirst().allSatisfy { $0.minX >= frames[0].maxX }
              && frames[1].minY > frames[2].maxY && frames[2].minY > frames[3].maxY,
              "New profiles fill the empty slots: one profile as tall as the window on the left, three stacked on the right")
        check(Set(panes.map { ObjectIdentifier($0.profile.store) }).count == 4
              && panes.allSatisfy { $0.webView.configuration.websiteDataStore === $0.profile.store },
              "Every pane is its own profile, with its own data store")
        if let column = grid.splitView(at: [1]) {
            column.dragDivider(at: 0, to: 0)   // as small as it gets
            column.dividerDragEnded()
            grid.layoutSubtreeIfNeeded()
            let dragged = panes[1].frame.height
            controller.resetPaneSizes(nil)
            grid.layoutSubtreeIfNeeded()
            let heights = panes.dropFirst().map(\.frame.height)
            check(dragged < heights[0] - 10 && (heights.max() ?? 0) - (heights.min() ?? 0) <= 1,
                  "Atur Ulang Ukuran Pane: stacked panes too (\(Int(dragged)) pt, then \(heights.map { Int($0) }))")
        }

        controller.window?.makeFirstResponder(panes[2].focusTarget)
        controller.createProfile(name: "Uji 5")   // every slot is taken: it takes the place of Uji 3
        check(controller.testShown == [first, second, "Uji 5", "Uji 4"] && controller.testPane("Uji 3") === panes[2]
              && controller.testSelectedInToolbar == [first, second, "Uji 4", "Uji 5"],
              "A new profile takes the place of the pane you are in; the profile there stays alive, hidden")
        controller.testClickInToolbar("Uji 3")   // with the focus in Uji 5
        check(controller.testShown == names && controller.testPane("Uji 3") === panes[2],
              "Clicking a hidden profile in the toolbar shows it in the pane you are in, as it was")

        if let menu = controller.paneMenu(for: fourth), let index = menu.items.firstIndex(where: { $0.title == first }) {
            check(menu.items.first { $0.state == .on }?.title == "Uji 4", "The pane menu marks the pane's profile")
            menu.performActionForItem(at: index)
            check(controller.testShown == ["Uji 4", second, "Uji 3", first],
                  "The pane menu: a profile shown elsewhere trades places with it")
            if let back = controller.paneMenu(for: fourth), let item = back.items.firstIndex(where: { $0.title == first }) {
                back.performActionForItem(at: item)
            }
        } else {
            check(false, "The pane menu lists the profiles")
        }
        check(controller.testShown == names && third != fourth, "And back")

        controller.window?.makeFirstResponder(panes[1].focusTarget)
        controller.toggleSingleProfile(nil)
        check(controller.testShown == [second], "⌃⌘G shows only the profile you are in")
        controller.toggleSingleProfile(nil)
        check(controller.testShown == names, "⌃⌘G again: the layout before, with the same profiles")

        controller.setLayout(.automatic)
        check(controller.testShown == [first, second, "Uji 3", "Uji 4", "Uji 5"], "Otomatis shows every profile")
        controller.setLayout(.oneAndThree)
    }

    /// [4], continued: the zoom of every page follows the size of its pane; ⌘+ and ⌘0 change the
    /// zoom of the pane you are in, which its profile keeps, also when it is frozen; Zoom Otomatis.
    /// Layout 1 + 3 showing Uji 1–4 with Uji 5 hidden, as checkLayouts leaves it and as it ends.
    private func checkZoom(_ controller: MainWindowController) {
        let grid = controller.testGrid
        func panes() -> [PaneView] { ["Uji 1", "Uji 2", "Uji 3", "Uji 4"].compactMap { controller.testPane($0) } }
        func automatic(_ pane: PaneView) -> Int { PageZoom.automatic(for: pane.pageArea) }
        func saved(_ name: String) -> Int? { StateStore.shared.data.profiles.first { $0.name == name }?.zoomOffset }
        grid.layoutSubtreeIfNeeded()
        let shown = panes()
        guard shown.count == 4 else { return check(false, "Zoom: 1 + 3 shows Uji 1–4") }
        check(shown.allSatisfy { $0.testZoom == automatic($0) } && shown[1].testZoom < 100,
              "Every page follows the size of its pane (\(shown.map { "\($0.testZoom)%" }.joined(separator: ", ")))")

        controller.window?.makeFirstResponder(shown[1].focusTarget)
        controller.zoomInPane(nil)
        check(shown[1].testZoom == automatic(shown[1]) + 10 && shown[2].testZoom == automatic(shown[2])
              && saved("Uji 2") == 10,
              "⌘+ zooms in the pane you are in by 10%, and its profile keeps that")

        controller.testSetPolicy(.immediately)
        controller.testShow("Uji 5")   // in the place of Uji 2, which is frozen
        let frozen = controller.testPane("Uji 2") == nil
        controller.testSetPolicy(.after15Minutes)
        controller.testShow("Uji 2")   // back in its place; Uji 5 stays alive, hidden
        grid.layoutSubtreeIfNeeded()
        guard let thawed = controller.testPane("Uji 2") else { return check(false, "Uji 2 is shown again") }
        check(frozen && thawed !== shown[1] && thawed.testZoom == automatic(thawed) + 10
              && controller.testShown == ["Uji 1", "Uji 2", "Uji 3", "Uji 4"],
              "A profile keeps its zoom when it is frozen (\(thawed.testZoom)%)")

        controller.toggleSingleProfile(nil)   // only Uji 2, in the whole window
        grid.layoutSubtreeIfNeeded()
        check(controller.testShown == ["Uji 2"] && thawed.testZoom == automatic(thawed) + 10,
              "The profile's zoom stays on top of the automatic one when the pane grows (\(thawed.testZoom)%)")
        controller.toggleSingleProfile(nil)
        grid.layoutSubtreeIfNeeded()

        let toggle = NSMenuItem(title: "", action: #selector(MainWindowController.toggleAutomaticZoom(_:)), keyEquivalent: "")
        controller.toggleAutomaticZoom(nil)
        _ = controller.validateMenuItem(toggle)
        check(panes().map(\.testZoom) == [100, 110, 100, 100] && toggle.state == .off
              && !StateStore.shared.data.automaticZoom,
              "Zoom Otomatis off: every page at 100%, plus the profile's own zoom")
        controller.toggleAutomaticZoom(nil)
        _ = controller.validateMenuItem(toggle)
        controller.resetZoomPane(nil)   // ⌘0, with the keyboard focus in Uji 2
        check(toggle.state == .on && panes().allSatisfy { $0.testZoom == automatic($0) } && saved("Uji 2") == nil,
              "⌘0 goes back to the automatic zoom")

        // The controls in a pane's toolbar zoom that pane, also while you are in another one.
        let other = panes()[2]
        other.testClickZoom(1)
        check(other.testZoom == automatic(other) + 10 && other.testZoomControls.title == "\(other.testZoom)%"
              && saved("Uji 3") == 10 && thawed.testZoom == automatic(thawed) && controller.focusedPane === thawed,
              "+ in a pane's toolbar zooms in that pane only, while the keyboard focus stays where it is")
        other.testClickZoom(-1)
        other.testClickZoom(-1)
        check(other.testZoom == automatic(other) - 10 && saved("Uji 3") == -10, "− zooms it out")
        other.testClickZoom(0)
        check(other.testZoom == automatic(other) && saved("Uji 3") == nil, "A click on its zoom goes back to the automatic zoom")
        check(panes().allSatisfy { $0.testZoomControls.shown && $0.testZoomControls.title == "\($0.testZoom)%" && $0.testToolbarFits },
              "Every pane shows its zoom between − and + (\(panes().map(\.testZoomControls.title).joined(separator: ", ")))")

        if let split = grid.splitView(at: []) {
            split.dragDivider(at: 0, to: grid.bounds.width)   // the panes on the right as narrow as they get
            split.dividerDragEnded()
            grid.layoutSubtreeIfNeeded()
            let narrow = panes()[1]
            check(!narrow.testZoomControls.shown && narrow.testToolbarFits && panes()[0].testZoomControls.shown,
                  "A pane too narrow for them leaves the zoom controls out, and its toolbar still fits "
                  + "(\(Int(narrow.frame.width)) pt)")
            controller.resetPaneSizes(nil)
            grid.layoutSubtreeIfNeeded()
            check(panes().allSatisfy { $0.testZoomControls.shown && $0.testToolbarFits },
                  "They come back when the pane is wide enough")
        }
    }

    /// [7]: a page that asks for a new tab gets a note in its pane and no window; one that asks for a
    /// popup window with a size of its own, as sign-in windows do, gets the window, in its profile.
    /// The pages are the test's own, in the pane of Uji 1.
    private func checkNewTabs(_ controller: MainWindowController) async {
        guard let pane = controller.testPane("Uji 1") else { return check(false, "Uji 1 is shown") }
        let id = pane.profile.id
        func open(_ script: String) async {
            pane.testHideNote()
            pane.webView.loadHTMLString("<a id=link href='https://example.com/' target='_blank'>link</a>"
                                        + "<script>\(script)</script>", baseURL: nil)
            let deadline = Date().addingTimeInterval(3)
            while pane.testNote == nil && PopupWindowController.webViews(for: id).isEmpty && Date() < deadline {
                await pause(0.1)
            }
        }
        await open("document.getElementById('link').click()")
        check(pane.testNote == PaneView.newTabNote && PopupWindowController.webViews(for: id).isEmpty,
              "A link with target=\"_blank\" opens no window; the pane says that new tabs are not supported")
        await open("window.open('https://example.com/')")
        check(pane.testNote == PaneView.newTabNote && PopupWindowController.webViews(for: id).isEmpty,
              "window.open without a size opens no window either")
        await open("window.open('about:blank', 'xspace-test', 'width=400,height=300')")
        let popups = PopupWindowController.webViews(for: id)
        check(popups.count == 1 && pane.testNote == nil && popups.first?.configuration.websiteDataStore === pane.profile.store,
              "A popup window with a size of its own, as sign-in windows have, opens in its profile")
        PopupWindowController.closeAll(for: id)
    }

    /// [5]: the keyboard focus never stays in a page that is not on screen. Layout 1 + 3 with
    /// Uji 5 hidden; afterwards Uji 5 is shown instead of Uji 4.
    private func checkKeyboardFocus(_ controller: MainWindowController) {
        guard let hidden = controller.testPane("Uji 5"), let shown = controller.testPane("Uji 4") else {
            return check(false, "Uji 4 is shown and Uji 5 hidden but alive")
        }
        controller.window?.makeFirstResponder(shown.focusTarget)
        check(controller.window?.makeFirstResponder(hidden.focusTarget) == false && controller.focusedPane === shown,
              "A page that is not on screen cannot take the keyboard focus")
        controller.testClickInToolbar("Uji 5")
        check(controller.focusedPane === hidden && controller.testShown.contains("Uji 5") && !controller.testShown.contains("Uji 4"),
              "A profile shown from the toolbar takes the place and the keyboard focus of the pane you are in")
        check((controller.window?.firstResponder as? NSView)?.isHiddenOrHasHiddenAncestor != true,
              "No page that is not on screen has the keyboard focus")
    }

    // MARK: Helpers

    /// Writes state.json as XSpace 0.5.0 left it (see [0]): two profiles with the default panes, the
    /// second one selected in Fokus mode.
    private func write050State(first: (id: UUID, name: String), second: (id: UUID, name: String)) {
        func profile(_ id: UUID, _ name: String, colorIndex: Int) -> [String: Any] {
            ["id": id.uuidString, "name": name, "colorIndex": colorIndex,
             "panes": [Self.aiStudio, Self.sheets].map { ["url": $0] }]
        }
        var firstProfile = profile(first.id, first.name, colorIndex: 0)
        firstProfile["splitRatios"] = [0.3, 0.7]
        let state: [String: Any] = [
            "version": 1,
            "profiles": [firstProfile, profile(second.id, second.name, colorIndex: 1)],
            "selectedProfileID": second.id.uuidString,
            "showAll": false,
            "hibernatePolicy": "memoryPressureOnly",
            "pendingDeletion": [String](),
        ]
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: stateDirectory.appendingPathComponent("state.json"))
        } catch {
            check(false, "Writing a 0.5.0 state.json (\(error.localizedDescription))")
        }
    }

    /// Where to save a snapshot: the .png file given after --selftest-ui, or with "-<name>" added to
    /// its name. Nil without one.
    private func snapshotURL(_ name: String? = nil) -> URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest-ui"), index + 1 < args.count,
              args[index + 1].hasSuffix(".png") else { return nil }
        let file = URL(fileURLWithPath: args[index + 1])
        guard let name else { return file }
        return file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(name).png")
    }

    /// state.json as saved, as JSON.
    private func savedState() -> [String: Any] {
        guard let data = try? Data(contentsOf: StateStore.shared.fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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

/// Watches a profile while it is deleted (see [8]) without keeping anything alive: weak references
/// to XSpace's objects and the data store, and the PID of the pane's page process.
@MainActor
private final class DeletionWatch {
    private final class WeakBox {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    /// Deletes the store if the app could not (see [10]).
    let removal: DataStoreRemoval
    private let xspaceObjects: [(name: String, box: WeakBox)]
    private let store: WeakBox
    private let pids: [pid_t]

    init(profile: Profile, pane: PaneView?) {
        removal = DataStoreRemoval(profile.store)
        store = WeakBox(profile.store)
        var objects: [(name: String, box: WeakBox)] = [("profile", WeakBox(profile))]
        var pids: [pid_t] = []
        if let pane {
            objects.append(("pane", WeakBox(pane)))
            objects.append(("web view", WeakBox(pane.webView)))
            if let pid = MemoryProbe.pid(of: pane.webView, "_webProcessIdentifier") { pids.append(pid) }
        }
        xspaceObjects = objects
        self.pids = pids
    }

    /// XSpace no longer holds the profile, its pane or its web view.
    var xspaceReleased: Bool { xspaceObjects.allSatisfy { $0.box.object == nil } }

    var storeReleased: Bool { store.object == nil }

    /// What is still alive, for messages.
    var alive: String {
        var names = xspaceObjects.filter { $0.box.object != nil }.map { $0.name }
        if !storeReleased { names.append("data store") }
        let running = pids.filter { Self.isRunning($0) }
        if !running.isEmpty { names.append("page processes \(running.map { String($0) }.joined(separator: ", "))") }
        return names.isEmpty ? "nothing" : names.joined(separator: ", ")
    }

    /// Whether a process exists, with the process-info call the App Sandbox allows.
    private static func isRunning(_ pid: pid_t) -> Bool {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size
    }
}
