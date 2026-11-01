import AppKit

/// Minimal splitter: its views sit side by side (horizontal) or are stacked from top to bottom
/// (vertical), and each view can be a pane or another split. Sizes follow ratios (equal by
/// default), dividers can be dragged, double-clicking a divider equalizes again, and the round
/// button on each divider between panes side by side swaps the panes next to it. NSSplitView is
/// deliberately not used: with Auto Layout it overrode divider positions with the panes' minimum
/// widths.
@MainActor
final class PaneSplitView: NSView {
    static let minimumPaneWidth: CGFloat = 200
    /// The pane toolbar (32 pt) plus room for the page.
    static let minimumPaneHeight: CGFloat = 160
    static let dividerThickness: CGFloat = 6

    /// Side by side or stacked.
    var axis: SplitAxis = .horizontal {
        didSet { if axis != oldValue { setPanes(panes) } }
    }
    var ratios: [CGFloat] = []
    var onRatiosChanged: (([CGFloat]) -> Void)?
    /// Called with the divider's index when its swap button is clicked.
    var onSwapRequested: ((Int) -> Void)?
    /// The views in order, left to right or top to bottom: panes or nested splits.
    private(set) var panes: [NSView] = []
    private(set) var swapButtons: [PaneSwapButton] = []
    private var dividers: [PaneDividerView] = []
    private let dividerThickness = PaneSplitView.dividerThickness

    /// Shows `views` in this order. Views that are already shown stay where they are in the view
    /// hierarchy (a web view that leaves the window stops drawing for a moment); only views that
    /// come or go are added or removed.
    func setPanes(_ views: [NSView]) {
        // A view that has moved into another split in the meantime stays where it is.
        for view in panes where view.superview === self && !views.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        dividers.forEach { $0.removeFromSuperview() }
        swapButtons.forEach { $0.removeFromSuperview() }
        panes = views
        dividers = []
        swapButtons = []
        for view in views where view.superview !== self {
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
            // Only between panes side by side, where the button sits in the band of their
            // toolbars. Added last so they are drawn above the panes they overlap.
            if axis == .horizontal {
                for index in 0..<(views.count - 1) {
                    let button = PaneSwapButton()
                    button.owner = self
                    button.index = index
                    addSubview(button)
                    swapButtons.append(button)
                }
            }
        }
        // A frozen split has no panes: keep its ratios for when the panes come back.
        if !views.isEmpty && ratios.count != views.count { ratios = equalRatios(views.count) }
        needsLayout = true
    }

    /// Swaps the pane at `index` with the next one. Each pane keeps its size, and the views
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

    /// Nested splits get their frame from the parent's layout, which does not lay them out.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !panes.isEmpty else { return }
        if ratios.count != panes.count { ratios = equalRatios(panes.count) }
        let sum = ratios.reduce(0, +)
        let shares = sum > 0 ? ratios.map { $0 / sum } : equalRatios(panes.count)
        let total = length(of: bounds.size)
        let available = max(0, total - dividerThickness * CGFloat(panes.count - 1))
        var offset: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            let size = index == panes.count - 1 ? max(0, total - offset) : (available * shares[index]).rounded()
            pane.frame = frame(at: offset, size: size)
            offset += size
            if index < dividers.count {
                dividers[index].frame = frame(at: offset, size: dividerThickness)
                offset += dividerThickness
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

    /// The smallest size at which every pane keeps its minimum width and height.
    var minimumSize: NSSize {
        let sizes = panes.map(Self.minimumSize(of:))
        let dividers = dividerThickness * CGFloat(max(0, panes.count - 1))
        switch axis {
        case .horizontal:
            return NSSize(width: sizes.reduce(0) { $0 + $1.width } + dividers, height: sizes.map(\.height).max() ?? 0)
        case .vertical:
            return NSSize(width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height } + dividers)
        }
    }

    static func minimumSize(of view: NSView) -> NSSize {
        (view as? PaneSplitView)?.minimumSize ?? NSSize(width: minimumPaneWidth, height: minimumPaneHeight)
    }

    /// Moves divider `index` to `position`, measured from the leading edge (the left edge, or the
    /// top edge when stacked) to the divider. The views on both sides keep their minimum size.
    func dragDivider(at index: Int, to position: CGFloat) {
        guard index + 1 < panes.count, index + 1 < ratios.count else { return }
        let (before, after) = (panes[index], panes[index + 1])
        let start = offset(of: before)
        let end = offset(of: after) + length(of: after.frame.size)
        let clamped = min(max(position, start + length(of: Self.minimumSize(of: before))),
                          end - dividerThickness - length(of: Self.minimumSize(of: after)))
        let sizeBefore = clamped - start
        let sizeAfter = end - dividerThickness - clamped
        guard sizeBefore > 0, sizeAfter > 0 else { return }
        let pairShare = ratios[index] + ratios[index + 1]
        ratios[index] = pairShare * sizeBefore / (sizeBefore + sizeAfter)
        ratios[index + 1] = pairShare * sizeAfter / (sizeBefore + sizeAfter)
        needsLayout = true
    }

    func dividerDragEnded() {
        onRatiosChanged?(ratios)
    }

    /// Where the pointer puts the divider it drags, as a position for `dragDivider(at:to:)`.
    func dividerPosition(for event: NSEvent, thickness: CGFloat) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        // The pointer is in the middle of the divider.
        switch axis {
        case .horizontal: return point.x - thickness / 2
        case .vertical: return bounds.height - point.y - thickness / 2
        }
    }

    /// The size along the axis.
    private func length(of size: NSSize) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    /// Where a view starts along the axis, measured from the leading edge.
    private func offset(of view: NSView) -> CGFloat {
        axis == .horizontal ? view.frame.minX : bounds.height - view.frame.maxY
    }

    /// The frame at `offset` from the leading edge, `size` long along the axis.
    private func frame(at offset: CGFloat, size: CGFloat) -> NSRect {
        switch axis {
        case .horizontal: return NSRect(x: offset, y: 0, width: size, height: bounds.height)
        case .vertical: return NSRect(x: 0, y: bounds.height - offset - size, width: bounds.width, height: size)
        }
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
        addCursorRect(bounds, cursor: owner?.axis == .vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.equalize() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        let thickness = owner.axis == .horizontal ? bounds.width : bounds.height
        owner.dragDivider(at: index, to: owner.dividerPosition(for: event, thickness: thickness))
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
