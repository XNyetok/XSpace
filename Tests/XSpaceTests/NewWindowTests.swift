import XCTest
@testable import XSpace

/// What a page's request for a new window opens: a popup window, or no window but a note in the
/// pane (a new tab). The features are what WebKit reports for each request (checked on macOS 27).
final class NewWindowTests: XCTestCase {
    private let none: [NSNumber?] = [nil, nil, nil, nil]

    func testLinksAndWindowOpenWithoutFeaturesAskForATab() {
        XCTAssertFalse(PopupWindowController.isPopupWindow(size: none, bars: none),
                       "target=\"_blank\", window.open(url) and window.open(url, '_blank', 'noopener')")
        XCTAssertFalse(PopupWindowController.isPopupWindow(size: none, bars: [1, 1, 1, 1]), "bars that stay")
    }

    func testASizeAPositionOrLeftOutBarsAskForAPopupWindow() {
        XCTAssertTrue(PopupWindowController.isPopupWindow(size: [500, 600, nil, nil], bars: none),
                      "width=500,height=600, as sign-in windows")
        XCTAssertTrue(PopupWindowController.isPopupWindow(size: [nil, nil, 100, 100], bars: none), "left=100,top=100")
        XCTAssertTrue(PopupWindowController.isPopupWindow(size: none, bars: [0, nil, 0, nil]), "toolbar=no,menubar=no")
        XCTAssertTrue(PopupWindowController.isPopupWindow(size: none, bars: [nil, nil, nil, 0]), "resizable=no")
    }
}
