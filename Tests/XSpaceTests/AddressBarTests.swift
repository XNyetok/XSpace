import XCTest
@testable import XSpace

/// `PaneView.resolve(_:)`: what the address bar opens for typed text.
final class AddressBarTests: XCTestCase {
    @MainActor
    private func resolve(_ text: String) -> String? {
        PaneView.resolve(text)?.absoluteString
    }

    @MainActor
    func testFullURLsAreKept() {
        XCTAssertEqual(resolve("https://example.com/a?b=1#c"), "https://example.com/a?b=1#c")
        XCTAssertEqual(resolve("http://example.com"), "http://example.com")
        XCTAssertEqual(resolve("about:blank"), "about:blank")
    }

    @MainActor
    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(resolve("  example.com \n"), "https://example.com")
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("   "))
    }

    @MainActor
    func testDomainsOpenOverHTTPS() {
        XCTAssertEqual(resolve("example.com"), "https://example.com")
        XCTAssertEqual(resolve("docs.google.com/spreadsheets/"), "https://docs.google.com/spreadsheets/")
        XCTAssertEqual(resolve("example.com:8443/x"), "https://example.com:8443/x")
    }

    @MainActor
    func testLocalAddressesOpenOverHTTP() {
        XCTAssertEqual(resolve("localhost"), "http://localhost")
        XCTAssertEqual(resolve("localhost:3000/app"), "http://localhost:3000/app")
        XCTAssertEqual(resolve("127.0.0.1:8080"), "http://127.0.0.1:8080")
        XCTAssertEqual(resolve("192.168.1.1/admin"), "http://192.168.1.1/admin")
    }

    /// What shortcuts accept: addresses, not search terms.
    func testSearchTermsAreNoAddress() {
        XCTAssertEqual(PaneView.address("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(PaneView.address("localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertNil(PaneView.address("gemini api pricing"))
        XCTAssertNil(PaneView.address("1.5 kg"))
        XCTAssertNil(PaneView.address(""))
    }

    @MainActor
    func testOtherTextIsAGoogleSearch() {
        XCTAssertEqual(resolve("gemini api pricing"), "https://www.google.com/search?q=gemini%20api%20pricing")
        XCTAssertEqual(resolve("1.5 kg"), "https://www.google.com/search?q=1.5%20kg")
    }

    /// Typed text must never turn into a javascript:, file:, data: or other non-web navigation.
    @MainActor
    func testTypedTextNeverOpensOtherSchemes() {
        let inputs = ["javascript:alert(1)", "javascript:alert(document.cookie)", "file:///etc/passwd",
                      "data:text/html,<b>hi</b>", "mailto:someone@example.com", "x-apple.systempreferences:"]
        for text in inputs {
            let scheme = PaneView.resolve(text)?.scheme
            XCTAssertTrue(scheme == nil || scheme == "http" || scheme == "https", "\(text) → \(scheme ?? "nil")")
        }
    }
}
