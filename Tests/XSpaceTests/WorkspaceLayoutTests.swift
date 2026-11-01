import XCTest
@testable import XSpace

/// Workspace layouts: the tree, migrating 0.5.0 profiles, the rules applied to saved layouts and
/// the fields written for 0.5.0.
final class WorkspaceLayoutTests: XCTestCase {
    private let profileA = UUID()
    private let profileB = UUID()

    private func pane(_ profile: UUID, _ url: String = "https://example.com/", id: UUID = UUID()) -> LayoutNode {
        .pane(LayoutPane(id: id, profileID: profile, url: url))
    }

    private func split(_ axis: SplitAxis, _ children: [LayoutNode], ratios: [Double]? = nil,
                       id: UUID = UUID()) -> LayoutNode {
        .split(LayoutSplit(id: id, axis: axis, children: children, ratios: ratios))
    }

    private func profile(_ id: UUID, panes: [String] = Defaults.paneURLs, ratios: [Double]? = nil) -> ProfileState {
        ProfileState(id: id, name: "Akun", colorIndex: 0, panes: panes.map { PaneState(url: $0) }, splitRatios: ratios)
    }

    private func workspace(_ root: LayoutNode, id: UUID = UUID()) -> WorkspaceState {
        WorkspaceState(id: id, name: nil, root: root)
    }

    /// One tall pane on the left (A), two stacked on the right (B above A).
    private func mixedLayout() -> LayoutNode {
        split(.horizontal, [
            pane(profileA, "https://a.example/"),
            split(.vertical, [pane(profileB, "https://b.example/"), pane(profileA, "https://c.example/")]),
        ], ratios: [0.4, 0.6])
    }

    // MARK: Migrating 0.5.0 profiles

    func testAProfileBecomesAWorkspaceWithTheSamePanesAndWidths() {
        let migrated = WorkspaceState(migrating: profile(profileA, ratios: [0.3, 0.7]))
        XCTAssertNil(migrated.name, "named after its profile")
        guard case .split(let root) = migrated.root else { return XCTFail("expected panes side by side") }
        XCTAssertEqual(root.axis, .horizontal)
        XCTAssertEqual(root.ratios, [0.3, 0.7])
        XCTAssertEqual(migrated.root.panes.map(\.url), Defaults.paneURLs)
        XCTAssertEqual(Set(migrated.root.panes.map(\.profileID)), [profileA])
    }

    func testAProfileWithoutPanesGetsTheDefaultPanes() {
        let migrated = WorkspaceState(migrating: profile(profileA, panes: []))
        XCTAssertEqual(migrated.root.panes.map(\.url), Defaults.paneURLs)
    }

    func testAProfileWithOnePaneBecomesThatPane() {
        let migrated = WorkspaceState(migrating: profile(profileA, panes: ["https://a.example/"], ratios: [1]))
        guard case .pane(let only) = migrated.root else { return XCTFail("expected a single pane") }
        XCTAssertEqual(only.url, "https://a.example/")
    }

    func testWidthsThatDoNotFitThePanesAreDropped() {
        for ratios: [Double] in [[1], [0.5, 0.5, 0.5], [0, 1], [-1, 2], [.nan, 1], [.infinity, 1]] {
            let migrated = WorkspaceState(migrating: profile(profileA, ratios: ratios))
            guard case .split(let root) = migrated.root else { return XCTFail("expected a split") }
            XCTAssertNil(root.ratios, "\(ratios)")
        }
    }

    func testNewProfilesGetTheDefaultPanes() {
        let created = WorkspaceState(defaultFor: profileA)
        XCTAssertEqual(created.root.panes.map(\.url), Defaults.paneURLs)
        XCTAssertEqual(Set(created.root.panes.map(\.profileID)), [profileA])
    }

    // MARK: JSON

    func testNodesAreWrittenAsPaneOrSplit() throws {
        let data = try JSONEncoder().encode(workspace(mixedLayout()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["name"], "a workspace without a name of its own has no name key")
        let root = try XCTUnwrap((json["root"] as? [String: Any])?["split"] as? [String: Any])
        XCTAssertEqual(root["axis"] as? String, "horizontal")
        XCTAssertEqual(root["ratios"] as? [Double], [0.4, 0.6])
        let children = try XCTUnwrap(root["children"] as? [[String: Any]])
        XCTAssertEqual(children.count, 2)
        let left = try XCTUnwrap(children[0]["pane"] as? [String: Any])
        XCTAssertEqual(left["url"] as? String, "https://a.example/")
        XCTAssertEqual(left["profileID"] as? String, profileA.uuidString)
        XCTAssertNotNil(children[1]["split"])
    }

    func testWorkspacesSurviveARoundTrip() throws {
        var named = workspace(mixedLayout())
        named.name = "Riset"
        for original in [named, workspace(mixedLayout()), workspace(pane(profileA))] {
            let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original)
        }
    }

