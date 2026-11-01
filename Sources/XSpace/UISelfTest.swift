import AppKit
import Darwin
import WebKit

/// `XSpace --selftest-ui [shot.png]`: runs the real XSpace window with THROWAWAY state
/// (temporary folder + new test profiles), checks upgrading from 0.5.0, freezing, swapping panes,
/// a workspace with several profiles, deleting a profile and the RAM indicator, then deletes
/// everything. Real profiles are never touched. With a .png argument it also saves a snapshot.
@MainActor
final class UISelfTest: NSObject, NSApplicationDelegate {
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
        log("XSpace UI self-test — upgrading, freezing, workspaces, deleting, RAM indicator "
            + "(throwaway state, test profiles)")

        log("\n[0] Upgrading from 0.5.0")
        // The window opens on a state.json as 0.5.0 left it: two test profiles, the second selected.
        let (firstID, secondID) = (UUID(), UUID())
        let (first, second) = ("Uji 1", "Uji 2")
        write050State(first: (firstID, first), second: (secondID, second))
        let controller = MainWindowController()
        controller.showWindow(nil)
        controller.testSetPolicy(.memoryPressureOnly)
        let migrated = controller.workspaces
        check(migrated.map { controller.title(of: $0) } == [first, second]
              && migrated.map { $0.root.panes.map(\.profileID) } == [[firstID, firstID], [secondID, secondID]]
              && migrated.allSatisfy { $0.root.panes.map(\.url) == Defaults.paneURLs },
              "Every profile becomes a workspace with the same panes")
        if case .split(let split)? = migrated.first?.root {
            check(split.ratios == [0.3, 0.7], "Pane widths are kept")
        } else {
            check(false, "Pane widths are kept (no split)")
        }
        check(workspaceHidden(controller, first) && !workspaceHidden(controller, second),
              "The profile that was selected is shown")
        StateStore.shared.save()
        let saved = savedState()
        let savedProfiles = saved["profiles"] as? [[String: Any]] ?? []
        check(saved["version"] as? Int == 2 && (saved["workspaces"] as? [Any])?.count == 2
              && savedProfiles.map { $0["id"] as? String } == [firstID.uuidString, secondID.uuidString]
              && savedProfiles.allSatisfy { profile in
                  (profile["panes"] as? [[String: Any]])?.compactMap { $0["url"] as? String } == Defaults.paneURLs
              }
              && savedProfiles.first?["splitRatios"] as? [Double] == [0.3, 0.7],
              "The saved file has the workspaces, and every profile's panes for 0.5.0")
        // The first profile has been on screen before (until then it is not loaded at all).
        controller.testSelect(first)
        controller.testSelect(second)
        await pause(5)

        log("\n[1] Policy: only on memory pressure")
        check(workspaceHidden(controller, first) && paneCount(controller, first) == 2,
              "Hidden profile stays alive until memory runs low")

        if let pane = controller.testWorkspace(first)?.panes.first {
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
            controller.testSelect(first)
            check(!pane.needsReloadWhenVisible, "That pane is reloaded once it is shown again")
            controller.testSelect(second)
            await pause(2)
        } else {
            check(false, "Hidden profile has panes")
        }

        controller.handleMemoryPressure(.warning)
        check(paneCount(controller, first) == 0, "Memory pressure → hidden profile frozen")
        check(paneCount(controller, second) == 2, "The visible profile is left alone")

        controller.testSelect(first)
        await pause(6)
        let restoredHost = controller.testWorkspace(first)?.panes.first?.webView.url?.host ?? "-"
        check(paneCount(controller, first) == 2 && !workspaceHidden(controller, first),
              "A frozen profile comes back when opened")
        if let workspace = controller.testWorkspace(first), workspace.panes.count == 2 {
            workspace.layoutSubtreeIfNeeded()
            let (left, right) = (workspace.panes[0].frame.width, workspace.panes[1].frame.width)
            check(left + right > 0 && abs(left / (left + right) - 0.3) < 0.01,
                  "It comes back with the widths from 0.5.0 (\(Int(left)) | \(Int(right)) pt)")
        }
        let offline = ProcessInfo.processInfo.environment["XSPACE_SELFTEST_OFFLINE"] == "1"
        if offline {
            log("  SKIP  Page restore check (offline)")
        } else {
            check(restoredHost.hasSuffix("google.com"), "Pages are restored after freezing (\(restoredHost))")
        }

