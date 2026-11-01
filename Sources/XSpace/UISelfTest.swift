import AppKit
import Darwin
import WebKit

/// `XSpace --selftest-ui [shot.png]`: runs the real XSpace window with THROWAWAY state
/// (temporary folder + new test profiles), checks upgrading from 0.5.0, freezing, the layouts,
/// showing and swapping profiles, the keyboard focus, the RAM indicator, deleting a profile and
/// the first start (welcome screen, start pages, deleting the last profile), then deletes
/// everything. Real profiles are never touched. With a .png argument it also saves snapshots:
/// shot.png of the 1 + 3 layout, shot-welcome.png of the welcome screen and shot-start.png of the
/// start pages.
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

        log("\n[4] Layouts")
        await checkLayouts(controller, first: first, second: second)

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

        log("\n[7] Deleting a profile")
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

        // The data stores of the test profiles are deleted at the end ([9]).
        var removals = controller.profiles.map { DataStoreRemoval($0.store) }
        // The deleted profile's store is still there if WebKit held it (see the note above) or if
        // the checks above failed. It belongs to the throwaway state, so it must not stay behind.
        if stores.contains(fifth), let removal = watch?.removal { removals.append(removal) }
        controller.testDestroyAll()
        controller.close()

        log("\n[8] First start: welcome screen and start pages")
        removals += await checkFirstStart()

        log("\n[9] Clean up")
        for removal in removals {
            await checkRemoval(removal, "Test profile \(removal.shortID)… deleted")
        }
    }

    /// [8]: a window without saved state shows the welcome screen and makes no profile; choosing a
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
        // deletes their data stores; [9] checks that they are gone.
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

    /// [8], continued: the panes of 2 × 2 on their start pages, the keyboard focus, and an address
    /// typed in one of them. False if a pane is missing.
    private func checkStartPages(_ controller: MainWindowController, names: [String]) async -> Bool {
        let panes = names.compactMap { controller.testPane($0) }
        guard panes.count == 4 else {
            check(false, "Every new profile has its pane")
            return false
        }
        check(panes.allSatisfy { $0.isShowingStartPage && $0.webView.url == nil && !$0.webView.isLoading }
              && StateStore.shared.data.profiles.allSatisfy { $0.url == nil },
              "Every pane shows its start page and loads nothing")
        let firstField = panes[0].focusTarget as? NSTextField
        check(controller.focusedPane === panes[0] && firstField?.currentEditor() != nil,
              "The first pane's address field has the keyboard focus")
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
        check(panes[0].isShowingStartPage && panes[2].isShowingStartPage && panes[3].isShowingStartPage,
              "The other panes stay on their start page")
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
            grid.splitView(at: [])?.equalize()
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

/// Watches a profile while it is deleted (see [7]) without keeping anything alive: weak references
/// to XSpace's objects and the data store, and the PID of the pane's page process.
@MainActor
private final class DeletionWatch {
    private final class WeakBox {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    /// Deletes the store if the app could not (see [9]).
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