    func testANodeThatIsNeitherAPaneNorASplitIsAnError() {
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutNode.self, from: Data(#"{"tab": {}}"#.utf8)))
    }

    // MARK: Reading and changing a layout

    func testPanesAreListedLeftToRightAndTopToBottom() {
        XCTAssertEqual(mixedLayout().panes.map(\.url), ["https://a.example/", "https://b.example/", "https://c.example/"])
        XCTAssertTrue(mixedLayout().contains(profile: profileB))
        XCTAssertFalse(mixedLayout().contains(profile: UUID()))
    }

    func testSwappingChildrenKeepsTheirShares() {
        let (first, second) = (pane(profileA, "https://a.example/"), pane(profileA, "https://b.example/"))
        var split = LayoutSplit(id: UUID(), axis: .horizontal, children: [first, second], ratios: [0.3, 0.7])
        split.swapChildren(at: 0)
        XCTAssertEqual(split.children, [second, first])
        XCTAssertEqual(split.ratios, [0.7, 0.3])
        split.swapChildren(at: 1)   // there is no third child
        XCTAssertEqual(split.children, [second, first])
    }

    func testUpdatingANestedSplit() {
        let innerID = UUID()
        let layout = split(.horizontal, [pane(profileA), split(.vertical, [pane(profileA), pane(profileB)], id: innerID)])
        let updated = layout.updatingSplit(innerID) { $0.ratios = [1, 3] }
        guard case .split(let root) = updated, case .split(let inner) = root.children[1] else {
            return XCTFail("expected the same structure")
        }
        XCTAssertEqual(inner.ratios, [1, 3])
        XCTAssertNil(root.ratios)
    }

    func testChangingOnePane() {
        let layout = mixedLayout()
        let target = layout.panes[1].id
        let updated = layout.mapPanes { pane in
            var pane = pane
            if pane.id == target { pane.url = "https://new.example/" }
            return pane
        }
        XCTAssertEqual(updated.panes.map(\.url), ["https://a.example/", "https://new.example/", "https://c.example/"])
        XCTAssertEqual(updated.panes.map(\.id), layout.panes.map(\.id))
    }

    func testRemovingPanesCollapsesSplitsAndKeepsShares() throws {
        let layout = mixedLayout()
        let withoutB = try XCTUnwrap(layout.removingPanes { $0.profileID == profileB })
        XCTAssertEqual(withoutB.panes.map(\.url), ["https://a.example/", "https://c.example/"])
        guard case .split(let root) = withoutB else { return XCTFail("expected a split") }
        XCTAssertEqual(root.ratios, [0.4, 0.6], "the right column keeps its width")
        guard case .pane = root.children[1] else { return XCTFail("a split with one pane left becomes that pane") }

        let withoutA = try XCTUnwrap(layout.removingPanes { $0.profileID == profileA })
        guard case .pane(let only) = withoutA else { return XCTFail("expected a single pane") }
        XCTAssertEqual(only.url, "https://b.example/")
        XCTAssertNil(layout.removingPanes { _ in true })
    }

    // MARK: Rules for saved layouts

    func testAValidStateIsLeftAsItIs() {
        let workspaces = [workspace(mixedLayout()), WorkspaceState(migrating: profile(profileB))]
        let profiles = [profile(profileA), profile(profileB)]
        XCTAssertEqual(WorkspaceState.normalized(workspaces, profiles: profiles), workspaces)
    }

    func testPanesOfUnknownProfilesAreDropped() {
        let normalized = WorkspaceState.normalized([workspace(mixedLayout())], profiles: [profile(profileA)])
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].root.panes.map(\.url), ["https://a.example/", "https://c.example/"])
    }

    func testWorkspacesWithoutPanesAreRemoved() {
        let onlyB = workspace(split(.horizontal, [pane(profileB), pane(profileB)]))
        let emptySplit = workspace(split(.vertical, []))
        let aWorkspace = WorkspaceState(migrating: profile(profileA))
        let normalized = WorkspaceState.normalized([onlyB, emptySplit, aWorkspace], profiles: [profile(profileA)])
        XCTAssertEqual(normalized, [aWorkspace])
    }

    func testSizesThatDoNotFitAreReset() {
        let layout = split(.horizontal, [pane(profileA), split(.vertical, [pane(profileA), pane(profileA)], ratios: [0, 1])],
                           ratios: [0.5, 0.25, 0.25])
        let normalized = WorkspaceState.normalized([workspace(layout)], profiles: [profile(profileA)])
        guard case .split(let root) = normalized[0].root, case .split(let inner) = root.children[1] else {
            return XCTFail("expected the same structure")
        }
        XCTAssertNil(root.ratios)
        XCTAssertNil(inner.ratios)
    }

    func testASplitWithOneChildIsReplacedByIt() {
        let only = pane(profileA)
        let normalized = WorkspaceState.normalized([workspace(split(.horizontal, [split(.vertical, [only])]))],
                                                   profiles: [profile(profileA)])
        XCTAssertEqual(normalized[0].root, only)
    }

    func testDuplicateIDsAreReplaced() {
        let shared = UUID()
        let first = workspace(split(.horizontal, [pane(profileA, id: shared), pane(profileA, id: shared)]), id: shared)
        let second = workspace(pane(profileA, id: shared), id: shared)
        let normalized = WorkspaceState.normalized([first, second], profiles: [profile(profileA)])
        var ids = normalized.map(\.id)
        for workspace in normalized {
            ids += workspace.root.panes.map(\.id)
            if case .split(let split) = workspace.root { ids.append(split.id) }
        }
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, ids.count, "every workspace, split and pane has its own ID")
        XCTAssertEqual(normalized.map { $0.root.panes.count }, [2, 1])
    }

    func testEveryProfileGetsAWorkspace() {
        let aWorkspace = WorkspaceState(migrating: profile(profileA))
        let b = profile(profileB, panes: ["https://b.example/"])
        let normalized = WorkspaceState.normalized([aWorkspace], profiles: [profile(profileA), b])
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0], aWorkspace)
        XCTAssertEqual(normalized[1].root.panes.map(\.url), ["https://b.example/"])
        XCTAssertEqual(normalized[1].root.panes.map(\.profileID), [profileB])
    }

    func testRulesAppliedTwiceChangeNothingMore() {
        let messy = [workspace(mixedLayout()), workspace(split(.horizontal, [pane(profileA)], ratios: [2]))]
        let profiles = [profile(profileA), profile(profileB)]
        let once = WorkspaceState.normalized(messy, profiles: profiles)
        XCTAssertEqual(WorkspaceState.normalized(once, profiles: profiles), once)
    }

    // MARK: Fields for 0.5.0

    func testA050ProfileIsWrittenBackUnchanged() {
        let original = profile(profileA, panes: ["https://a.example/", "https://b.example/"], ratios: [0.3, 0.7])
        let migrated = WorkspaceState(migrating: original)
        var stale = original
        stale.panes = [PaneState(url: "https://old.example/")]
        stale.splitRatios = nil
        XCTAssertEqual(WorkspaceState.legacyProfiles([stale], from: [migrated]), [original])
    }

    func testProfilesInAMixedWorkspaceGetTheirOwnPanes() {
        let profiles = WorkspaceState.legacyProfiles([profile(profileA), profile(profileB)], from: [workspace(mixedLayout())])
        XCTAssertEqual(profiles[0].panes.map(\.url), ["https://a.example/", "https://c.example/"])
        XCTAssertEqual(profiles[1].panes.map(\.url), ["https://b.example/"])
        XCTAssertNil(profiles[0].splitRatios, "those widths belong to the mixed layout")
        XCTAssertNil(profiles[1].splitRatios)
    }

    func testTheFirstWorkspaceThatShowsAProfileCounts() {
        let first = WorkspaceState(sideBySide: ["https://first.example/"], of: profileA, ratios: nil)
        let second = WorkspaceState(sideBySide: ["https://second.example/"], of: profileA, ratios: nil)
        let profiles = WorkspaceState.legacyProfiles([profile(profileA)], from: [first, second])
        XCTAssertEqual(profiles[0].panes.map(\.url), ["https://first.example/"])
    }

    func testAProfileNoWorkspaceShowsKeepsItsPanes() {
        let b = profile(profileB, panes: ["https://b.example/"], ratios: nil)
        let profiles = WorkspaceState.legacyProfiles([b], from: [WorkspaceState(migrating: profile(profileA))])
        XCTAssertEqual(profiles, [b])
    }
}
