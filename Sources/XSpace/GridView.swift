import AppKit

/// Shows the profiles' panes in the slots of the layout (see GridNode). The panes of profiles that
/// are not shown stay alive in a hidden part of this view, where WebKit throttles them, until they
/// are frozen. The splits are kept while the layout keeps its shape, so a pane only moves when it
/// changes place.
@MainActor
final class GridView: NSView {
    private var tree: GridNode?
    private var rootView: NSView?
    /// The split views by their path in the tree: the indexes of the children from the root down.
    private var splitViews: [[Int]: PaneSplitView] = [:]
    private let hiddenPanes = NSView()

    /// The sizes of all splits, depth first, after a divider was dragged or double-clicked.
    var onSizesChanged: (([[Double]]) -> Void)?
    /// The swap button between two panes side by side: the two slots whose profiles trade places.
    var onSwapRequested: ((Int, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hiddenPanes.isHidden = true
        hiddenPanes.autoresizingMask = [.width, .height]
        addSubview(hiddenPanes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The split at `path` (for tests).
    func splitView(at path: [Int]) -> PaneSplitView? {
        splitViews[path]
    }

    /// Keeps a pane alive but out of sight: its profile is not shown.
    func hide(_ pane: NSView) {
        guard pane.superview !== hiddenPanes else { return }
        hiddenPanes.addSubview(pane)
    }

    /// Shows `tree`, with views[i] in slot i, and the splits at `sizes` (depth first; nil, or
    /// sizes that do not fit a split, give equal sizes).
    func show(_ tree: GridNode, views: [NSView], sizes: [[Double]]?) {
        let reusable = tree == self.tree ? splitViews : [:]
        let oldSplits = splitViews
        splitViews = [:]
        var splitIndex = 0
        let root = view(for: tree, path: [], views: views, sizes: sizes, splitIndex: &splitIndex, reusable: reusable)
        if rootView !== root {
            // Added first: a pane that becomes the root moves without leaving the window.
            root.frame = hiddenPanes.frame
            root.autoresizingMask = [.width, .height]
            addSubview(root, positioned: .below, relativeTo: hiddenPanes)
            if let oldRoot = rootView, oldRoot.superview === self { oldRoot.removeFromSuperview() }
            rootView = root
        }
        for (path, split) in oldSplits where splitViews[path] !== split {
            split.setPanes([])
            split.removeFromSuperview()
        }
        self.tree = tree
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hiddenPanes.frame = bounds
    }

    private func view(for node: GridNode, path: [Int], views: [NSView], sizes: [[Double]]?,
                      splitIndex: inout Int, reusable: [[Int]: PaneSplitView]) -> NSView {
        switch node {
        case .slot(let slot):
            return slot < views.count ? views[slot] : NSView()
        case .split(let axis, let children):
            let split = reusable[path] ?? makeSplit(at: path)
            split.axis = axis
            if let sizes, splitIndex < sizes.count, sizes[splitIndex].count == children.count,
               sizes[splitIndex].allSatisfy({ $0.isFinite && $0 > 0 }) {
                split.ratios = sizes[splitIndex].map { CGFloat($0) }
            } else {
                split.ratios = []
            }
            splitIndex += 1
            var childViews: [NSView] = []
            for (index, child) in children.enumerated() {
                childViews.append(view(for: child, path: path + [index], views: views, sizes: sizes,
                                       splitIndex: &splitIndex, reusable: reusable))
            }
            split.setPanes(childViews)
            splitViews[path] = split
            return split
        }
    }

    private func makeSplit(at path: [Int]) -> PaneSplitView {
        let split = PaneSplitView()
        split.onRatiosChanged = { [weak self] _ in self?.reportSizes() }
        split.onSwapRequested = { [weak self] index in self?.swap(at: path, index) }
        return split
    }

    private func reportSizes() {
        guard let tree else { return }
        var sizes: [[Double]] = []
        collectSizes(of: tree, path: [], into: &sizes)
        onSizesChanged?(sizes)
    }

    private func collectSizes(of node: GridNode, path: [Int], into sizes: inout [[Double]]) {
        guard case .split(_, let children) = node else { return }
        sizes.append(splitViews[path]?.ratios.map { Double($0) } ?? [])
        for index in children.indices {
            collectSizes(of: children[index], path: path + [index], into: &sizes)
        }
    }

    private func swap(at path: [Int], _ index: Int) {
        guard case .split(_, let children)? = tree?.node(at: path), index + 1 < children.count,
              case .slot(let first) = children[index], case .slot(let second) = children[index + 1] else { return }
        onSwapRequested?(first, second)
    }
}

/// An empty slot of a fixed layout: offers the profiles that are not shown, or a new profile.
@MainActor
final class EmptySlotView: NSView {
    var menuProvider: (() -> NSMenu?)?
    private let button = NSButton(title: "Pilih Profil…", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(choose(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.borderColor = NSColor.separatorColor.cgColor
            self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let menu = menuProvider?() else { return }
        let below = sender.isFlipped ? sender.bounds.maxY + 4 : sender.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: sender)
    }
}

extension GridPreset {
    /// A small picture of the layout for menus and the toolbar (a template image).
    var icon: NSImage {
        // The automatic layout is drawn as two rows of three.
        let tree = self.tree(slots: slotCount ?? 6)
        let image = NSImage(size: NSSize(width: 19, height: 14), flipped: true) { rect in
            NSColor.black.setFill()
            Self.draw(tree, in: rect.insetBy(dx: 0.5, dy: 0.5))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ node: GridNode, in rect: NSRect) {
        switch node {
        case .slot:
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        case .split(let axis, let children):
            let gap: CGFloat = 1.5
            let count = CGFloat(children.count)
            for (index, child) in children.enumerated() {
                let offset = CGFloat(index)
                switch axis {
                case .horizontal:
                    let width = (rect.width - gap * (count - 1)) / count
                    draw(child, in: NSRect(x: rect.minX + offset * (width + gap), y: rect.minY,
                                           width: width, height: rect.height))
                case .vertical:
                    let height = (rect.height - gap * (count - 1)) / count
                    draw(child, in: NSRect(x: rect.minX, y: rect.minY + offset * (height + gap),
                                           width: rect.width, height: height))
                }
            }
        }
    }
}
