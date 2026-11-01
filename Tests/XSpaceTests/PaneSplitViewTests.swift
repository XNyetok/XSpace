import AppKit
import XCTest
@testable import XSpace

/// Pane sizes: ratios, dragging a divider (with the minimum pane size), equalizing, swapping,
/// stacking and nesting.
final class PaneSplitViewTests: XCTestCase {
    @MainActor
    private func makeSplit(width: CGFloat, panes: Int, ratios: [CGFloat] = []) -> (PaneSplitView, [NSView]) {
        let split = PaneSplitView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        split.ratios = ratios
        let views = (0..<panes).map { _ in NSView() }
        split.setPanes(views)
        split.layout()
        return (split, views)
    }

    @MainActor
    func testPanesShareTheWidthEqually() {
        let (_, views) = makeSplit(width: 1006, panes: 2)   // 1000 pt for panes + one 6 pt divider
        XCTAssertEqual(views[0].frame, NSRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertEqual(views[1].frame, NSRect(x: 506, y: 0, width: 500, height: 300))
    }

    @MainActor
    func testSavedRatiosAreApplied() {
        let (_, views) = makeSplit(width: 1006, panes: 2, ratios: [1, 3])
        XCTAssertEqual(views.map(\.frame.width), [250, 750])
    }

    @MainActor
    func testRatiosForAnotherPaneCountAreReset() {
        let (_, views) = makeSplit(width: 1012, panes: 3, ratios: [0.2, 0.8])
        XCTAssertEqual(views.map(\.frame.width), [333, 333, 334])
    }

    @MainActor
    func testDraggingADividerKeepsTheMinimumPaneWidth() {
        let (split, views) = makeSplit(width: 1006, panes: 2)
        var reported: [CGFloat]?
        split.onRatiosChanged = { reported = $0 }

        split.dragDivider(at: 0, to: 300)
        split.layout()
        XCTAssertEqual(views.map(\.frame.width), [300, 700])

        split.dragDivider(at: 0, to: 20)   // too far: panes are at least 200 pt wide
        split.layout()
        XCTAssertEqual(views.map(\.frame.width), [200, 800])

        split.dragDivider(at: 0, to: 990)
        split.layout()
        XCTAssertEqual(views.map(\.frame.width), [800, 200])

        XCTAssertNil(reported, "ratios are reported once, when the drag ends")
        split.dividerDragEnded()
        XCTAssertEqual(reported?.count, 2)
    }

    @MainActor
    func testSwappingPanesKeepsTheirWidths() {
        let (split, views) = makeSplit(width: 1006, panes: 2, ratios: [0.3, 0.7])
        split.swapPanes(at: 0)
        split.layout()
        XCTAssertTrue(split.panes[0] === views[1] && split.panes[1] === views[0])
        XCTAssertEqual(views[1].frame, NSRect(x: 0, y: 0, width: 700, height: 300))
        XCTAssertEqual(views[0].frame, NSRect(x: 706, y: 0, width: 300, height: 300))
        XCTAssertEqual(split.ratios, [0.7, 0.3])
        XCTAssertTrue(views.allSatisfy { $0.superview === split }, "the views move; they are not removed")
    }

    /// A frozen row has no panes; its widths must still be there when it is opened again.
    @MainActor
    func testWidthsSurviveFreezing() {
        let (split, _) = makeSplit(width: 1006, panes: 2, ratios: [0.3, 0.7])
        split.setPanes([])
        let views = [NSView(), NSView()]
        split.setPanes(views)
        split.layout()
        XCTAssertEqual(views.map(\.frame.width), [300, 700])
    }

    @MainActor
    func testSwapButtonSitsOnTheDividerAndRequestsTheSwap() {
        let (split, _) = makeSplit(width: 1006, panes: 2)
        XCTAssertEqual(split.swapButtons.count, 1)
        let button = split.swapButtons[0]
        XCTAssertEqual(button.frame.midX, 503)   // the divider spans 500...506
        XCTAssertEqual(button.frame.maxY, 300 - (PaneView.toolbarHeight - PaneSwapButton.size) / 2,
                       "centered in the band of the pane toolbars")
        var requested: Int?
        split.onSwapRequested = { requested = $0 }
        button.performClick(nil)
        XCTAssertEqual(requested, 0)
        split.setPanes([])
        XCTAssertTrue(split.swapButtons.isEmpty && button.superview == nil, "a frozen row has no button")
    }

    @MainActor
    func testEqualizeResetsTheWidths() {
        let (split, views) = makeSplit(width: 1006, panes: 2, ratios: [0.3, 0.7])
        var reported: [CGFloat]?
        split.onRatiosChanged = { reported = $0 }
        split.equalize()
        split.layout()
        XCTAssertEqual(views.map(\.frame.width), [500, 500])
        XCTAssertEqual(reported, [0.5, 0.5])
    }

    // MARK: Stacked and nested

    @MainActor
    private func makeStack(height: CGFloat, panes: Int) -> (PaneSplitView, [NSView]) {
        let split = PaneSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        split.axis = .vertical
        let views = (0..<panes).map { _ in NSView() }
        split.setPanes(views)
        split.layout()
        return (split, views)
    }

    @MainActor
    func testStackedPanesShareTheHeightFromTheTop() {
        let (_, views) = makeStack(height: 606, panes: 2)
        XCTAssertEqual(views[0].frame, NSRect(x: 0, y: 306, width: 400, height: 300), "the first pane is on top")
        XCTAssertEqual(views[1].frame, NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    @MainActor
    func testDraggingAStackedDividerKeepsTheMinimumPaneHeight() {
        let (split, views) = makeStack(height: 1006, panes: 2)

        split.dragDivider(at: 0, to: 300)   // measured from the top
        split.layout()
        XCTAssertEqual(views.map(\.frame.height), [300, 700])
        XCTAssertEqual(views[0].frame.maxY, 1006)

        split.dragDivider(at: 0, to: 20)   // too far: panes are at least 160 pt high
        split.layout()
        XCTAssertEqual(views.map(\.frame.height), [160, 840])

        split.dragDivider(at: 0, to: 990)
        split.layout()
        XCTAssertEqual(views.map(\.frame.height), [840, 160])
    }

    @MainActor
    func testStackedPanesHaveNoSwapButton() {
        let (split, views) = makeSplit(width: 1006, panes: 2)
        XCTAssertEqual(split.swapButtons.count, 1)
        split.axis = .vertical
        XCTAssertTrue(split.swapButtons.isEmpty, "the button only fits between panes side by side")
        XCTAssertTrue(split.panes.elementsEqual(views, by: ===) && views.allSatisfy { $0.superview === split })
    }

    /// Swapping swaps two panes: there is no button next to a group of stacked panes.
    @MainActor
    func testTheSwapButtonOnlySitsBetweenTwoPanes() {
        let split = PaneSplitView(frame: NSRect(x: 0, y: 0, width: 1012, height: 300))
        let stack = PaneSplitView()
        stack.axis = .vertical
        stack.setPanes([NSView(), NSView()])
        split.setPanes([NSView(), NSView(), stack])
        split.layout()
        XCTAssertEqual(split.swapButtons.map(\.index), [0], "between the two panes, not next to the stack")
        XCTAssertEqual(split.swapButtons.first?.frame.midX, 336, "on the first divider (333...339)")
    }

    /// One tall pane on the left, three stacked on the right.
    @MainActor
    func testNestedSplitsAreLaidOut() {
        let root = PaneSplitView(frame: NSRect(x: 0, y: 0, width: 1006, height: 918))
        let right = PaneSplitView()
        right.axis = .vertical
        let stacked = (0..<3).map { _ in NSView() }
        right.setPanes(stacked)
        let left = NSView()
        root.setPanes([left, right])
        root.layout()
        right.layout()
        XCTAssertEqual(left.frame, NSRect(x: 0, y: 0, width: 500, height: 918))
        XCTAssertEqual(right.frame, NSRect(x: 506, y: 0, width: 500, height: 918))
        XCTAssertEqual(stacked.map(\.frame.height), [302, 302, 302])
        XCTAssertEqual(stacked.map(\.frame.minY), [616, 308, 0], "top to bottom")
        XCTAssertTrue(stacked.allSatisfy { $0.frame.width == 500 })
    }

    @MainActor
    func testMinimumSizeOfNestedSplits() {
        let right = PaneSplitView()
        right.axis = .vertical
        right.setPanes([NSView(), NSView(), NSView()])
        XCTAssertEqual(right.minimumSize, NSSize(width: 200, height: 3 * 160 + 2 * 6))
        let root = PaneSplitView()
        root.setPanes([NSView(), right])
        XCTAssertEqual(root.minimumSize, NSSize(width: 200 + 6 + 200, height: 492))
    }

    @MainActor
    func testDraggingADividerKeepsANestedSplitsMinimum() {
        let root = PaneSplitView(frame: NSRect(x: 0, y: 0, width: 1006, height: 600))
        let right = PaneSplitView()   // two panes side by side: at least 406 pt wide
        right.setPanes([NSView(), NSView()])
        let left = NSView()
        root.setPanes([left, right])
        root.layout()
        root.dragDivider(at: 0, to: 900)
        root.layout()
        XCTAssertEqual(left.frame.width, 594)
        XCTAssertEqual(right.frame.width, 406)
    }

    /// Counts how often a view is put into or taken out of a superview.
    private final class MoveCountingView: NSView {
        var moves = 0
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            moves += 1
        }
    }

    /// Splitting or closing a pane must not take the web views next to it out of the window.
    @MainActor
    func testPanesThatStayAreLeftInPlace() {
        let split = PaneSplitView(frame: NSRect(x: 0, y: 0, width: 1012, height: 300))
        let (a, b) = (MoveCountingView(), MoveCountingView())
        split.setPanes([a, b])
        let new = NSView()
        split.ratios = [0.5, 0.25, 0.25]
        split.setPanes([a, new, b])
        split.layout()
        XCTAssertEqual([a.moves, b.moves], [1, 1], "added once, never taken out")
        XCTAssertTrue(split.panes.elementsEqual([a, new, b], by: ===))
        XCTAssertEqual([a, new, b].map(\.frame.width), [500, 250, 250])
        XCTAssertEqual(split.swapButtons.count, 2)

        split.setPanes([a, b])
        XCTAssertNil(new.superview)
        XCTAssertEqual([a.moves, b.moves], [1, 1])
    }

    /// When a workspace is rebuilt, its panes move into new splits before the old ones are emptied.
    @MainActor
    func testAViewThatMovedToAnotherSplitStaysThere() {
        let (old, views) = makeSplit(width: 1006, panes: 2)
        let new = PaneSplitView()
        new.setPanes([views[0]])
        old.setPanes([])
        XCTAssertTrue(views[0].superview === new)
        XCTAssertNil(views[1].superview)
    }
}
