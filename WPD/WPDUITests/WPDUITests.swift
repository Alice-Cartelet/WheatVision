import XCTest
final class WPDUITests: XCTestCase {
    func testNavigationAndCameraFallback() {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription:"相机权限") { alert in
            let allow = alert.buttons["允许"]
            if allow.exists { allow.tap(); return true }
            let ok = alert.buttons["OK"]
            if ok.exists { ok.tap(); return true }
            return false
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["识别"].waitForExistence(timeout:10))
        XCTAssertEqual(app.tabBars.buttons.count, 2)
        app.tabBars.buttons["历史"].tap()
        XCTAssertTrue(app.navigationBars["历史"].exists)
        app.tabBars.buttons["识别"].tap()
        XCTAssertTrue(app.buttons["拍照分析"].exists)
    }
}
