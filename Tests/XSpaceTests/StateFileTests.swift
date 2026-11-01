import XCTest
@testable import XSpace

/// Reading state.json from disk: no file yet, a readable file, and one that cannot be read.
final class StateFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xspace-statefile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var stateFile: URL { directory.appendingPathComponent("state.json") }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testWithoutAFileXSpaceStartsWithANewState() throws {
        XCTAssertTrue(StateStore.load(from: stateFile).profiles.isEmpty)
        XCTAssertEqual(try files(), [])
    }

    func testAReadableFileIsLoaded() throws {
        try Data(#"{"showAll": true}"#.utf8).write(to: stateFile)
        XCTAssertTrue(StateStore.load(from: stateFile).showAll)
        XCTAssertEqual(try files(), ["state.json"])
    }

    func testAnUnreadableFileIsMovedAsideInsteadOfOverwritten() throws {
        let damaged = Data(#"{"profiles": [{"id": "not a UUID", "name": "Akun 1"}]}"#.utf8)
        try damaged.write(to: stateFile)

        XCTAssertTrue(StateStore.load(from: stateFile).profiles.isEmpty, "XSpace starts over")
        let files = try files()
        XCTAssertEqual(files.count, 1, "\(files)")
        XCTAssertTrue(files[0].hasPrefix("state-unreadable-") && files[0].hasSuffix(".json"), files[0])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(files[0])), damaged)
    }
}
