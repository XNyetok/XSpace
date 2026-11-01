import Foundation

// MARK: - Workspaces (persisted in state.json)

/// How a split arranges its children: side by side (horizontal) or stacked from top to bottom
/// (vertical).
enum SplitAxis: String, Codable {
    case horizontal
    case vertical
}

/// One pane of a workspace: a page shown in one profile.
struct LayoutPane: Codable, Equatable {
    var id: UUID
    var profileID: UUID
    var url: String
}

/// Children side by side or stacked, each with a share of the space.
struct LayoutSplit: Codable, Equatable {
    var id: UUID
    var axis: SplitAxis
    var children: [LayoutNode]
    /// Relative sizes of the children, in their order (nil = equal).
    var ratios: [Double]?
}

/// A workspace's layout is a tree: each node is a pane or a split of further nodes.
/// In state.json a node is written as {"pane": {…}} or {"split": {…}}.
enum LayoutNode: Equatable {
    case pane(LayoutPane)
    case split(LayoutSplit)
}

/// A saved arrangement of panes. Each pane can show any profile, so one workspace can show
/// several accounts at once. Every profile from 0.5.0 became a workspace with the same panes.
struct WorkspaceState: Codable, Equatable {
    var id: UUID
    /// nil = named after the profiles of its panes.
    var name: String?
    var root: LayoutNode
}

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try container.decodeIfPresent(LayoutPane.self, forKey: .pane) {
            self = .pane(pane)
        } else if let split = try container.decodeIfPresent(LayoutSplit.self, forKey: .split) {
            self = .split(split)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath,
                                                    debugDescription: "A layout node is a pane or a split"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane): try container.encode(pane, forKey: .pane)
        case .split(let split): try container.encode(split, forKey: .split)
        }
    }
}

// MARK: - Reading and changing a layout

extension LayoutNode {
    /// The ID of the pane or split.
    var id: UUID {
        switch self {
        case .pane(let pane): return pane.id
        case .split(let split): return split.id
        }
    }

    /// The panes in reading order: left to right, top to bottom.
    var panes: [LayoutPane] {
        switch self {
        case .pane(let pane): return [pane]
        case .split(let split): return split.children.flatMap(\.panes)
        }
    }

    func contains(profile id: UUID) -> Bool {
        panes.contains { $0.profileID == id }
    }

    func pane(_ id: UUID) -> LayoutPane? {
        panes.first { $0.id == id }
    }

    /// The split `id` in this layout.
    func split(_ id: UUID) -> LayoutSplit? {
        guard case .split(let split) = self else { return nil }
        if split.id == id { return split }
        for child in split.children {
            if let found = child.split(id) { return found }
        }
        return nil
    }

    /// The split that holds the node `id`, and the node's index in it; nil for the outermost node.
    func parent(of id: UUID) -> (split: LayoutSplit, index: Int)? {
        guard case .split(let split) = self else { return nil }
        if let index = split.children.firstIndex(where: { $0.id == id }) { return (split, index) }
        for child in split.children {
            if let found = child.parent(of: id) { return found }
        }
        return nil
    }

    /// The same layout with `newPane` next to the pane `id`: right after it in the split that
    /// holds it if that split goes along `axis`, otherwise together with it in a new split along
    /// `axis` that takes its place. Either way the two share the space the pane had.
    func inserting(_ newPane: LayoutPane, nextTo id: UUID, along axis: SplitAxis) -> LayoutNode {
        switch self {
        case .pane(let pane):
            guard pane.id == id else { return self }
            return .split(LayoutSplit(id: UUID(), axis: axis, children: [self, .pane(newPane)], ratios: nil))
        case .split(var split):
            if split.axis == axis, let index = split.children.firstIndex(where: { $0.id == id }),
               case .pane = split.children[index] {
                let count = split.children.count
                var shares = split.ratios.flatMap { $0.count == count ? $0 : nil } ?? Array(repeating: 1, count: count)
                shares[index] /= 2
                shares.insert(shares[index], at: index + 1)
                split.children.insert(.pane(newPane), at: index + 1)
                split.ratios = shares
                return .split(split)
            }
            split.children = split.children.map { $0.inserting(newPane, nextTo: id, along: axis) }
            return .split(split)
        }
    }

