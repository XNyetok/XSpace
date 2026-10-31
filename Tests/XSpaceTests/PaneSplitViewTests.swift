import AppKit
import XCTest
@testable import XSpace

/// Pane widths: ratios, dragging a divider (with the minimum pane width) and equalizing.
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

        split.dragDivider(at: 0, toX: 300)
        split.layout()
        XCTAssertEqual(views.map(\.frame.width), [300, 700])

        split.dragDivider(at: 0, toX: 20)   // too far: panes are at least 200 pt wide
        split.layout()
        XCTAssertEqual(views.map(\.frame.width), [200, 800])

        split.dragDivider(at: 0, toX: 990)
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
}
