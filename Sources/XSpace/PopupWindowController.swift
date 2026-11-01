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

    /// Whether a page asks for a popup window rather than a new tab, as browsers tell them apart:
    /// a popup window has a size or a position of its own, or leaves out bars, as sign-in windows
    /// do (window.open with "width=500,height=600", for example). A link with target="_blank" and
    /// window.open without such features ask for a new tab.
    static func isPopupWindow(_ features: WKWindowFeatures) -> Bool {
        isPopupWindow(size: [features.width, features.height, features.x, features.y],
                      bars: [features.menuBarVisibility, features.statusBarVisibility,
                             features.toolbarsVisibility, features.allowsResizing])
    }

    /// The same from the features a page gives: `size` its width, height, x and y, `bars` whether
    /// it wants the menu bar, status bar, toolbars and resizing (nil for what it does not say).
    nonisolated static func isPopupWindow(size: [NSNumber?], bars: [NSNumber?]) -> Bool {
        size.contains { $0 != nil } || bars.contains { $0?.boolValue == false }
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