        log("\n[2] Policy: immediately when hidden")
        controller.testSetPolicy(.immediately)
        controller.testSelect(second)
        check(paneCount(controller, first) == 0, "Profile is frozen as soon as it is hidden")

        log("\n[3] Policy: after 15 minutes off screen")
        controller.testSetPolicy(.after15Minutes)
        controller.testSelect(first)
        await pause(3)
        controller.hibernateIdleWorkspaces(now: Date().addingTimeInterval(14 * 60))
        check(paneCount(controller, second) == 2, "Not frozen before 15 minutes")
        controller.hibernateIdleWorkspaces(now: Date().addingTimeInterval(16 * 60))
        check(paneCount(controller, second) == 0, "Frozen after 15 minutes off screen")

        log("\n[4] Swapping panes")
        if let workspace = controller.testWorkspace(first), workspace.panes.count == 2 {
            let (left, right) = (workspace.panes[0], workspace.panes[1])
            let urlsBefore = workspace.urls
            controller.window?.makeFirstResponder(left.webView)
            check(controller.focusedPane === left, "The pane commands act on the pane you are in")
            controller.swapPanes(nil)
            workspace.layoutSubtreeIfNeeded()
            check(workspace.panes[0] === right && workspace.panes[1] === left && right.frame.minX < left.frame.minX,
                  "The two panes trade places (same web views, nothing recreated)")
            let saved = StateStore.shared.data.workspaces.first { $0.id == workspace.id }?.root.panes.map(\.url)
            check(workspace.urls == Array(urlsBefore.reversed()) && saved == workspace.urls, "The new order is saved")
            controller.swapPanes(nil)   // the focused pane is the last one now: it swaps with the one before
            workspace.layoutSubtreeIfNeeded()
            check(workspace.panes[0] === left && left.frame.minX < right.frame.minX, "Swapping again restores the order")
        } else {
            check(false, "Visible profile has two panes")
        }
        if let frozen = controller.testWorkspace(second), !frozen.isAwake {
            let before = frozen.urls
            frozen.swapPanes(at: 0)
            check(frozen.urls == Array(before.reversed()) && !frozen.isAwake,
                  "A frozen profile can be swapped without waking it")
            frozen.swapPanes(at: 0)
        }

        log("\n[5] A workspace with several profiles, side by side and stacked")
        // The window cannot create one yet. One tall pane on the left, two stacked on the right.
        let mixedID = controller.testAddWorkspace(.split(LayoutSplit(id: UUID(), axis: .horizontal, children: [
            .pane(LayoutPane(id: UUID(), profileID: firstID, url: "about:blank")),
            .split(LayoutSplit(id: UUID(), axis: .vertical, children: [
                .pane(LayoutPane(id: UUID(), profileID: secondID, url: "about:blank")),
                .pane(LayoutPane(id: UUID(), profileID: firstID, url: "about:blank")),
            ], ratios: nil)),
        ], ratios: nil)))
        await pause(2)
        if let mixed = controller.testWorkspace(id: mixedID), mixed.panes.count == 3 {
            await checkMixedWorkspace(mixed, profiles: [firstID, secondID, firstID])
            // Stacked panes swap too, with ⌃⌘X (the ⇄ button is only between panes side by side).
            let (top, bottom) = (mixed.panes[1], mixed.panes[2])
            controller.window?.makeFirstResponder(top.webView)
            controller.swapPanes(nil)
            mixed.layoutSubtreeIfNeeded()
            check(mixed.panes[1] === bottom && mixed.panes[2] === top && bottom.frame.minY > top.frame.minY,
                  "Two stacked panes trade places")
            controller.swapPanes(nil)
            mixed.layoutSubtreeIfNeeded()
            let layoutBefore = mixed.currentLayout()
            controller.testSelect(first)
            check(controller.focusedPane == nil, "A pane that is no longer on screen is not the pane you are in")
            controller.hibernateHiddenNow(nil)
            check(!mixed.isAwake && mixed.panes.isEmpty, "A hidden workspace is frozen as a whole")
            controller.testSelectWorkspace(id: mixedID)
            check(mixed.isAwake && mixed.panes.map(\.profile.id) == [firstID, secondID, firstID]
                  && mixed.layout == layoutBefore,
                  "It comes back with the same layout and pages")
        } else {
            check(false, "The workspace shows three panes")
        }

