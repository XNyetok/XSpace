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

/// Minimal horizontal splitter: pane widths follow ratios (equal by default), dividers can be
/// dragged, double-clicking a divider equalizes again, and the round button on each divider
/// swaps the panes next to it. NSSplitView is deliberately not used: with Auto Layout it
/// overrode divider positions with the panes' minimum widths.
@MainActor
final class PaneSplitView: NSView {
    var ratios: [CGFloat] = []
    var onRatiosChanged: (([CGFloat]) -> Void)?
    /// Called with the divider's index when its swap button is clicked.
    var onSwapRequested: ((Int) -> Void)?
    private(set) var panes: [NSView] = []
    private(set) var swapButtons: [PaneSwapButton] = []
    private var dividers: [PaneDividerView] = []
    private let dividerWidth: CGFloat = 6
    private let minimumPaneWidth: CGFloat = 200

    func setPanes(_ views: [NSView]) {
        panes.forEach { $0.removeFromSuperview() }
        dividers.forEach { $0.removeFromSuperview() }
        swapButtons.forEach { $0.removeFromSuperview() }
        panes = views
        dividers = []
        swapButtons = []
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
            // Added last so they are drawn above the panes they overlap.
            for index in 0..<(views.count - 1) {
                let button = PaneSwapButton()
                button.owner = self
                button.index = index
                addSubview(button)
                swapButtons.append(button)
            }
        }
        // A frozen row has no panes: keep its ratios for when the panes come back.
        if !views.isEmpty && ratios.count != views.count { ratios = equalRatios(views.count) }
        needsLayout = true
    }

    /// Swaps the pane at `index` with the next one. Each pane keeps its width, and the views
    /// stay in place in the view hierarchy (only their frames change).
    func swapPanes(at index: Int) {
        if index >= 0, index + 1 < panes.count { panes.swapAt(index, index + 1) }
        if index >= 0, index + 1 < ratios.count { ratios.swapAt(index, index + 1) }
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
        // Each swap button sits on its divider, in the band of the panes' toolbars.
        let size = PaneSwapButton.size
        for (index, button) in swapButtons.enumerated() where index < dividers.count {
            button.frame = NSRect(x: (dividers[index].frame.midX - size / 2).rounded(),
                                  y: (bounds.height - PaneView.toolbarHeight / 2 - size / 2).rounded(),
                                  width: size, height: size)
        }
    }

    func dragDivider(at index: Int, toX proposedX: CGFloat) {
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

    func dividerDragEnded() {
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

/// The small round ⇄ button between two panes: swaps them.
@MainActor
final class PaneSwapButton: NSButton {
    static let size: CGFloat = 20

    weak var owner: PaneSplitView?
    var index = 0
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Tukar posisi pane")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        toolTip = "Tukar posisi pane (⌃⌘X)"
        setAccessibilityLabel("Tukar posisi pane")
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        layer?.borderWidth = 1
        target = self
        action = #selector(swapClicked(_:))
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func swapClicked(_ sender: Any?) {
        owner?.onSwapRequested?(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshColors()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshColors()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)   // not the divider's resize cursor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = (self.hovering ? NSColor.controlAccentColor : NSColor.windowBackgroundColor).cgColor
            self.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        contentTintColor = hovering ? .white : .secondaryLabelColor
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
