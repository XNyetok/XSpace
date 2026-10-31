import AppKit

@main
enum XSpaceMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest-ui") {
            // Throwaway state; must be set before StateStore is touched for the first time.
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("xspace-uitest-\(UUID().uuidString)", isDirectory: true)
            setenv("XSPACE_STATE_DIR", directory.path, 1)
            let runner = UISelfTest(stateDirectory: directory)
            app.delegate = runner
            withExtendedLifetime(runner) { app.run() }
        } else if let mode = SelfTest.Mode(arguments: arguments) {
            let runner = SelfTest(mode: mode)
            app.delegate = runner
            withExtendedLifetime(runner) { app.run() }
        } else {
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