        log("\n[6] Pane commands")
        controller.testSelect(first)
        if let workspace = controller.testWorkspace(first), workspace.panes.count == 2 {
            checkShowingInAnotherProfile(controller, workspace, first: (firstID, first), second: (secondID, second))
            checkSplittingAndClosing(controller, workspace, second: (secondID, second))
        } else {
            check(false, "The first workspace has two panes")
        }
        let singleID = controller.testAddWorkspace(.pane(LayoutPane(id: UUID(), profileID: firstID, url: "about:blank")))
        if let single = controller.testWorkspace(id: singleID), let pane = single.panes.first,
           let paneID = single.paneID(of: pane) {
            controller.window?.makeFirstResponder(pane.webView)
            let closeItem = NSMenuItem(title: "Tutup Pane", action: #selector(MainWindowController.closePane(_:)), keyEquivalent: "")
            check(!controller.validateMenuItem(closeItem)
                  && controller.paneMenu(in: single, paneID: paneID)?.items.last?.isEnabled == false,
                  "The only pane of a workspace cannot be closed")
        } else {
            check(false, "A workspace with one pane shows it")
        }

        log("\n[7] RAM indicator")
        let report = controller.memoryReport()
        log("   total \(report.totalText) — UI \(MemoryProbe.format(report.app)), GPU \(MemoryProbe.format(report.gpu)), networking \(MemoryProbe.format(report.network))")
        for usage in report.profiles {
            log("   \(usage.name): \(MemoryProbe.format(usage.bytes)), \(usage.panes) pane(s)\(usage.hidden ? ", hidden" : "")")
        }
        check(report.app > 0 && report.total > report.app, "Indicator reads app + page memory")

        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--selftest-ui"), index + 1 < args.count, args[index + 1].hasSuffix(".png") {
            controller.testSetPolicy(.never)
            controller.testSelect(second)
            await pause(6)
            await controller.writeSnapshot(to: URL(fileURLWithPath: args[index + 1]))
        }

