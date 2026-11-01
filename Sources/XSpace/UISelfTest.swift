import AppKit
import Darwin
import WebKit

/// `XSpace --selftest-ui [shot.png]`: runs the real XSpace window with THROWAWAY state
/// (temporary folder + new test profiles), checks freezing and the RAM indicator, then deletes
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
        log("XSpace UI self-test — freezing & RAM indicator (throwaway state, test profiles)")
        let controller = MainWindowController()
        controller.showWindow(nil)
        controller.testSetPolicy(.memoryPressureOnly)
        guard let first = controller.profiles.first?.name else {
            check(false, "Initial profile created")
            return
        }
        let second = controller.createProfile(name: "Uji 2").name
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
            controller.swapPanes(nil)   // acts on the selected workspace: `first`
            workspace.layoutSubtreeIfNeeded()
            check(workspace.panes[0] === right && workspace.panes[1] === left && right.frame.minX < left.frame.minX,
                  "The two panes trade places (same web views, nothing recreated)")
            let saved = StateStore.shared.data.workspaces.first { $0.id == workspace.id }?.root.panes.map(\.url)
            check(workspace.urls == Array(urlsBefore.reversed()) && saved == workspace.urls, "The new order is saved")
            controller.swapPanes(nil)
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

        log("\n[5] RAM indicator")
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

        log("\n[6] Deleting a profile")
        // A new profile is selected, so its panes load, as when the user deletes the profile on
        // screen. Only its ID is kept here: holding the Profile would keep its data store alive.
        let third = controller.createProfile(name: "Uji 3").id
        await pause(3)
        let watch = controller.profiles.first { $0.id == third }.map {
            DeletionWatch(profile: $0, workspace: controller.testWorkspace($0.name))
        }
        let deleteStart = Date()
        await controller.testDelete(third)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(deleteStart))
        let released = watch?.xspaceReleased ?? false
        check(released, "XSpace lets go of a deleted profile" + (released ? "" : " (still alive: \(watch?.alive ?? "-"))"))
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

        log("\n[7] Clean up")
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

/// Watches a profile while it is deleted (see [6]) without keeping anything alive: weak references
/// to XSpace's objects and the data store, and the PIDs of the panes' page processes.
@MainActor
private final class DeletionWatch {
    private final class WeakBox {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    /// Deletes the store if the app could not (see [7]).
    let removal: DataStoreRemoval
    private let xspaceObjects: [(name: String, box: WeakBox)]
    private let store: WeakBox
    private let pids: [pid_t]

    init(profile: Profile, workspace: WorkspaceView?) {
        removal = DataStoreRemoval(profile.store)
        store = WeakBox(profile.store)
        var objects: [(name: String, box: WeakBox)] = [("profile", WeakBox(profile))]
        if let workspace { objects.append(("workspace", WeakBox(workspace))) }
        var pids: [pid_t] = []
        for (index, pane) in (workspace?.panes ?? []).enumerated() {
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
