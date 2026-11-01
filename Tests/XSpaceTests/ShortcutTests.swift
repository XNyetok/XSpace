import XCTest
@testable import XSpace

/// The shortcuts on a profile's start page: what the dialog accepts, saving them, and adding,
/// changing and removing them.
final class ShortcutTests: XCTestCase {
    private let example = Shortcut(title: "Example", url: "https://example.com")
    private let exampleOrg = Shortcut(title: "Example Org", url: "https://example.org")

    /// Profiles named "Akun 1", "Akun 2", … without shortcuts.
    private func state(profiles count: Int) -> AppStateData {
        var state = AppStateData()
        for index in 0..<count {
            state.addProfile(name: "Akun \(index + 1)", colorIndex: index, inSlot: 0)
        }
        return state
    }

    func testTheDialogTakesTheAddressOfAWebsite() {
        XCTAssertEqual(Shortcut(name: " Example ", address: "example.com"), example)
        XCTAssertEqual(Shortcut(name: "", address: "https://www.example.org/a?b=1"),
                       Shortcut(title: "example.org", url: "https://www.example.org/a?b=1"),
                       "without a name, the site's")
        XCTAssertEqual(Shortcut(name: "Lokal", address: "localhost:3000")?.url, "http://localhost:3000")
        for address in ["", "   ", "gemini api pricing", "about:blank", "javascript:alert(1)", "file:///etc/hosts"] {
            XCTAssertNil(Shortcut(name: "x", address: address), address)
        }
    }

    func testShortcutsAreSavedWithTheirProfile() throws {
        var state = state(profiles: 2)
        state.addShortcut(example, to: state.profiles[0].id)
        let decoded = try JSONDecoder().decode(AppStateData.self, from: state.encodedForDisk())
        XCTAssertEqual(decoded.profiles.map(\.shortcuts), [[example], []])
    }

    func testOlderAndDamagedFilesHaveNoShortcuts() throws {
        let id = UUID()
        let older = try JSONDecoder().decode(AppStateData.self, from: Data("""
            {"profiles": [{"id": "\(id)", "name": "Akun 1", "colorIndex": 0, "url": "https://example.com/"}]}
            """.utf8))
        XCTAssertEqual(older.profiles.first?.shortcuts, [])
        let damaged = try JSONDecoder().decode(AppStateData.self, from: Data("""
            {"profiles": [{"id": "\(id)", "name": "Akun 1", "colorIndex": 0, "shortcuts": [{"title": 1}]}]}
            """.utf8))
        XCTAssertEqual(damaged.profiles.map(\.id), [id], "the profile stays")
        XCTAssertEqual(damaged.profiles.first?.shortcuts, [])
    }

    func testAddingAShortcut() {
        var state = state(profiles: 2)
        let (first, second) = (state.profiles[0].id, state.profiles[1].id)
        state.addShortcut(example, to: first)
        state.addShortcut(Shortcut(title: "Again", url: example.url), to: first)
        XCTAssertEqual(state.profiles.map(\.shortcuts), [[example], []], "once per address, in that profile only")
        for index in 0..<(Shortcut.limit + 2) {
            state.addShortcut(Shortcut(title: "\(index)", url: "https://\(index).example"), to: second)
        }
        XCTAssertEqual(state.profiles[1].shortcuts.count, Shortcut.limit)
        XCTAssertEqual(state.profiles[1].shortcuts.first?.title, "0", "in the order they were added")
    }

    func testAddingAShortcutToEveryProfile() {
        var state = state(profiles: 3)
        state.addShortcut(exampleOrg, to: state.profiles[1].id)
        for index in 0..<Shortcut.limit {
            state.addShortcut(Shortcut(title: "\(index)", url: "https://\(index).example"), to: state.profiles[2].id)
        }
        state.addShortcut(example, to: state.profiles[0].id, everywhere: true)
        XCTAssertEqual(state.profiles[0].shortcuts, [example])
        XCTAssertEqual(state.profiles[1].shortcuts, [exampleOrg, example])
        XCTAssertFalse(state.profiles[2].shortcuts.contains(example), "a profile with ten shortcuts has no room")
        state.addShortcut(example, to: state.profiles[1].id, everywhere: true)
        XCTAssertEqual(state.profiles[1].shortcuts, [exampleOrg, example], "nor one with that address")
    }

    func testChangingAndRemovingAShortcut() {
        var state = state(profiles: 2)
        let (first, second) = (state.profiles[0].id, state.profiles[1].id)
        state.addShortcut(example, to: first, everywhere: true)
        state.addShortcut(exampleOrg, to: first)
        let renamed = Shortcut(title: "Contoh", url: example.url)
        state.replaceShortcut(example, of: first, with: renamed)
        XCTAssertEqual(state.profiles[0].shortcuts, [renamed, exampleOrg], "in its place")
        state.removeShortcut(renamed, from: first)
        XCTAssertEqual(state.profiles[0].shortcuts, [exampleOrg])
        XCTAssertEqual(state.profiles[1].shortcuts, [example], "the other profiles keep theirs")
        state.removeShortcut(example, from: first)
        state.replaceShortcut(renamed, of: second, with: exampleOrg)
        XCTAssertEqual(state.profiles.map(\.shortcuts), [[exampleOrg], [example]], "unknown shortcuts change nothing")
    }
}