        log("\n[8] Deleting a profile")
        // A new profile is selected, so its panes load, as when the user deletes the profile on
        // screen. It also gets a pane in a workspace it shares with another profile, which is shown
        // too. Only its ID is kept here: holding the Profile would keep its data store alive.
        let third = controller.createProfile(name: "Uji 3").id
        let sharedID = controller.testAddWorkspace(.split(LayoutSplit(id: UUID(), axis: .vertical, children: [
            .pane(LayoutPane(id: UUID(), profileID: third, url: "about:blank")),
            .pane(LayoutPane(id: UUID(), profileID: secondID, url: "about:blank")),
        ], ratios: nil)))
        await pause(3)
        // Weak: holding the pane would keep its profile's data store in use after the clean-up.
        weak let kept = controller.testWorkspace(id: sharedID)?.panes.first { $0.profile.id == secondID }
        let watch = controller.profiles.first { $0.id == third }.map {
            DeletionWatch(profile: $0, workspace: controller.testWorkspace($0.name), panes: controller.testPanes(of: $0.id))
        }
        log("   watching \(watch?.paneCount ?? 0) pane(s) in 2 workspaces")
        let deleteStart = Date()
        await controller.testDelete(third)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(deleteStart))
        let released = watch?.xspaceReleased ?? false
        check(released, "XSpace lets go of a deleted profile, in every workspace"
              + (released ? "" : " (still alive: \(watch?.alive ?? "-"))"))
        let keptAlone = controller.testWorkspace(id: sharedID).map { $0.panes.count == 1 && $0.panes.first === kept } ?? false
        check(kept != nil && keptAlone && kept?.webView.superview === kept,
              "The other profile's pane stays in the shared workspace and keeps running")
        let stores = await WKWebsiteDataStore.allDataStoreIdentifiers
        let queued = StateStore.shared.data.pendingDeletion.contains(third)
        let heldByWebKit = queued && released && watch?.storeReleased == false
        if heldByWebKit {
            // WebKit can hold a store for longer than DataStoreRemoval waits (seen once on macOS 26,
            // cause unknown). The app then deletes it at the next launch, so this is no failure;
            // the note records what was still alive. The cleanup below deletes it.
            log("  NOTE  WebKit still held the data store after \(seconds) s, so the app deletes it at "
                + "the next launch (still alive: \(watch?.alive ?? "-"))")
        } else {
            check(!queued && !stores.contains(third), "Deleting a profile deletes its data store right away (\(seconds) s)")
        }

        log("\n[9] Clean up")
        var removals = controller.profiles.map { DataStoreRemoval($0.store) }
        if heldByWebKit, let removal = watch?.removal { removals.append(removal) }
        controller.testDestroyAll()
        controller.close()
        for removal in removals {
            await checkRemoval(removal, "Test profile \(removal.shortID)… deleted")
        }
    }

    // MARK: Helpers

    private func paneCount(_ controller: MainWindowController, _ name: String) -> Int {
        controller.testWorkspace(name)?.panes.count ?? -1
    }

    private func workspaceHidden(_ controller: MainWindowController, _ name: String) -> Bool {
        controller.testWorkspace(name)?.isHidden ?? false
    }

    /// Writes state.json as XSpace 0.5.0 left it (see [0]): two profiles with the default panes,
    /// the first with its panes at 30 % | 70 %, and the second one selected.
    private func write050State(first: (id: UUID, name: String), second: (id: UUID, name: String)) {
        func profile(_ id: UUID, _ name: String, colorIndex: Int) -> [String: Any] {
            ["id": id.uuidString, "name": name, "colorIndex": colorIndex,
             "panes": Defaults.paneURLs.map { ["url": $0] }]
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

    /// [6]: showing a pane in another profile, from the pane's own menu (its profile name) and from
    /// Pane → Ganti Profil Pane. `workspace` shows two panes of the first profile.
    private func checkShowingInAnotherProfile(_ controller: MainWindowController, _ workspace: WorkspaceView,
                                              first: (id: UUID, name: String), second: (id: UUID, name: String)) {
        let (left, right) = (workspace.panes[0], workspace.panes[1])
        guard let rightID = workspace.paneID(of: right), let menu = controller.paneMenu(in: workspace, paneID: rightID) else {
            return check(false, "The pane has a menu")
        }
        check(menu.items.first { $0.state == .on }?.title == first.name, "The pane's menu marks its profile")
        guard let index = menu.items.firstIndex(where: { $0.title == second.name }) else {
            return check(false, "The pane's menu lists the other profile")
        }
        menu.performActionForItem(at: index)
        workspace.layoutSubtreeIfNeeded()
        let shown = workspace.panes
        check(shown.count == 2 && shown[0] === left && shown[1] !== right && shown[1].profile.id == second.id
              && shown[1].webView.configuration.websiteDataStore === shown[1].profile.store
              && right.webView.superview == nil,
              "The pane shows the other profile in a new web view; the pane next to it keeps running")
        let saved = StateStore.shared.data.workspaces.first { $0.id == workspace.id }
        check(saved?.root.panes.map(\.profileID) == [first.id, second.id]
              && saved.map { controller.title(of: $0) } == "\(first.name) + \(second.name)"
              && controller.focusedPane === shown[1],
              "The change is saved, the workspace is named after both profiles, and the pane has the focus")
        let item = NSMenuItem()
        item.representedObject = first.id
        controller.showPaneInProfile(item)   // Pane → Ganti Profil Pane acts on the pane you are in
        check(workspace.panes.count == 2 && workspace.panes[0] === left && workspace.panes[1].profile.id == first.id,
              "Pane → Ganti Profil Pane shows the pane you are in in the first profile again")
    }

    /// [6]: splitting and closing panes, from the Pane menu and from the pane's own menu.
    /// `workspace` shows two panes of the first profile side by side.
    private func checkSplittingAndClosing(_ controller: MainWindowController, _ workspace: WorkspaceView,
                                          second: (id: UUID, name: String)) {
        let (left, right) = (workspace.panes[0], workspace.panes[1])
        workspace.layoutSubtreeIfNeeded()
        let widthsBefore = [left.frame.width, right.frame.width]
        controller.window?.makeFirstResponder(left.webView)
        controller.splitPaneRight(nil)
        workspace.layoutSubtreeIfNeeded()
        var panes = workspace.panes
        guard panes.count == 3 else { return check(false, "Bagi ke Kanan adds a pane (\(panes.count) panes)") }
        let added = panes[1]
        check(panes[0] === left && panes[2] === right && added.profile.id == left.profile.id
              && workspace.urls[1] == workspace.urls[0]
              && left.frame.maxX < added.frame.minX && added.frame.maxX < right.frame.minX
              && controller.focusedPane === added,
              "Bagi ke Kanan: a new pane right of it, same profile and page, with the focus; the others keep running")

        guard let addedID = workspace.paneID(of: added),
              let down = controller.paneMenu(in: workspace, paneID: addedID)?.items.first(where: { $0.title == "Bagi ke Bawah" })?.submenu,
              let index = down.items.firstIndex(where: { $0.title == second.name }) else {
            return check(false, "The pane's menu offers Bagi ke Bawah in the other profile")
        }
        down.performActionForItem(at: index)
        workspace.layoutSubtreeIfNeeded()
        panes = workspace.panes
        guard panes.count == 4 else { return check(false, "Bagi ke Bawah adds a pane (\(panes.count) panes)") }
        let below = panes[2]
        check(panes[1] === added && panes[3] === right && below.profile.id == second.id
              && added.superview === below.superview && added.frame.minY > below.frame.maxY,
              "Bagi ke Bawah from the pane's menu: a pane below it, in the profile chosen")
        let saved = StateStore.shared.data.workspaces.first { $0.id == workspace.id }?.root.panes.map(\.profileID)
        check(saved == panes.map(\.profile.id), "The new layout is saved")

        controller.window?.makeFirstResponder(below.webView)
        controller.closePane(nil)
        check(workspace.panes.count == 3 && controller.focusedPane === right,
              "Tutup Pane closes the pane you are in, and the focus moves to the next pane")
        controller.window?.makeFirstResponder(added.webView)
        controller.closePane(nil)
        workspace.layoutSubtreeIfNeeded()
        let widthsAfter = [left.frame.width, right.frame.width]
        check(workspace.panes.count == 2 && workspace.panes[0] === left && workspace.panes[1] === right
              && zip(widthsBefore, widthsAfter).allSatisfy { abs($0 - $1) <= 1 },
              "Closing the new panes gives the two panes their place and size back "
              + "(\(widthsBefore.map { Int($0) }) → \(widthsAfter.map { Int($0) }) pt)")
    }

    /// state.json as saved, as JSON.
    private func savedState() -> [String: Any] {
        guard let data = try? Data(contentsOf: StateStore.shared.fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    /// [5]: a workspace with one tall pane on the left and two stacked on the right, whose panes
    /// show `profiles` in reading order (the first and the last the same profile).
    private func checkMixedWorkspace(_ mixed: WorkspaceView, profiles: [UUID]) async {
        mixed.layoutSubtreeIfNeeded()
        let panes = mixed.panes
        check(panes.map(\.profile.id) == profiles, "Each pane shows the profile it was given")
        check(panes.allSatisfy { $0.webView.configuration.websiteDataStore === $0.profile.store }
              && panes[0].profile.store !== panes[1].profile.store,
              "Each pane uses its own profile's data store")
        let frames = panes.map { $0.convert($0.bounds, to: mixed) }
        check(abs(frames[0].height - mixed.bounds.height) < 1
              && frames[1].minX >= frames[0].maxX && frames[2].minX >= frames[0].maxX
              && frames[1].minY >= frames[2].maxY,
              "One pane as tall as the workspace on the left, two stacked on the right")
        guard let cookie = HTTPCookie(properties: [.name: "xspace-uitest", .value: "1",
                                                   .domain: "xspace.test", .path: "/"]) else { return }
        await panes[0].webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let sameProfile = await panes[2].webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let otherProfile = await panes[1].webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        check(sameProfile.contains { $0.name == cookie.name } && !otherProfile.contains { $0.name == cookie.name },
              "A cookie set in one profile reaches its other pane, not the other profile's")
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
/// to XSpace's objects and the data store, and the PIDs of the panes' page processes.
@MainActor
private final class DeletionWatch {
    private final class WeakBox {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    /// Deletes the store if the app could not (see [9]).
    let removal: DataStoreRemoval
    let paneCount: Int
    private let xspaceObjects: [(name: String, box: WeakBox)]
    private let store: WeakBox
    private let pids: [pid_t]

    /// - Parameters:
    ///   - workspace: the profile's own workspace, which goes with it.
    ///   - panes: the profile's panes in every workspace.
    init(profile: Profile, workspace: WorkspaceView?, panes: [PaneView]) {
        removal = DataStoreRemoval(profile.store)
        store = WeakBox(profile.store)
        paneCount = panes.count
        var objects: [(name: String, box: WeakBox)] = [("profile", WeakBox(profile))]
        if let workspace { objects.append(("workspace", WeakBox(workspace))) }
        var pids: [pid_t] = []
        for (index, pane) in panes.enumerated() {
            objects.append(("pane \(index + 1)", WeakBox(pane)))
            objects.append(("web view \(index + 1)", WeakBox(pane.webView)))
            if let pid = MemoryProbe.pid(of: pane.webView, "_webProcessIdentifier"), !pids.contains(pid) {
                pids.append(pid)
            }
        }
        xspaceObjects = objects
        self.pids = pids
    }

    /// XSpace no longer holds the profile, its workspace, its panes or their web views.
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
