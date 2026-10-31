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
}
