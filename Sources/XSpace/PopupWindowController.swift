import AppKit
import WebKit

/// Popup window (window.open, "open in new tab", sign-in popups). Always uses the data
/// store of the profile it came from.
@MainActor
final class PopupWindowController: NSWindowController, NSWindowDelegate {
    private static var live: Set<PopupWindowController> = []

    let pane: PaneView

    init(profile: Profile, configuration: WKWebViewConfiguration, features: WKWindowFeatures, relativeTo parent: NSWindow?) {
        pane = PaneView(profile: profile, configuration: configuration, initialURL: nil)
        let width = max(CGFloat(features.width?.doubleValue ?? 1100), 420)
        let height = max(CGFloat(features.height?.doubleValue ?? 800), 320)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(profile.name) — memuat…"
        window.contentView = pane
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        pane.onRequestClose = { [weak self] in self?.close() }
        let name = profile.name
        pane.onTitleChange = { [weak self] title in
            self?.window?.title = title.isEmpty ? name : "\(name) — \(title)"
        }
        if let parent {
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 60, y: parent.frame.maxY - 60))
        } else {
            window.center()
        }
        Self.live.insert(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        pane.tearDown()
        Self.live.remove(self)
    }

    static func closeAll(for profileID: UUID) {
        for controller in Array(live) where controller.pane.profile.id == profileID {
            controller.close()
        }
    }

    static func webViews(for profileID: UUID) -> [WKWebView] {
        live.filter { $0.pane.profile.id == profileID }.map(\.pane.webView)
    }

    static func refreshAppearance(for profileID: UUID) {
        for controller in live where controller.pane.profile.id == profileID {
            controller.pane.refreshProfileAppearance()
        }
    }
}