    /// The same layout with every pane passed through `transform`.
    func mapPanes(_ transform: (LayoutPane) -> LayoutPane) -> LayoutNode {
        switch self {
        case .pane(let pane):
            return .pane(transform(pane))
        case .split(var split):
            split.children = split.children.map { $0.mapPanes(transform) }
            return .split(split)
        }
    }

    /// The same layout with the split `id` changed by `change`.
    func updatingSplit(_ id: UUID, _ change: (inout LayoutSplit) -> Void) -> LayoutNode {
        guard case .split(var split) = self else { return self }
        if split.id == id {
            change(&split)
        } else {
            split.children = split.children.map { $0.updatingSplit(id, change) }
        }
        return .split(split)
    }

    /// The layout without the panes `shouldRemove` picks, or nil if no pane is left. A split left
    /// with one child is replaced by that child; the other children keep their shares.
    func removingPanes(where shouldRemove: (LayoutPane) -> Bool) -> LayoutNode? {
        switch self {
        case .pane(let pane):
            return shouldRemove(pane) ? nil : self
        case .split(var split):
            var children: [LayoutNode] = []
            var shares: [Double] = []
            for (index, child) in split.children.enumerated() {
                guard let kept = child.removingPanes(where: shouldRemove) else { continue }
                children.append(kept)
                if let ratios = split.ratios, index < ratios.count { shares.append(ratios[index]) }
            }
            guard children.count > 1 else { return children.first }
            split.ratios = split.ratios != nil && shares.count == children.count ? shares : nil
            split.children = children
            return .split(split)
        }
    }

    /// The layout without the pane `id`, or nil if it was the only pane. Its space goes to the
    /// node before it in its split (or after it, if it was the first), so splitting a pane and
    /// closing the new one gives the pane its size back. A split left with one child is replaced
    /// by that child.
    func removingPane(_ id: UUID) -> LayoutNode? {
        switch self {
        case .pane(let pane):
            return pane.id == id ? nil : self
        case .split(var split):
            guard let index = split.children.firstIndex(where: { $0.id == id }) else {
                // A split always keeps at least one child, so no child disappears here.
                split.children = split.children.compactMap { $0.removingPane(id) }
                return .split(split)
            }
            let count = split.children.count
            var shares = split.ratios.flatMap { $0.count == count ? $0 : nil } ?? Array(repeating: 1, count: count)
            shares[index > 0 ? index - 1 : 1] += shares[index]
            shares.remove(at: index)
            split.children.remove(at: index)
            guard split.children.count > 1 else { return split.children.first }
            split.ratios = shares
            return .split(split)
        }
    }

    /// The same layout without sizes that cannot be applied: a split's ratios must be one
    /// positive number per child, otherwise its children share the space equally.
    func withValidRatios() -> LayoutNode {
        guard case .split(var split) = self else { return self }
        split.children = split.children.map { $0.withValidRatios() }
        if let ratios = split.ratios,
           ratios.count != split.children.count || !ratios.allSatisfy({ $0.isFinite && $0 > 0 }) {
            split.ratios = nil
        }
        return .split(split)
    }

    /// The same layout with a new ID for every node whose ID is already in `seen`.
    func withUniqueIDs(seen: inout Set<UUID>) -> LayoutNode {
        switch self {
        case .pane(var pane):
            pane.id = uniqueID(pane.id, seen: &seen)
            return .pane(pane)
        case .split(var split):
            split.id = uniqueID(split.id, seen: &seen)
            var children: [LayoutNode] = []
            for child in split.children {
                children.append(child.withUniqueIDs(seen: &seen))
            }
            split.children = children
            return .split(split)
        }
    }

