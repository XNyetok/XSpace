import XCTest
@testable import XSpace

/// Reading and writing state.json, including files written by older versions, and the changes to
/// the profiles and the layout.
final class SavedStateTests: XCTestCase {
    private let aiStudio = "https://aistudio.google.com/"
    private let sheets = "https://docs.google.com/spreadsheets/"

    private func decode(_ json: String) throws -> AppStateData {
        try JSONDecoder().decode(AppStateData.self, from: Data(json.utf8))
    }

    /// Profiles named "Akun 1", "Akun 2", … in the automatic layout.
    private func state(profiles count: Int) -> AppStateData {
        var state = AppStateData()
        for index in 0..<count {
            state.addProfile(name: "Akun \(index + 1)", colorIndex: index, inSlot: 0)
        }
        return state
    }

    private func ids(_ state: AppStateData) -> [UUID] {
        state.profiles.map(\.id)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let state = try decode("{}")
        XCTAssertEqual(state.version, 1)
        XCTAssertTrue(state.profiles.isEmpty)
        XCTAssertEqual(state.layout, .single, "0.5.0 without showAll: Fokus")
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

    // MARK: Older files

    func testA050FileInFokusModeShowsTheSelectedProfile() throws {
        let (first, second) = (UUID(), UUID())
        let state = try decode("""
            {"version": 1, "selectedProfileID": "\(second)", "showAll": false, "profiles": [
              {"id": "\(first)", "name": "Akun 1", "colorIndex": 0, "splitRatios": [0.3, 0.7],
               "panes": [{"url": "\(sheets)"}, {"url": "\(aiStudio)"}]},
              {"id": "\(second)", "name": "Akun 2", "colorIndex": 1,
               "panes": [{"url": "\(aiStudio)"}, {"url": "\(sheets)"}]}]}
            """)
        XCTAssertEqual(state.profiles.map(\.url), [sheets, aiStudio], "every profile keeps the page of its first pane")
        XCTAssertEqual(state.layout, .single)
        XCTAssertEqual(state.shownProfiles, [second])
        XCTAssertEqual(state.selectedProfileID, second)
    }

    func testA050FileInSemuaModeShowsEveryProfile() throws {
        let (first, second) = (UUID(), UUID())
        let state = try decode("""
            {"showAll": true, "profiles": [
              {"id": "\(first)", "name": "Akun 1", "colorIndex": 0, "panes": [{"url": "\(aiStudio)"}]},
              {"id": "\(second)", "name": "Akun 2", "colorIndex": 1, "panes": []}]}
            """)
        XCTAssertEqual(state.layout, .automatic)
        XCTAssertEqual(state.shownProfiles, [first, second])
        XCTAssertEqual(state.profiles.map(\.url), [aiStudio, nil], "a profile without panes shows the start page")
    }

    /// Version 2 was never released, but its files exist: the workspaces are left out, and the
    /// profiles' panes (written for 0.5.0) give each profile its page.
    func testAVersion2FileKeepsTheProfilesPages() throws {
        let id = UUID()
        let state = try decode("""
            {"version": 2, "showAll": false, "selectedProfileID": "\(id)", "workspaces": [{"id": "x"}],
             "selectedWorkspaceID": "\(UUID())", "profiles": [
              {"id": "\(id)", "name": "Akun 1", "colorIndex": 0, "panes": [{"url": "https://a.example/"}, {"url": "\(sheets)"}]}]}
            """)
        XCTAssertEqual(state.profiles.map(\.url), ["https://a.example/"])
        XCTAssertEqual(state.shownProfiles, [id])
        let written = String(decoding: try state.encodedForDisk(), as: UTF8.self)
        XCTAssertFalse(written.contains("workspaces"))
    }

    // MARK: Writing

    func testTheStateSurvivesARoundTrip() throws {
        var state = state(profiles: 3)
        state.switchLayout(to: .oneAndThree, active: nil)
        state.layoutSizes["oneAndThree"] = [[0.6, 0.4], [1, 1, 2]]
        state.hibernatePolicy = .memoryPressureOnly
        state.pendingDeletion = [UUID()]
        state.profiles[1].url = "https://b.example/"

        let decoded = try JSONDecoder().decode(AppStateData.self, from: state.encodedForDisk())
        XCTAssertEqual(decoded.version, AppStateData.currentVersion)
        XCTAssertEqual(decoded.profiles.map(\.url), state.profiles.map(\.url))
        XCTAssertEqual(decoded.layout, .oneAndThree)
        XCTAssertEqual(decoded.shownProfiles, state.shownProfiles)
        XCTAssertEqual(decoded.layoutSizes, state.layoutSizes)
        XCTAssertEqual(decoded.previousLayout, nil)
        XCTAssertEqual(decoded.hibernatePolicy, .memoryPressureOnly)
        XCTAssertEqual(decoded.pendingDeletion, state.pendingDeletion)
    }

    func testTheSavedFileStaysReadableFor050() throws {
        var state = state(profiles: 2)
        state.profiles[0].url = "https://a.example/"
        let legacy = try JSONDecoder().decode(Legacy050State.self, from: state.encodedForDisk())
        XCTAssertEqual(legacy.profiles.map(\.id), ids(state))
        XCTAssertEqual(legacy.profiles.map { $0.panes.map(\.url) }, [["https://a.example/"], [""]],
                       "one pane per profile, an empty one for a profile without a page")
        XCTAssertTrue(legacy.showAll, "more than one profile on screen: Semua")
        XCTAssertEqual(legacy.selectedProfileID, state.selectedProfileID)

        state.switchLayout(to: .single, active: state.profiles[0].id)
        let fokus = try JSONDecoder().decode(Legacy050State.self, from: state.encodedForDisk())
        XCTAssertFalse(fokus.showAll)
        XCTAssertEqual(fokus.selectedProfileID, state.profiles[0].id)
    }

    func testAProfileWithoutAPageStaysWithoutOne() throws {
        let state = state(profiles: 1)
        let written = String(decoding: try state.encodedForDisk(), as: UTF8.self)
        XCTAssertFalse(written.contains(#""url" : null"#), written)
        XCTAssertNil(try JSONDecoder().decode(AppStateData.self, from: state.encodedForDisk()).profiles[0].url)
        let id = UUID()
        let empty = try decode(#"{"profiles": [{"id": "\#(id)", "name": "Akun 1", "colorIndex": 0, "url": ""}]}"#)
        XCTAssertNil(empty.profiles[0].url, "an empty address is no page")
    }

    /// 0.5.0 saves the file again without the keys it does not know, but keeps "version": 3.
    func testGoingBackTo050AndForwardAgainKeepsEveryProfile() throws {
        var state = state(profiles: 3)
        state.profiles[2].url = "https://c.example/"
        state.switchLayout(to: .single, active: state.profiles[2].id)
        let savedBy050 = try JSONEncoder().encode(JSONDecoder().decode(Legacy050State.self, from: state.encodedForDisk()))
        let reread = try JSONDecoder().decode(AppStateData.self, from: savedBy050)
        XCTAssertEqual(reread.version, 3)
        XCTAssertEqual(ids(reread), ids(state))
        XCTAssertEqual(reread.profiles.map(\.url), state.profiles.map(\.url))
        XCTAssertEqual(reread.layout, .single)
        XCTAssertEqual(reread.shownProfiles, [state.profiles[2].id])
    }

    // MARK: Layouts and profiles

    func testUnknownAndRepeatedProfilesLeaveTheirSlotEmpty() throws {
        let (first, second) = (UUID(), UUID())
        let state = try decode("""
            {"layout": "twoByTwo", "layoutSlots": {"twoByTwo": ["\(first)", "\(UUID())", "\(first)", "\(second)"]},
             "profiles": [{"id": "\(first)", "name": "Akun 1", "colorIndex": 0, "url": "\(aiStudio)"},
                          {"id": "\(second)", "name": "Akun 2", "colorIndex": 1, "url": "\(aiStudio)"}]}
            """)
        XCTAssertEqual(state.shownProfiles, [first, nil, nil, second])
    }

    func testAFixedLayoutWithoutProfilesIsFilled() throws {
        let (first, second) = (UUID(), UUID())
        let state = try decode("""
            {"layout": "oneAndTwo", "layoutSlots": {"oneAndTwo": [null, "\(UUID())"]},
             "profiles": [{"id": "\(first)", "name": "Akun 1", "colorIndex": 0, "url": "\(aiStudio)"},
                          {"id": "\(second)", "name": "Akun 2", "colorIndex": 1, "url": "\(aiStudio)"}]}
            """)
        XCTAssertEqual(state.shownProfiles, [first, second, nil])
    }

    func testAnUnknownLayoutFallsBackToOneOfTheKnownOnes() throws {
        XCTAssertEqual(try decode(#"{"layout": "hexagons", "showAll": true}"#).layout, .automatic)
        XCTAssertEqual(try decode(#"{"layout": "hexagons"}"#).layout, .single)
    }

    func testTheAutomaticLayoutShowsEveryProfileInToolbarOrder() {
        let state = state(profiles: 3)
        XCTAssertEqual(state.layout, .automatic)
        XCTAssertEqual(state.shownProfiles, ids(state).map { $0 })
        XCTAssertEqual(state.sizesKey, "automatic-3", "its sizes depend on the number of profiles")
    }

    func testResettingTheSizesOfALayout() {
        var state = state(profiles: 3)
        state.switchLayout(to: .oneAndTwo, active: nil)
        state.layoutSizes = ["oneAndTwo": [[0.7, 0.3], [0.5, 0.5]], "twoColumns": [[0.2, 0.8]], "automatic-3": [[1, 2, 3]]]
        XCTAssertTrue(state.hasCustomSizes)
        state.resetSizes()
        XCTAssertFalse(state.hasCustomSizes)
        XCTAssertEqual(state.layoutSizes, ["twoColumns": [[0.2, 0.8]], "automatic-3": [[1, 2, 3]]],
                       "the other layouts keep their sizes")
        state.switchLayout(to: .automatic, active: nil)
        XCTAssertTrue(state.hasCustomSizes, "the automatic layout's sizes go with the number of profiles")
        state.resetSizes()
        XCTAssertEqual(state.layoutSizes, ["twoColumns": [[0.2, 0.8]]])
    }

    func testSwitchingToAFixedLayoutTheFirstTime() {
        var state = state(profiles: 3)
        let (a, b, c) = (state.profiles[0].id, state.profiles[1].id, state.profiles[2].id)
        state.switchLayout(to: .twoColumns, active: c)
        XCTAssertEqual(state.shownProfiles, [a, c], "the profiles shown, the active one kept")
        XCTAssertEqual(state.selectedProfileID, c)
        state.switchLayout(to: .oneAndThree, active: c)
        XCTAssertEqual(state.shownProfiles, [a, c, b, nil], "then the others; an empty slot is left")
    }

    func testEveryLayoutRemembersItsProfiles() {
        var state = state(profiles: 3)
        let (a, b, c) = (state.profiles[0].id, state.profiles[1].id, state.profiles[2].id)
        state.switchLayout(to: .twoColumns, active: nil)
        state.show(c, inSlot: 1)
        XCTAssertEqual(state.shownProfiles, [a, c])
        state.switchLayout(to: .single, active: a)
        XCTAssertEqual(state.shownProfiles, [a], "the single-profile layout shows the active profile")
        XCTAssertEqual(state.previousLayout, .twoColumns)
        state.switchLayout(to: .twoColumns, active: b)
        XCTAssertEqual(state.shownProfiles, [a, c], "as it was")
    }

    func testShowingAProfileInASlot() {
        var state = state(profiles: 3)
        let (a, b, c) = (state.profiles[0].id, state.profiles[1].id, state.profiles[2].id)
        state.switchLayout(to: .twoColumns, active: nil)
        XCTAssertEqual(state.shownProfiles, [a, b])
        state.show(c, inSlot: 0)
        XCTAssertEqual(state.shownProfiles, [c, b], "a profile that is not shown takes the place")
        XCTAssertEqual(state.selectedProfileID, c)
        state.show(b, inSlot: 0)
        XCTAssertEqual(state.shownProfiles, [b, c], "a profile shown elsewhere trades places")
        state.show(UUID(), inSlot: 0)
        state.show(a, inSlot: 5)
        XCTAssertEqual(state.shownProfiles, [b, c], "unknown profiles and slots change nothing")
    }

    func testTheAutomaticLayoutChangesTheToolbarOrderWhenProfilesTradePlaces() {
        var state = state(profiles: 3)
        let (a, b, c) = (state.profiles[0].id, state.profiles[1].id, state.profiles[2].id)
        state.swapSlots(0, 2)
        XCTAssertEqual(ids(state), [c, b, a])
        state.show(c, inSlot: 1)
        XCTAssertEqual(ids(state), [b, c, a])
    }

    func testANewProfileGoesToAnEmptySlotOrTheGivenOne() {
        var state = state(profiles: 1)
        state.switchLayout(to: .twoColumns, active: nil)
        let second = state.addProfile(name: "Akun 2", colorIndex: 1, inSlot: 0)
        XCTAssertEqual(state.shownProfiles, [state.profiles[0].id, second.id], "the empty slot")
        let third = state.addProfile(name: "Akun 3", colorIndex: 2, inSlot: 0)
        XCTAssertEqual(state.shownProfiles, [third.id, second.id], "no empty slot: the given one")
        XCTAssertEqual(state.selectedProfileID, third.id)
        XCTAssertNil(third.url, "a new profile has no page yet: its pane shows the start page")
    }

    // MARK: The first start

    func testTheFirstStartMakesAProfileForEveryPaneOfTheLayout() {
        var state = AppStateData()
        state.start(with: .oneAndThree)
        XCTAssertEqual(state.layout, .oneAndThree)
        XCTAssertEqual(state.profiles.map(\.name), ["Akun 1", "Akun 2", "Akun 3", "Akun 4"])
        XCTAssertEqual(state.profiles.map(\.colorIndex), [0, 1, 2, 3], "every profile in its own color")
        XCTAssertEqual(state.shownProfiles, ids(state).map { $0 }, "one profile in each pane, in order")
        XCTAssertEqual(state.profiles.map(\.url), [nil, nil, nil, nil], "nothing to load yet")
        XCTAssertEqual(state.selectedProfileID, state.profiles[0].id, "the first one is the active profile")
        XCTAssertNil(state.previousLayout)
    }

    func testTheFirstStartWithOneOrEveryProfile() {
        var single = AppStateData()
        single.start(with: .single)
        XCTAssertEqual(single.profiles.count, 1)
        XCTAssertEqual(single.shownProfiles, [single.profiles[0].id])
        var automatic = AppStateData()
        automatic.start(with: .automatic)
        XCTAssertEqual(automatic.profiles.count, 1, "the automatic layout starts with one profile")
        XCTAssertEqual(automatic.shownProfiles, [automatic.profiles[0].id])
    }

    func testAfterTheLastProfileIsDeletedXSpaceStartsOver() {
        var state = state(profiles: 1)
        state.switchLayout(to: .twoColumns, active: nil)
        let id = state.profiles[0].id
        state.removeProfile(id)
        XCTAssertTrue(state.profiles.isEmpty)
        XCTAssertEqual(state.shownProfiles, [nil, nil])
        XCTAssertNil(state.selectedProfileID)
        XCTAssertEqual(state.pendingDeletion, [id])
        state.start(with: .oneAndTwo)
        XCTAssertEqual(state.layout, .oneAndTwo, "the welcome screen starts over")
        XCTAssertEqual(state.shownProfiles, ids(state).map { $0 })
        XCTAssertEqual(state.profiles.map(\.name), ["Akun 1", "Akun 2", "Akun 3"])
    }

    func testThereIsOnlyOneFirstStart() {
        var state = state(profiles: 2)
        let before = ids(state)
        state.start(with: .twoByTwo)
        XCTAssertEqual(ids(state), before, "with profiles, nothing changes")
        XCTAssertEqual(state.layout, .automatic)
    }

    func testDeletingAProfileGivesItsPlaceToOneThatIsHidden() {
        var state = state(profiles: 3)
        let (a, b, c) = (state.profiles[0].id, state.profiles[1].id, state.profiles[2].id)
        state.switchLayout(to: .twoColumns, active: nil)
        state.selectedProfileID = b
        state.removeProfile(b)
        XCTAssertEqual(state.shownProfiles, [a, c])
        XCTAssertEqual(state.selectedProfileID, a)
        XCTAssertEqual(state.pendingDeletion, [b])
        state.removeProfile(c)
        XCTAssertEqual(state.shownProfiles, [a, nil], "no hidden profile left: the slot stays empty")
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
