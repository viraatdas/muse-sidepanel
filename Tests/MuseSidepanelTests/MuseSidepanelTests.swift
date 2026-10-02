import XCTest
@testable import MuseSidepanel

final class NavigationPolicyTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testMuseAndMetaSignInStayInThePanel() {
        XCTAssertTrue(WebController.isFirstParty(url("https://muse.ai/chat/123")))
        XCTAssertTrue(WebController.isFirstParty(url("https://auth.muse.ai/login")))
        XCTAssertTrue(WebController.isFirstParty(url("https://www.facebook.com/login")))
        XCTAssertTrue(WebController.isFirstParty(url("https://accounts.meta.com/")))
    }

    func testOtherSitesOpenInTheBrowser() {
        XCTAssertFalse(WebController.isFirstParty(url("https://example.com/")))
        XCTAssertFalse(WebController.isFirstParty(url("https://notmuse.ai/")))
        XCTAssertFalse(WebController.isFirstParty(url("https://muse.ai.evil.example/")))
        XCTAssertFalse(WebController.isFirstParty(url("mailto:someone@muse.ai")))
    }
}

final class SettingsTests: XCTestCase {
    func testWidthIsClamped() {
        let saved = Settings.width
        defer { Settings.width = saved }
        Settings.width = 10
        XCTAssertEqual(Settings.width, Settings.minWidth)
        Settings.width = 10_000
        XCTAssertEqual(Settings.width, Settings.maxWidth)
    }
}
