import AppKit
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
        check(rowHidden(controller, first) && paneCount(controller, first) == 2,
              "Hidden profile stays alive until memory runs low")

        if let pane = controller.testRow(first)?.panes.first,
           let pid = MemoryProbe.pid(of: pane.webView, "_webProcessIdentifier") {
            if kill(pid, SIGKILL) == 0 {
                await pause(2)
                check(pane.needsReloadWhenVisible && !pane.webView.isLoading,
                      "A hidden pane whose process died is not reloaded in the background")
            } else {
                log("  SKIP  Killing the page process is not permitted here (errno \(errno))")
            }
        } else {
            log("  SKIP  Page process ID not available")
        }

        controller.handleMemoryPressure(.warning)
        check(paneCount(controller, first) == 0, "Memory pressure → hidden profile frozen")
        check(paneCount(controller, second) == 2, "The visible profile is left alone")

        controller.testSelect(first)
        await pause(6)
        let restoredHost = controller.testRow(first)?.panes.first?.webView.url?.host ?? "-"
        check(paneCount(controller, first) == 2 && !rowHidden(controller, first),
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
        controller.hibernateIdleProfiles(now: Date().addingTimeInterval(14 * 60))
        check(paneCount(controller, second) == 2, "Not frozen before 15 minutes")
        controller.hibernateIdleProfiles(now: Date().addingTimeInterval(16 * 60))
        check(paneCount(controller, second) == 0, "Frozen after 15 minutes off screen")

        log("\n[4] RAM indicator")
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

        log("\n[5] Clean up")
        let ids = controller.testDestroyAll()
        controller.close()
        for id in ids {
            check(await WebKitSupport.removeDataStore(id), "Test profile \(id.uuidString.prefix(8))… deleted")
        }
    }

    // MARK: Helpers

    private func paneCount(_ controller: MainWindowController, _ name: String) -> Int {
        controller.testRow(name)?.panes.count ?? -1
    }

    private func rowHidden(_ controller: MainWindowController, _ name: String) -> Bool {
        controller.testRow(name)?.isHidden ?? false
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func check(_ ok: Bool, _ label: String) {
        log("\(ok ? "  PASS" : "  FAIL")  \(label)")
        if !ok { failures += 1 }
    }

    private func log(_ text: String) {
        print(text)
        fflush(stdout)
    }
}
