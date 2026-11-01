import AppKit
import WebKit

/// One row = one profile, with its panes side by side (default: AI Studio | Sheets).
/// Panes are created the first time the row becomes visible (lazy loading) and can be
/// frozen (web views destroyed, URLs kept) to give memory back.
@MainActor
final class ProfileRowView: NSView {
    let profile: Profile
    private(set) var urls: [String]
    private(set) var panes: [PaneView] = []
    private let split = PaneSplitView()

    var onURLsChanged: (([String]) -> Void)?
    var onRatiosChanged: (([Double]) -> Void)?

    init(profile: Profile, urls: [String], ratios: [Double]?) {
        self.profile = profile
        self.urls = urls.isEmpty ? Defaults.paneURLs : urls
        super.init(frame: .zero)
        if let ratios { split.ratios = ratios.map { CGFloat($0) } }
        split.onRatiosChanged = { [weak self] ratios in
            self?.onRatiosChanged?(ratios.map { Double($0) })
        }
        split.onSwapRequested = { [weak self] index in
            self?.swapPanes(at: index)
        }
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isAwake: Bool { !panes.isEmpty }

    func wake() {
        guard panes.isEmpty else {
            panes.forEach { $0.reloadIfNeeded() }
            return
        }
        for urlString in urls {
            let pane = PaneView(profile: profile, configuration: nil, initialURL: URL(string: urlString))
            // The index is looked up when the page navigates, because panes can be swapped.
            pane.onURLChange = { [weak self, weak pane] url in
                guard let self, let pane, let index = self.panes.firstIndex(where: { $0 === pane }) else { return }
                self.paneDidNavigate(index: index, url: url)
            }
            panes.append(pane)
        }
        split.setPanes(panes)
    }

    /// Swaps the pane at `index` with the one to its right. The web views move as they are
    /// (nothing reloads), each pane keeps its width, and the new order is saved. On a frozen row
    /// the panes come back in the new order.
    func swapPanes(at index: Int) {
        guard index >= 0, index + 1 < urls.count else { return }
        urls.swapAt(index, index + 1)
        if index + 1 < panes.count { panes.swapAt(index, index + 1) }
        split.swapPanes(at: index)
        onURLsChanged?(urls)
        if split.ratios.count == urls.count {
            onRatiosChanged?(split.ratios.map { Double($0) })
        }
    }

    /// Destroys the web views (their processes exit, memory is returned) and keeps the last URLs.
    func hibernate() {
        guard !panes.isEmpty else { return }
        urls = currentURLs()
        panes.forEach { $0.tearDown() }
        panes.removeAll()
        split.setPanes([])
        onURLsChanged?(urls)
    }

    /// Used when the profile is deleted: tear down without saving anything.
    func destroy() {
        onURLsChanged = nil
        onRatiosChanged = nil
        panes.forEach { $0.tearDown() }
        panes.removeAll()
        split.setPanes([])
    }

    func resetToDefaults() {
        hibernate()
        urls = Defaults.paneURLs
        onURLsChanged?(urls)
        split.equalize()
        if !isHidden { wake() }
    }

    func currentURLs() -> [String] {
        guard !panes.isEmpty else { return urls }
        return panes.enumerated().map { index, pane in
            pane.persistableURL ?? (index < urls.count ? urls[index] : Defaults.paneURLs[index % Defaults.paneURLs.count])
        }
    }

    func refreshAppearance() {
        panes.forEach { $0.refreshProfileAppearance() }
    }

    private func paneDidNavigate(index: Int, url: String) {
        guard index < urls.count, urls[index] != url else { return }
        urls[index] = url
        onURLsChanged?(urls)
    }
}

/// Container for the profile rows. Visible rows share the height equally.
@MainActor
final class RowsContainerView: NSView {
    private(set) var rows: [ProfileRowView] = []
    var spacing: CGFloat = 8

    override var isFlipped: Bool { true }

    func addRow(_ row: ProfileRowView) {
        rows.append(row)
        addSubview(row)
        needsLayout = true
    }

    func removeRow(_ row: ProfileRowView) {
        rows.removeAll { $0 === row }
        row.removeFromSuperview()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let visible = rows.filter { !$0.isHidden }
        guard !visible.isEmpty else { return }
        let count = CGFloat(visible.count)
        let height = max(0, (bounds.height - spacing * (count - 1)) / count)
        var y: CGFloat = 0
        for row in visible {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + spacing
        }
    }
}
