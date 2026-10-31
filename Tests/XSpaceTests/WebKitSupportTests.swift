import WebKit
import XCTest
@testable import XSpace

/// Web view configuration, User-Agent, download file names, the error page and memory numbers.
final class WebKitSupportTests: XCTestCase {
    /// Isolation rule: a pane always uses the data store of its own profile.
    @MainActor
    func testPanesUseTheirProfileDataStore() {
        let store = WKWebsiteDataStore.nonPersistent()
        let config = WebKitSupport.makeConfiguration(store: store)
        XCTAssertTrue(config.websiteDataStore === store)
        XCTAssertEqual(config.applicationNameForUserAgent, WebKitSupport.userAgentSuffix)
        XCTAssertEqual(config.mediaTypesRequiringUserActionForPlayback, .all)
    }

    func testUserAgentHasSafarisFormat() {
        let suffix = WebKitSupport.userAgentSuffix
        XCTAssertNotNil(suffix.range(of: #"^Version/\d+(\.\d+)* Safari/605\.1\.15$"#, options: .regularExpression),
                        suffix)
    }

    // MARK: Downloads

    private let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)

    @MainActor
    private func destination(_ name: String, existing: Set<String> = []) -> String {
        DownloadCoordinator.destination(in: downloads, suggestedFilename: name) { existing.contains($0) }.path
    }

    @MainActor
    func testDownloadUsesTheSuggestedName() {
        XCTAssertEqual(destination("report.pdf"), "/Users/test/Downloads/report.pdf")
    }

    @MainActor
    func testDownloadNeverOverwritesAFile() {
        let existing: Set = ["/Users/test/Downloads/report.pdf", "/Users/test/Downloads/report 2.pdf"]
        XCTAssertEqual(destination("report.pdf", existing: existing), "/Users/test/Downloads/report 3.pdf")
        XCTAssertEqual(destination("README", existing: ["/Users/test/Downloads/README"]),
                       "/Users/test/Downloads/README 2")
    }

    @MainActor
    func testDownloadStaysInsideTheDownloadsFolder() {
        XCTAssertEqual(destination("../../Library/LaunchAgents/evil.plist"), "/Users/test/Downloads/evil.plist")
        XCTAssertEqual(destination("/etc/hosts"), "/Users/test/Downloads/hosts")
        for name in ["", ".", "..", "/", "folder/"] {
            XCTAssertEqual(destination(name), "/Users/test/Downloads/download", "suggested name: \(name)")
        }
    }

    // MARK: Error page and memory report

    func testErrorPageEscapesMessageAndURL() {
        let html = ErrorPage.html(message: "<script>alert(1)</script>",
                                  url: "https://x.test/\"><img src=x onerror=alert(1)>")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&quot;&gt;&lt;img"))
    }

    func testMemoryReportTotal() {
        var report = MemoryReport()
        report.app = 10 << 20
        report.gpu = 5 << 20
        report.network = 1 << 20
        report.profiles = [.init(name: "Akun 1", color: .systemBlue, bytes: 100 << 20, panes: 2, hidden: false),
                           .init(name: "Akun 2", color: .systemGreen, bytes: 0, panes: 0, hidden: true)]
        XCTAssertEqual(report.total, 116 << 20)
        XCTAssertFalse(report.totalText.hasPrefix("≈"))
        report.isApproximate = true
        XCTAssertTrue(report.totalText.hasPrefix("≈ "))
        XCTAssertEqual(MemoryProbe.format(0), "0 MB")
    }

    func testOwnProcessMemoryCanBeRead() throws {
        let sample = try XCTUnwrap(MemoryProbe.sample(of: getpid()))
        XCTAssertGreaterThan(sample.bytes, 0)
    }
}
