import XCTest
@testable import XSpace

/// Layouts: the fixed ones, the automatic grid, and which profiles a layout shows first.
final class GridTests: XCTestCase {
    func testFixedLayouts() {
        XCTAssertEqual(GridPreset.single.tree(slots: 9), .slot(0))
        XCTAssertEqual(GridPreset.twoColumns.tree(slots: 0), .split(.horizontal, [.slot(0), .slot(1)]))
        XCTAssertEqual(GridPreset.twoRows.tree(slots: 0), .split(.vertical, [.slot(0), .slot(1)]))
        XCTAssertEqual(GridPreset.twoByTwo.tree(slots: 0),
                       .split(.vertical, [.split(.horizontal, [.slot(0), .slot(1)]), .split(.horizontal, [.slot(2), .slot(3)])]))
        XCTAssertEqual(GridPreset.oneAndThree.tree(slots: 0),
                       .split(.horizontal, [.slot(0), .split(.vertical, [.slot(1), .slot(2), .slot(3)])]))
    }

    func testEveryFixedLayoutShowsItsSlotsOnceInReadingOrder() {
        for preset in GridPreset.allCases {
            guard let count = preset.slotCount else { continue }
            XCTAssertEqual(preset.tree(slots: 0).slots, Array(0..<count), preset.rawValue)
        }
        XCTAssertEqual(Set(GridPreset.allCases.map(\.title)).count, GridPreset.allCases.count)
    }

    func testTheAutomaticLayoutShowsEveryProfile() {
        XCTAssertNil(GridPreset.automatic.slotCount)
        for count in 1...16 {
            XCTAssertEqual(GridPreset.automatic.tree(slots: count).slots, Array(0..<count), "\(count) profiles")
        }
    }

    func testTheAutomaticLayoutKeepsTheGridBalanced() {
        func rows(_ count: Int) -> [Int] {
            switch GridPreset.automatic.tree(slots: count) {
            case .slot: return [1]
            case .split(.horizontal, let children): return [children.count]
            case .split(.vertical, let rows): return rows.map(\.slots.count)
            }
        }
        XCTAssertEqual([1, 2, 3].map(rows), [[1], [2], [3]], "up to three side by side")
        XCTAssertEqual(rows(4), [2, 2])
        XCTAssertEqual(rows(5), [3, 2])
        XCTAssertEqual(rows(6), [3, 3])
        XCTAssertEqual(rows(7), [3, 3, 1])
        XCTAssertEqual(rows(9), [3, 3, 3])
        XCTAssertEqual(rows(10), [4, 4, 2])
    }

    func testFindingANode() {
        let tree = GridPreset.oneAndThree.tree(slots: 0)
        XCTAssertEqual(tree.node(at: []), tree)
        XCTAssertEqual(tree.node(at: [0]), .slot(0))
        XCTAssertEqual(tree.node(at: [1, 2]), .slot(3))
        XCTAssertNil(tree.node(at: [2]))
        XCTAssertNil(tree.node(at: [0, 0]), "a slot has no children")
    }

    func testCustomSizes() {
        let tree = GridPreset.oneAndThree.tree(slots: 0)   // two side by side, the second a column of three
        XCTAssertEqual(tree.splitCounts, [2, 3], "the order of the saved sizes")
        XCTAssertFalse(Grid.hasCustomSizes(nil, in: tree))
        XCTAssertFalse(Grid.hasCustomSizes([[0.5, 0.5], [1, 1, 1]], in: tree), "equal sizes are the layout's own")
        XCTAssertTrue(Grid.hasCustomSizes([[0.6, 0.4]], in: tree))
        XCTAssertTrue(Grid.hasCustomSizes([[0.5, 0.5], [1, 1, 2]], in: tree), "a nested split counts too")
        XCTAssertFalse(Grid.hasCustomSizes([[0.6, 0.3, 0.1], [1, -1, 2], [0.3, 0.7]], in: tree),
                       "sizes that do not fit a split leave it equal, and there is no third split")
        XCTAssertFalse(Grid.hasCustomSizes([[0.3, 0.7]], in: .slot(0)), "one pane has no sizes")
    }

    func testFillingALayout() {
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        XCTAssertEqual(Grid.filling(4, shown: [c], profiles: [a, b, c], active: nil), [c, a, b, nil],
                       "the profiles shown first, then the others in toolbar order; empty slots if there are not enough")
        XCTAssertEqual(Grid.filling(2, shown: [a, b, c], profiles: [a, b, c, d], active: c), [a, c],
                       "the active profile stays, in the last slot")
        XCTAssertEqual(Grid.filling(1, shown: [a, b], profiles: [a, b], active: b), [b])
        XCTAssertEqual(Grid.filling(2, shown: [nil, b], profiles: [a, b], active: UUID()), [b, a], "an unknown profile is ignored")
        XCTAssertEqual(Grid.filling(0, shown: [a], profiles: [a], active: a), [])
    }
}
