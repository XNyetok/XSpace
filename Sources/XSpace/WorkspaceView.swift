import AppKit

/// One workspace: its panes arranged as in its layout, side by side and stacked, each pane in
/// the profile it was given (a workspace from 0.5.0: AI Studio | Sheets of one profile). Panes
/// are created the first time the workspace becomes visible (lazy loading) and can be frozen:
/// the web views are destroyed, and the layout with its URLs and sizes is kept.
@MainActor
final class WorkspaceView: NSView {
    let id: UUID
    /// The layout, with the URLs the panes last finished loading and the current sizes.
    private(set) var layout: LayoutNode
    private let profileWithID: (UUID) -> Profile?
    /// The live views by node ID; empty while the workspace is frozen.
    private var paneViews: [UUID: PaneView] = [:]
    private var splitViews: [UUID: PaneSplitView] = [:]
    private var rootView: NSView?

    var onLayoutChanged: ((LayoutNode) -> Void)?

    init(id: UUID, layout: LayoutNode, profile: @escaping (UUID) -> Profile?) {
        self.id = id
        self.layout = layout
        profileWithID = profile
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isAwake: Bool { rootView != nil }

    /// The live panes in reading order: left to right, top to bottom.
    var panes: [PaneView] { layout.panes.compactMap { paneViews[$0.id] } }

    /// The URL of every pane in reading order, also while frozen.
    var urls: [String] { layout.panes.map(\.url) }

    func wake() {
        guard isAwake else {
            rebuild()
            return
        }
        panes.forEach { $0.reloadIfNeeded() }
    }

    /// Destroys the web views (their processes exit, memory is returned) and keeps the layout.
    func hibernate() {
        guard isAwake else { return }
        layout = currentLayout()
        removeViews()
        onLayoutChanged?(layout)
    }

    /// Used when the workspace is removed: tear down without saving anything.
    func destroy() {
        onLayoutChanged = nil
        removeViews()
    }

    /// Takes over a layout that was changed elsewhere, for example by deleting a profile: panes
    /// that are still in it keep running (nothing reloads), the others are destroyed.
    func update(layout newLayout: LayoutNode) {
        layout = newLayout
        if isAwake { rebuild() }
    }

    /// The layout with the panes' current URLs.
    func currentLayout() -> LayoutNode {
        guard isAwake else { return layout }
        return layout.mapPanes { pane in
            guard let url = paneViews[pane.id]?.persistableURL else { return pane }
            var current = pane
            current.url = url
            return current
        }
    }

    /// The ID of `pane` in the layout, if it is one of this workspace's panes.
    func paneID(of pane: PaneView) -> UUID? {
        paneViews.first { $0.value === pane }?.key
    }

    /// Swaps the child at `index` of the outer split with the next one: for a workspace from
    /// 0.5.0, its two panes. The web views move as they are (nothing reloads), each keeps its
    /// size, and the new order is saved. A frozen workspace stays frozen.
    func swapPanes(at index: Int) {
        guard case .split(let split) = layout else { return }
        swapChildren(ofSplit: split.id, at: index)
    }

    /// Swaps the pane with the next one in its split, or with the previous one if it is the last,
    /// side by side or stacked. As with swapPanes(at:), nothing reloads.
    func swapPaneWithNeighbor(_ paneID: UUID) {
        guard let parent = layout.parent(of: paneID) else { return }
        let isLast = parent.index + 1 == parent.split.children.count
        swapChildren(ofSplit: parent.split.id, at: isLast ? parent.index - 1 : parent.index)
    }

    func resetToDefaults(profileID: UUID) {
        hibernate()
        layout = WorkspaceState(defaultFor: profileID).root
        onLayoutChanged?(layout)
        if !isHidden { wake() }
    }

    func refreshAppearance() {
        paneViews.values.forEach { $0.refreshProfileAppearance() }
    }

    // MARK: Views

    /// Builds the views for the layout. Panes that are already running move into the new views.
    private func rebuild() {
        let running = paneViews
        let oldSplits = Array(splitViews.values)
        let oldRoot = rootView
        paneViews = [:]
        splitViews = [:]
        let root = makeView(for: layout, reusing: running)
        for (paneID, pane) in running where paneViews[paneID] == nil {
            pane.tearDown()
        }
        // The panes that are kept have moved already, so this only removes what is left.
        oldSplits.forEach { $0.setPanes([]) }
        if let oldRoot, oldRoot !== root, oldRoot.superview === self {
            oldRoot.removeFromSuperview()
        }
        root.frame = bounds
        root.autoresizingMask = [.width, .height]
        if root.superview !== self { addSubview(root) }
        rootView = root
    }

    private func makeView(for node: LayoutNode, reusing running: [UUID: PaneView]) -> NSView {
        switch node {
        case .pane(let pane):
            guard let view = running[pane.id] ?? makePane(pane) else {
                return NSView()   // its profile is gone; never the case for a saved layout
            }
            paneViews[pane.id] = view
            return view
        case .split(let split):
            let view = PaneSplitView()
            view.axis = split.axis
            if let ratios = split.ratios { view.ratios = ratios.map { CGFloat($0) } }
            let splitID = split.id
            view.onRatiosChanged = { [weak self] ratios in self?.splitDidResize(splitID, ratios: ratios) }
            view.onSwapRequested = { [weak self] index in self?.swapChildren(ofSplit: splitID, at: index) }
            view.setPanes(split.children.map { makeView(for: $0, reusing: running) })
            splitViews[splitID] = view
            return view
        }
    }

    private func makePane(_ pane: LayoutPane) -> PaneView? {
        guard let profile = profileWithID(pane.profileID) else { return nil }
        let view = PaneView(profile: profile, configuration: nil, initialURL: URL(string: pane.url))
        let paneID = pane.id
        view.onURLChange = { [weak self] url in self?.paneDidNavigate(paneID, url: url) }
        return view
    }

    /// Destroys every pane and split view.
    private func removeViews() {
        paneViews.values.forEach { $0.tearDown() }
        paneViews.removeAll()
        splitViews.values.forEach { $0.setPanes([]) }
        splitViews.removeAll()
        rootView?.removeFromSuperview()
        rootView = nil
    }

    // MARK: Changes from the views

    private func splitDidResize(_ splitID: UUID, ratios: [CGFloat]) {
        layout = layout.updatingSplit(splitID) { $0.ratios = ratios.map { Double($0) } }
        onLayoutChanged?(layout)
    }

    private func swapChildren(ofSplit splitID: UUID, at index: Int) {
        layout = layout.updatingSplit(splitID) { $0.swapChildren(at: index) }
        splitViews[splitID]?.swapPanes(at: index)
        onLayoutChanged?(layout)
    }

    private func paneDidNavigate(_ paneID: UUID, url: String) {
        var changed = false
        layout = layout.mapPanes { pane in
            guard pane.id == paneID, pane.url != url else { return pane }
            changed = true
            var moved = pane
            moved.url = url
            return moved
        }
        if changed { onLayoutChanged?(layout) }
    }
}

/// Container for the workspaces. Visible workspaces share the height equally.
@MainActor
final class WorkspacesContainerView: NSView {
    private(set) var workspaceViews: [WorkspaceView] = []
    var spacing: CGFloat = 8

    override var isFlipped: Bool { true }

    func addWorkspace(_ view: WorkspaceView) {
        workspaceViews.append(view)
        addSubview(view)
        needsLayout = true
    }

    func removeWorkspace(_ view: WorkspaceView) {
        workspaceViews.removeAll { $0 === view }
        view.removeFromSuperview()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let visible = workspaceViews.filter { !$0.isHidden }
        guard !visible.isEmpty else { return }
        let count = CGFloat(visible.count)
        let height = max(0, (bounds.height - spacing * (count - 1)) / count)
        var y: CGFloat = 0
        for view in visible {
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + spacing
        }
    }
}
