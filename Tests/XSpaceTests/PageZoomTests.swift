import XCTest
@testable import XSpace

/// The zoom of a pane's page: automatic from the size of the pane, with the profile's own on top.
final class PageZoomTests: XCTestCase {
    private func automatic(_ width: CGFloat, _ height: CGFloat) -> Int {
        PageZoom.automatic(for: CGSize(width: width, height: height))
    }

    func testAPaneAsBigAsABrowserWindowShowsItsPageAt100Percent() {
        XCTAssertEqual(automatic(1024, 640), 100)
        XCTAssertEqual(automatic(1410, 717), 100, "one profile on a 13-inch MacBook Air")
        XCTAssertEqual(automatic(5000, 3000), 100, "never more than 100%")
    }

    func testASmallerPaneZoomsOutInStepsOf5Percent() {
        XCTAssertEqual(automatic(1247, 615), 95, "2 × 2 on a 27-inch display: by the height")
        XCTAssertEqual(automatic(829, 1268), 80, "3 side by side on a 27-inch display: by the width")
        XCTAssertEqual(automatic(972.8, 640), 95, "exactly 95%")
        XCTAssertEqual(automatic(972, 640), 90, "just below 95%")
    }

    func testTheAutomaticZoomStopsAt70Percent() {
        XCTAssertEqual(automatic(702, 717), 70, "2 side by side on a 13-inch MacBook Air")
        XCTAssertEqual(automatic(702, 214), 70, "1 + 3 on the right, there")
        XCTAssertEqual(automatic(0, 0), 70)
        XCTAssertEqual(automatic(-5, .nan), 70)
    }

    func testTheProfilesOwnZoomComesOnTop() {
        XCTAssertEqual(PageZoom.zoom(base: 70, offset: 10), 80)
        XCTAssertEqual(PageZoom.zoom(base: 70, offset: -60), 30, "from 30%")
        XCTAssertEqual(PageZoom.zoom(base: 100, offset: 250), 300, "to 300%")
        XCTAssertEqual(PageZoom.zoom(base: 70, offset: .max), 300, "a hand-edited state.json cannot overflow it")
        XCTAssertEqual(PageZoom.zoom(base: 70, offset: .min), 30)
    }

    func testZoomingInAndOutChangesWhatIsShown() {
        XCTAssertEqual(PageZoom.offset(0, base: 70, adding: 10), 10)
        XCTAssertEqual(PageZoom.offset(-40, base: 70, adding: -10), -40, "at 30% it stays")
        XCTAssertEqual(PageZoom.offset(-60, base: 70, adding: 10), -30, "from the 30% shown to 40%")
        XCTAssertEqual(PageZoom.offset(200, base: 100, adding: 10), 200, "at 300% it stays")
    }
}
