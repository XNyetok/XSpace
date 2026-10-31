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
        for (index, urlString) in urls.enumerated() {
            let pane = PaneView(profile: profile, configuration: nil, initialURL: URL(string: urlString))
            pane.onURLChange = { [weak self] url in self?.paneDidNavigate(index: index, url: url) }
            panes.append(pane)
        }
        split.setPanes(panes)
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

/// Minimal horizontal splitter: pane widths follow ratios (equal by default), dividers can be
/// dragged, and double-clicking a divider equalizes again. NSSplitView is deliberately not
/// used: with Auto Layout it overrode divider positions with the panes' minimum widths.
@MainActor
final class PaneSplitView: NSView {
    var ratios: [CGFloat] = []
    var onRatiosChanged: (([CGFloat]) -> Void)?
    private(set) var panes: [NSView] = []
    private var dividers: [PaneDividerView] = []
    private let dividerWidth: CGFloat = 6
    private let minimumPaneWidth: CGFloat = 200

    func setPanes(_ views: [NSView]) {
        panes.forEach { $0.removeFromSuperview() }
        dividers.forEach { $0.removeFromSuperview() }
        panes = views
        dividers = []
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        if views.count > 1 {
            for index in 0..<(views.count - 1) {
                let divider = PaneDividerView()
                divider.owner = self
                divider.index = index
                addSubview(divider)
                dividers.append(divider)
            }
        }
        if ratios.count != views.count { ratios = equalRatios(views.count) }
        needsLayout = true
    }

    func equalize() {
        ratios = equalRatios(max(panes.count, ratios.count))
        needsLayout = true
        onRatiosChanged?(ratios)
    }

    override func layout() {
        super.layout()
        guard !panes.isEmpty else { return }
        if ratios.count != panes.count { ratios = equalRatios(panes.count) }
        let sum = ratios.reduce(0, +)
        let normalized = sum > 0 ? ratios.map { $0 / sum } : equalRatios(panes.count)
        let available = max(0, bounds.width - dividerWidth * CGFloat(panes.count - 1))
        var x: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            let width = index == panes.count - 1 ? max(0, bounds.width - x) : (available * normalized[index]).rounded()
            pane.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
            if index < dividers.count {
                dividers[index].frame = NSRect(x: x, y: 0, width: dividerWidth, height: bounds.height)
                x += dividerWidth
            }
        }
    }

    fileprivate func dragDivider(at index: Int, toX proposedX: CGFloat) {
        guard index + 1 < panes.count else { return }
        let start = panes[index].frame.minX
        let end = panes[index + 1].frame.maxX
        let x = min(max(proposedX, start + minimumPaneWidth), end - dividerWidth - minimumPaneWidth)
        let leftWidth = x - start
        let rightWidth = end - dividerWidth - x
        guard leftWidth > 0, rightWidth > 0 else { return }
        let pairShare = ratios[index] + ratios[index + 1]
        ratios[index] = pairShare * leftWidth / (leftWidth + rightWidth)
        ratios[index + 1] = pairShare * rightWidth / (leftWidth + rightWidth)
        needsLayout = true
    }

    fileprivate func dividerDragEnded() {
        onRatiosChanged?(ratios)
    }

    private func equalRatios(_ count: Int) -> [CGFloat] {
        count > 0 ? Array(repeating: 1 / CGFloat(count), count: count) : []
    }
}

@MainActor
final class PaneDividerView: NSView {
    weak var owner: PaneSplitView?
    var index = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.equalize() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        let point = owner.convert(event.locationInWindow, from: nil)
        owner.dragDivider(at: index, toX: point.x - bounds.width / 2)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.dividerDragEnded()
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
