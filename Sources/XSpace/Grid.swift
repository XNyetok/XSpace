import Foundation

// MARK: - Layouts (state.json: "layout")

/// How a split arranges its children: side by side (horizontal) or stacked from top to bottom
/// (vertical).
enum SplitAxis: String, Codable {
    case horizontal
    case vertical
}

/// How the window arranges the profiles, one pane each: every profile in a grid (automatic), or a
/// fixed layout that shows a given number of profiles.
enum GridPreset: String, Codable, CaseIterable {
    case automatic
    case single
    case twoColumns
    case twoRows
    case threeColumns
    case twoByTwo
    case oneAndTwo
    case oneAndThree

    /// Menu title (UI language: Indonesian).
    var title: String {
        switch self {
        case .automatic: return "Otomatis (semua profil)"
        case .single: return "1 profil"
        case .twoColumns: return "2 berdampingan"
        case .twoRows: return "2 bertumpuk"
        case .threeColumns: return "3 berdampingan"
        case .twoByTwo: return "2 × 2"
        case .oneAndTwo: return "1 + 2"
        case .oneAndThree: return "1 + 3"
        }
    }

    /// How many profiles the layout shows; nil for the automatic one, which shows them all.
    var slotCount: Int? {
        switch self {
        case .automatic: return nil
        case .single: return 1
        case .twoColumns, .twoRows: return 2
        case .threeColumns, .oneAndTwo: return 3
        case .twoByTwo, .oneAndThree: return 4
        }
    }

    /// The arrangement with `count` profiles (only the automatic layout depends on the count).
    func tree(slots count: Int) -> GridNode {
        switch self {
        case .automatic: return .automatic(count)
        case .single: return .slot(0)
        case .twoColumns: return .row(0..<2)
        case .twoRows: return .column(0..<2)
        case .threeColumns: return .row(0..<3)
        case .twoByTwo: return .split(.vertical, [.row(0..<2), .row(2..<4)])
        case .oneAndTwo: return .split(.horizontal, [.slot(0), .column(1..<3)])
        case .oneAndThree: return .split(.horizontal, [.slot(0), .column(1..<4)])
        }
    }
}

/// A layout as a tree. A slot shows one profile; a split puts its children side by side
/// (horizontal) or stacks them from the top (vertical). Slots are numbered in reading order.
enum GridNode: Equatable {
    case slot(Int)
    case split(SplitAxis, [GridNode])

    /// Slots side by side.
    static func row(_ slots: Range<Int>) -> GridNode {
        slots.count == 1 ? .slot(slots.lowerBound) : .split(.horizontal, slots.map { .slot($0) })
    }

    /// Slots stacked.
    static func column(_ slots: Range<Int>) -> GridNode {
        slots.count == 1 ? .slot(slots.lowerBound) : .split(.vertical, slots.map { .slot($0) })
    }

    /// Every profile in a balanced grid: up to three side by side, then rows of up to ⌈√n⌉
    /// (4 → 2 × 2, 5–6 → two rows of three, 7–9 → 3 × 3, …). A last row with fewer profiles gives
    /// them more width.
    static func automatic(_ count: Int) -> GridNode {
        guard count > 3 else { return row(0..<max(count, 1)) }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = stride(from: 0, to: count, by: columns).map { row($0..<min($0 + columns, count)) }
        return .split(.vertical, rows)
    }

    /// The slots in reading order.
    var slots: [Int] {
        switch self {
        case .slot(let slot): return [slot]
        case .split(_, let children): return children.flatMap(\.slots)
        }
    }

    /// The node at `path`: the indexes of the children from this node down.
    func node(at path: [Int]) -> GridNode? {
        guard let first = path.first else { return self }
        guard case .split(_, let children) = self, children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }

    /// The number of children of each split, depth first: the order of a layout's saved sizes.
    var splitCounts: [Int] {
        guard case .split(_, let children) = self else { return [] }
        return [children.count] + children.flatMap(\.splitCounts)
    }
}

enum Grid {
    /// Whether saved ratios can size a split with `count` children: a positive ratio for each.
    /// Others are ignored, and the split gets equal sizes.
    static func ratios(_ ratios: [Double], fit count: Int) -> Bool {
        ratios.count == count && ratios.allSatisfy { $0.isFinite && $0 > 0 }
    }

    /// Whether saved sizes (a split's ratios each, depth first) give the panes of `tree` other
    /// sizes than the layout's own, which are equal.
    static func hasCustomSizes(_ sizes: [[Double]]?, in tree: GridNode) -> Bool {
        guard let sizes else { return false }
        return zip(sizes, tree.splitCounts).contains { ratios, count in
            guard Grid.ratios(ratios, fit: count) else { return false }
            let sum = ratios.reduce(0, +)
            return ratios.contains { abs($0 / sum - 1 / Double(count)) > 0.001 }
        }
    }

    /// The profiles a fixed layout with `count` slots shows when you switch to it for the first
    /// time: the profiles shown so far in their order, then the others in toolbar order. The
    /// active profile stays on screen: if it would not fit, it takes the last slot.
    static func filling(_ count: Int, shown: [UUID?], profiles: [UUID], active: UUID?) -> [UUID?] {
        guard count > 0 else { return [] }
        var order: [UUID] = []
        for id in shown.compactMap({ $0 }) + profiles where !order.contains(id) {
            order.append(id)
        }
        var slots: [UUID?] = order.prefix(count).map { $0 }
        if let active, order.contains(active), !slots.contains(active) {
            slots[slots.count - 1] = active
        }
        return slots + Array(repeating: nil, count: count - slots.count)
    }
}
