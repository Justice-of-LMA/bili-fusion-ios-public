import XCTest
import WebKit
@testable import Fusion

final class LoginBrowserTests: XCTestCase {
    @MainActor func testOfficialPageBrowserIdentityIsAvailableBeforeNavigation() async throws {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        for tablet in [false, true] {
            let web = WKWebView()
            web.customUserAgent = LoginController.browserUserAgent(version: version, tablet: tablet)
            let actual = try await web.evaluateJavaScript("navigator.userAgent") as? String
            XCTAssertEqual(actual, web.customUserAgent)
            XCTAssertTrue(actual?.contains("Version/26.2") == true)
            XCTAssertTrue(actual?.contains("Safari/605.1.15") == true)
            XCTAssertEqual(actual?.contains("Mobile/"), !tablet)
            XCTAssertEqual(actual?.contains("Macintosh"), tablet)
        }
    }
}
