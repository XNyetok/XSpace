import XCTest
@testable import XSpace

/// Reading and writing state.json, including files written by older versions.
final class SavedStateTests: XCTestCase {
    private func decode(_ json: String) throws -> AppStateData {
        try JSONDecoder().decode(AppStateData.self, from: Data(json.utf8))
    }

    func testMissingKeysFallBackToDefaults() throws {
        let state = try decode("{}")
        XCTAssertEqual(state.version, 1)
        XCTAssertTrue(state.profiles.isEmpty)
        XCTAssertTrue(state.workspaces.isEmpty)
        XCTAssertNil(state.selectedWorkspaceID)
        XCTAssertNil(state.selectedProfileID)
        XCTAssertFalse(state.showAll)
        XCTAssertEqual(state.hibernatePolicy, .after15Minutes)
        XCTAssertTrue(state.pendingDeletion.isEmpty)
    }

    /// v0.1 stored a boolean "autoHibernate" instead of a policy.
    func testVersion01AutoHibernateIsMigrated() throws {
        XCTAssertEqual(try decode(#"{"autoHibernate": true}"#).hibernatePolicy, .immediately)
        XCTAssertEqual(try decode(#"{"autoHibernate": false}"#).hibernatePolicy, .after15Minutes)
    }

    func testUnknownPolicyFallsBackToDefault() throws {
        XCTAssertEqual(try decode(#"{"hibernatePolicy": "sometimes"}"#).hibernatePolicy, .after15Minutes)
    }

    func testProfileWithoutSplitRatiosDecodes() throws {
        let state = try decode("""
            {"profiles": [{"id": "6B1F0C9E-5A7D-4E1B-9C2A-58F3D0A1B2C3", "name": "Akun 1",
                           "colorIndex": 0, "panes": [{"url": "https://aistudio.google.com/"}]}]}
            """)
        XCTAssertEqual(state.profiles.count, 1)
        XCTAssertEqual(state.profiles[0].panes, [PaneState(url: "https://aistudio.google.com/")])
        XCTAssertNil(state.profiles[0].splitRatios)
    }

    func testRoundTrip() throws {
        var state = AppStateData()
        let id = UUID()
        state.profiles = [ProfileState(id: id, name: "Akun 1", colorIndex: 3,
                                       panes: Defaults.paneURLs.map { PaneState(url: $0) },
                                       splitRatios: [0.4, 0.6])]
        state.selectedProfileID = id
        state.showAll = true
        state.hibernatePolicy = .memoryPressureOnly
        state.pendingDeletion = [UUID()]

        let decoded = try JSONDecoder().decode(AppStateData.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.profiles, state.profiles)
        XCTAssertEqual(decoded.selectedProfileID, id)
        XCTAssertTrue(decoded.showAll)
        XCTAssertEqual(decoded.hibernatePolicy, .memoryPressureOnly)
        XCTAssertEqual(decoded.pendingDeletion, state.pendingDeletion)
    }

    func testHibernatePolicies() {
        XCTAssertEqual(HibernatePolicy.after15Minutes.idleSeconds, 15 * 60)
        XCTAssertEqual(HibernatePolicy.immediately.idleSeconds, 0)
        XCTAssertNil(HibernatePolicy.memoryPressureOnly.idleSeconds)
        XCTAssertNil(HibernatePolicy.never.idleSeconds)
        XCTAssertEqual(HibernatePolicy.allCases.filter(\.respondsToMemoryPressure),
                       [.after15Minutes, .immediately, .memoryPressureOnly])
        XCTAssertEqual(Set(HibernatePolicy.allCases.map(\.title)).count, HibernatePolicy.allCases.count)
    }

    func testEveryColorIndexMapsToAColor() {
        let count = Palette.colors.count
        XCTAssertEqual(Palette.color(0), Palette.colors[0])
        XCTAssertEqual(Palette.color(count + 1), Palette.colors[1])
        XCTAssertEqual(Palette.color(-1), Palette.colors[1])
        XCTAssertNotNil(Palette.color(Int.min))   // trapped before (abs overflow)
        XCTAssertNotNil(Palette.color(Int.max))
    }

    // MARK: Workspaces (version 2)

    private let aiStudio = "https://aistudio.google.com/"
    private let sheets = "https://docs.google.com/spreadsheets/"

    private func pane(_ profile: UUID, _ url: String) -> LayoutNode {
        .pane(LayoutPane(id: UUID(), profileID: profile, url: url))
    }

    /// Two profiles from 0.5.0, a workspace with both, and that workspace selected.
    private func stateWithAMixedWorkspace() -> (state: AppStateData, first: UUID, second: UUID, mixed: UUID) {
        var state = AppStateData()
        let first = state.addProfile(name: "Akun 1", colorIndex: 0).profile.id
        let second = state.addProfile(name: "Akun 2", colorIndex: 1).profile.id
        let mixed = WorkspaceState(id: UUID(), name: "Riset", root: .split(LayoutSplit(
            id: UUID(), axis: .horizontal,
            children: [pane(second, "https://b.example/"), pane(first, "https://a.example/")], ratios: [0.6, 0.4])))
        state.workspaces.append(mixed)
        state.selectedWorkspaceID = mixed.id
        return (state, first, second, mixed.id)
    }

    func testA050FileGetsAWorkspacePerProfile() throws {
        let (first, second) = (UUID(), UUID())
        let state = try decode("""
            {"version": 1, "selectedProfileID": "\(second)", "profiles": [
              {"id": "\(first)", "name": "Akun 1", "colorIndex": 0, "splitRatios": [0.3, 0.7],
               "panes": [{"url": "\(aiStudio)"}, {"url": "\(sheets)"}]},
              {"id": "\(second)", "name": "Akun 2", "colorIndex": 1,
               "panes": [{"url": "\(sheets)"}, {"url": "\(aiStudio)"}]}]}
            """)
        XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertEqual(state.workspaces.map { $0.root.panes.map(\.profileID) }, [[first, first], [second, second]])
        XCTAssertEqual(state.workspaces.map { $0.root.panes.map(\.url) }, [[aiStudio, sheets], [sheets, aiStudio]])
        guard case .split(let firstRoot) = state.workspaces[0].root else { return XCTFail("expected panes side by side") }
        XCTAssertEqual(firstRoot.ratios, [0.3, 0.7])
        XCTAssertEqual(state.selectedWorkspaceID, state.workspaces[1].id, "the profile 0.5.0 had selected")
    }

    func testAddingAProfileGivesItAWorkspace() {
        var state = AppStateData()
        let added = state.addProfile(name: "Akun 1", colorIndex: 0)
        XCTAssertEqual(state.profiles, [added.profile])
        XCTAssertEqual(state.workspaces, [added.workspace])
        XCTAssertEqual(state.selectedWorkspaceID, added.workspace.id)
        XCTAssertEqual(added.workspace.root.panes.map(\.url), Defaults.paneURLs)
        XCTAssertEqual(Set(added.workspace.root.panes.map(\.profileID)), [added.profile.id])
    }

    func testWorkspacesSurviveARoundTrip() throws {
        var (state, _, _, _) = stateWithAMixedWorkspace()
        state.showAll = true
        let decoded = try JSONDecoder().decode(AppStateData.self, from: state.encodedForDisk())
        XCTAssertEqual(decoded.version, AppStateData.currentVersion)
        XCTAssertEqual(decoded.workspaces, state.workspaces)
        XCTAssertEqual(decoded.selectedWorkspaceID, state.selectedWorkspaceID)
        XCTAssertTrue(decoded.showAll)
    }

    func testTheSavedFileStaysReadableFor050() throws {
        var (state, first, second, _) = stateWithAMixedWorkspace()
        state.workspaces[0].root = state.workspaces[0].root.updatingSplit(splitID(of: state.workspaces[0])) {
            $0.ratios = [0.7, 0.3]
            $0.swapChildren(at: 0)
        }
        let legacy = try JSONDecoder().decode(Legacy050State.self, from: state.encodedForDisk())
        XCTAssertEqual(legacy.profiles.map(\.id), [first, second])
        XCTAssertEqual(legacy.profiles[0].panes.map(\.url), [sheets, aiStudio], "the swapped order")
        XCTAssertEqual(legacy.profiles[0].splitRatios, [0.3, 0.7])
        XCTAssertEqual(legacy.profiles[1].panes.map(\.url), Defaults.paneURLs)
        XCTAssertEqual(legacy.selectedProfileID, second, "the profile in the selected workspace's first pane")
    }

    /// 0.5.0 saves the file again without the keys it does not know, but keeps "version": 2.
    func testGoingBackTo050AndForwardAgainKeepsEveryProfile() throws {
        var state = AppStateData()
        let first = state.addProfile(name: "Akun 1", colorIndex: 0)
        let second = state.addProfile(name: "Akun 2", colorIndex: 1)
        state.workspaces[0].root = state.workspaces[0].root.updatingSplit(splitID(of: first.workspace)) {
            $0.ratios = [0.25, 0.75]
        }
        state.selectedWorkspaceID = first.workspace.id

        let legacy = try JSONDecoder().decode(Legacy050State.self, from: state.encodedForDisk())
        let savedBy050 = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: savedBy050, as: UTF8.self).contains("workspaces"))
        let reread = try JSONDecoder().decode(AppStateData.self, from: savedBy050)

        XCTAssertEqual(reread.version, 2)
        XCTAssertEqual(reread.profiles.map(\.id), [first.profile.id, second.profile.id])
        XCTAssertEqual(reread.workspaces.map { $0.root.panes.map(\.profileID) },
                       state.workspaces.map { $0.root.panes.map(\.profileID) })
        XCTAssertEqual(reread.workspaces.map { $0.root.panes.map(\.url) }, state.workspaces.map { $0.root.panes.map(\.url) })
        guard case .split(let root) = reread.workspaces[0].root else { return XCTFail("expected panes side by side") }
        XCTAssertEqual(root.ratios, [0.25, 0.75])
        XCTAssertEqual(reread.selectedWorkspaceID, reread.workspaces[0].id)
    }

    func testWorkspacesThatCannotBeReadAreRebuiltFromTheProfiles() throws {
        let id = UUID()
        let state = try decode("""
            {"version": 2, "workspaces": [{"id": "not a workspace"}], "profiles": [
              {"id": "\(id)", "name": "Akun 1", "colorIndex": 0,
               "panes": [{"url": "https://a.example/"}, {"url": "https://b.example/"}]}]}
            """)
        XCTAssertEqual(state.profiles.map(\.id), [id])
        XCTAssertEqual(state.workspaces.map { $0.root.panes.map(\.url) }, [["https://a.example/", "https://b.example/"]])
        XCTAssertEqual(state.selectedWorkspaceID, state.workspaces.first?.id)
    }

    func testAProfileWithoutPanesStillReads() throws {
        let id = UUID()
        let state = try decode(#"{"profiles": [{"id": "\#(id)", "name": "Akun 1", "colorIndex": 0}]}"#)
        XCTAssertEqual(state.profiles.map(\.id), [id])
        XCTAssertEqual(state.workspaces.map { $0.root.panes.map(\.url) }, [Defaults.paneURLs])
    }

    func testRemovingAProfileRemovesItsPanesEverywhere() {
        var (state, first, second, mixed) = stateWithAMixedWorkspace()
        let secondWorkspace = state.workspaces[1].id
        state.selectedWorkspaceID = state.workspaces[0].id
        state.removeProfile(first)
        XCTAssertEqual(state.profiles.map(\.id), [second])
        XCTAssertEqual(state.workspaces.map(\.id), [secondWorkspace, mixed], "its own workspace is gone, the mixed one stays")
        XCTAssertEqual(state.workspaces[1].root.panes.map(\.profileID), [second])
        XCTAssertEqual(state.selectedWorkspaceID, secondWorkspace, "the first remaining workspace")
        XCTAssertEqual(state.pendingDeletion, [first])
    }

    /// A profile whose panes all show other profiles now (see WorkspaceState.normalized).
    func testAProfileWithoutPanesStaysWithoutAWorkspace() throws {
        var state = AppStateData()
        let first = state.addProfile(name: "Akun 1", colorIndex: 0)
        let second = state.addProfile(name: "Akun 2", colorIndex: 1)
        state.workspaces.removeAll { $0.id == second.workspace.id }
        state.selectedWorkspaceID = first.workspace.id
        let written = try state.encodedForDisk()

        let decoded = try JSONDecoder().decode(AppStateData.self, from: written)
        XCTAssertEqual(decoded.profiles.map(\.id), [first.profile.id, second.profile.id])
        XCTAssertEqual(decoded.workspaces.map(\.id), [first.workspace.id])
        let legacy = try JSONDecoder().decode(Legacy050State.self, from: written)
        XCTAssertEqual(legacy.profiles[1].panes.map(\.url), Defaults.paneURLs, "0.5.0 still shows it")
    }

    func testWithoutWorkspacesEveryProfileGetsOneAgain() throws {
        let id = UUID()
        let state = try decode("""
            {"version": 2, "workspaces": [], "profiles": [
              {"id": "\(id)", "name": "Akun 1", "colorIndex": 0, "panes": [{"url": "https://a.example/"}]}]}
            """)
        XCTAssertEqual(state.workspaces.map { $0.root.panes.map(\.url) }, [["https://a.example/"]])
        XCTAssertEqual(state.selectedWorkspaceID, state.workspaces.first?.id)
    }

    func testDeletingTheOnlyProfileWithPanesGivesTheOthersAWorkspace() {
        var state = AppStateData()
        let first = state.addProfile(name: "Akun 1", colorIndex: 0)
        let second = state.addProfile(name: "Akun 2", colorIndex: 1)
        state.workspaces.removeAll { $0.id == second.workspace.id }
        state.removeProfile(first.profile.id)
        XCTAssertEqual(state.workspaces.map { $0.root.panes.map(\.profileID) }, [[second.profile.id, second.profile.id]])
        XCTAssertEqual(state.selectedWorkspaceID, state.workspaces.first?.id)
    }

    private func splitID(of workspace: WorkspaceState) -> UUID {
        guard case .split(let split) = workspace.root else { return UUID() }
        return split.id
    }
}

/// state.json as XSpace 0.5.0 reads and writes it (a copy of its types), to check that going back
/// to 0.5.0 keeps every profile.
private struct Legacy050State: Codable {
    struct Pane: Codable, Equatable {
        var url: String
    }

    struct Profile: Codable, Equatable {
        var id: UUID
        var name: String
        var colorIndex: Int
        var panes: [Pane]
        var splitRatios: [Double]? = nil
    }

    var version = 1
    var profiles: [Profile] = []
    var selectedProfileID: UUID?
    var showAll = false
    var hibernatePolicy = "after15Minutes"
    var pendingDeletion: [UUID] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        selectedProfileID = try c.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        showAll = try c.decodeIfPresent(Bool.self, forKey: .showAll) ?? false
        pendingDeletion = try c.decodeIfPresent([UUID].self, forKey: .pendingDeletion) ?? []
        hibernatePolicy = (try? c.decodeIfPresent(String.self, forKey: .hibernatePolicy)) ?? "after15Minutes"
    }
}