    /// For a layout that is only panes of `profileID` side by side: their widths (nil = equal).
    fileprivate func sideBySideRatios(of profileID: UUID) -> [Double]? {
        guard case .split(let split) = self, split.axis == .horizontal else { return nil }
        let onlyThatProfile = split.children.allSatisfy { child in
            if case .pane(let pane) = child { return pane.profileID == profileID }
            return false
        }
        return onlyThatProfile ? split.ratios : nil
    }
}

extension LayoutSplit {
    /// Swaps the child at `index` with the next one; each keeps its share of the space.
    mutating func swapChildren(at index: Int) {
        guard index >= 0, index + 1 < children.count else { return }
        children.swapAt(index, index + 1)
        if var shares = ratios, index + 1 < shares.count {
            shares.swapAt(index, index + 1)
            ratios = shares
        }
    }
}

/// `id`, or a new ID if `id` is already taken.
private func uniqueID(_ id: UUID, seen: inout Set<UUID>) -> UUID {
    if seen.insert(id).inserted { return id }
    let fresh = UUID()
    seen.insert(fresh)
    return fresh
}

// MARK: - Creating, checking and migrating workspaces

extension WorkspaceState {
    /// The workspace a 0.5.0 profile becomes: its panes side by side, with the same widths.
    init(migrating profile: ProfileState) {
        self.init(sideBySide: profile.panes.map(\.url), of: profile.id, ratios: profile.splitRatios)
    }

    /// A new profile's workspace: the default panes (Google AI Studio | Google Sheets).
    init(defaultFor profileID: UUID) {
        self.init(sideBySide: Defaults.paneURLs, of: profileID, ratios: nil)
    }

    /// Panes of one profile side by side (the default panes if `urls` is empty). A single pane is
    /// the whole layout.
    init(sideBySide urls: [String], of profileID: UUID, ratios: [Double]?) {
        let panes = (urls.isEmpty ? Defaults.paneURLs : urls).map {
            LayoutNode.pane(LayoutPane(id: UUID(), profileID: profileID, url: $0))
        }
        let root = panes.count == 1
            ? panes[0]
            : LayoutNode.split(LayoutSplit(id: UUID(), axis: .horizontal, children: panes, ratios: ratios))
        self.init(id: UUID(), name: nil, root: root.withValidRatios())
    }

    /// Workspaces as XSpace shows them, from whatever state.json contained: panes of profiles that
    /// do not exist are dropped, sizes that do not fit are reset, splits with one child are
    /// replaced by it, duplicate IDs get new ones and workspaces without panes are removed.
    /// A profile does not need a pane: one that no workspace shows stays available for panes.
    /// Only when no workspace is left does every profile get one again (see init(migrating:)).
    static func normalized(_ workspaces: [WorkspaceState], profiles: [ProfileState]) -> [WorkspaceState] {
        let known = Set(profiles.map(\.id))
        var seen = Set<UUID>()
        var result: [WorkspaceState] = []
        for var workspace in workspaces {
            guard let root = workspace.root
                .withValidRatios()
                .removingPanes(where: { !known.contains($0.profileID) })
            else { continue }
            workspace.id = uniqueID(workspace.id, seen: &seen)
            workspace.root = root.withUniqueIDs(seen: &seen)
            result.append(workspace)
        }
        return result.isEmpty ? profiles.map(WorkspaceState.init(migrating:)) : result
    }

    /// The profiles as 0.5.0 reads them from state.json. 0.5.0 knows panes per profile and no
    /// workspaces, so each profile gets its panes from the first workspace that shows it, and
    /// its widths if that workspace is only its panes side by side (as every workspace migrated
    /// from 0.5.0 is). A profile that no workspace shows keeps what it had.
    static func legacyProfiles(_ profiles: [ProfileState], from workspaces: [WorkspaceState]) -> [ProfileState] {
        profiles.map { profile in
            guard let workspace = workspaces.first(where: { $0.root.contains(profile: profile.id) }) else {
                return profile
            }
            var mirrored = profile
            mirrored.panes = workspace.root.panes.filter { $0.profileID == profile.id }.map { PaneState(url: $0.url) }
            mirrored.splitRatios = workspace.root.sideBySideRatios(of: profile.id)
            return mirrored
        }
    }
}
