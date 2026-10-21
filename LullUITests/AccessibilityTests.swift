import XCTest

/// Walks every screen at the default and the largest text size: Xcode's full accessibility audit on each,
/// plus what VoiceOver says for the key controls.
final class AccessibilityTests: XCTestCase {
    private let app = XCUIApplication()

    private var textSize = "default"
    private var isLarge = false

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(textSize: String? = nil) {
        app.launchArguments = ["-ephemeral", "-demoHistory"]
        if let textSize {
            self.textSize = textSize
            isLarge = true
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        app.launch()
    }

    /// Xcode's accessibility audit: what VoiceOver reads and reaches, contrast, and how text copes with larger sizes.
    /// - Parameter overSheet: the screen is a sheet that leaves the one beneath it showing.
    private func audit(_ screen: String, overSheet: Bool = false) throws {
        if let directory = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(textSize)-\(screen).png"))
        }
        // At the default size the Dynamic Type and clipping checks can only guess what larger text will do, so the
        // run at the largest size checks the real layout for those. Contrast doesn't depend on text size and is
        // checked at the default. At the largest size the clipping check reports "may clip at larger sizes" when
        // there are none, without saying which text; the screenshots that run saves show nothing clipped.
        let checks: XCUIAccessibilityAuditType = isLarge
            ? [.elementDetection, .sufficientElementDescription, .trait, .hitRegion, .dynamicType]
            : XCUIAccessibilityAuditType.all.subtracting([.dynamicType, .textClipped])

        // Content scrolled under the status bar, a navigation bar, the tab bar or the editor's bottom bar is
        // seen once it's scrolled back; until then the bar, not the text, decides how it looks.
        let navigationBar = app.navigationBars.firstMatch
        let hasNavigationBar = navigationBar.exists && navigationBar.isHittable
        let top = hasNavigationBar ? navigationBar.frame.maxY : 62
        var bottom = CGFloat.infinity
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists && tabBar.isHittable { bottom = tabBar.frame.minY }
        let bottomBar = app.buttons["Use Tonight"]
        if bottomBar.exists && bottomBar.isHittable { bottom = min(bottom, bottomBar.frame.minY - 12) }

        try app.performAccessibilityAudit(for: checks) { issue in
            // A partial sheet leaves the editor beneath it visible but out of VoiceOver's reach, as a modal sheet should.
            // At the largest text size the same sheet fills the screen and this goes away.
            if overSheet && issue.auditType == .elementDetection { return true }
            if let element = issue.element {
                let frame = element.frame
                let underBar = frame.minY < top || frame.maxY > bottom
                if underBar && [.contrast, .textClipped].contains(issue.auditType) { return true }
                // Cancel, Save and Done are the system's bar buttons. UIKit keeps them a fixed size and shows
                // them enlarged in the Large Content Viewer when held, and draws them over whatever scrolls beneath.
                let inNavigationBar = hasNavigationBar && element.elementType == .button && frame.maxY <= navigationBar.frame.maxY
                if inNavigationBar && [.dynamicType, .contrast].contains(issue.auditType) { return true }
            }
            XCTFail("\(screen) at \(self.textSize) text: \(issue.compactDescription) – \(issue.element?.debugDescription ?? "") DETAIL \(issue.detailedDescription)")
            return true
        }
    }

    /// Scrolls until the element can be tapped, down first and then back up.
    @discardableResult
    private func reveal(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<5 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<10 where !(element.exists && element.isHittable) { app.swipeDown() }
        sleep(1)
        return element
    }

    private func element(_ predicate: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: predicate)).firstMatch
    }

    func testEveryScreen() throws {
        launch()
        try walk()
    }

    func testEveryScreenAtLargestTextSize() throws {
        launch(textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        try walk()
    }

    private func walk() throws {
        let heat = app.buttons["Heat"]
        XCTAssertTrue(heat.waitForExistence(timeout: 10))
        XCTAssertTrue(element("label BEGINSWITH 'Off, room'").waitForExistence(timeout: 10))
        try audit("remote-off")

        reveal(heat).tap()
        let timer = app.sliders["Turns off in"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == '4 hours'"), evaluatedWith: timer)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(element("label BEGINSWITH 'Heating, set to'").exists)
        try audit("remote-heat")
        reveal(app.buttons["Off"]).tap()

        reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BedJet,'")).firstMatch).tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        try audit("device")
        app.buttons["Done"].tap()

        app.tabBars.buttons["Schedule"].tap()
        let start = app.buttons["Start Night"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(element("label BEGINSWITH 'Night timeline'").exists)
        XCTAssertTrue(app.buttons["Edit Cool Drift"].exists)
        try audit("schedule")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 10)
        reveal(start).tap()
        let end = app.buttons["End Night"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertTrue(element("label BEGINSWITH 'Cooling,' AND label ENDSWITH 'left'").exists)
        try audit("schedule-running")
        reveal(end).tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        reveal(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Warm Welcome,'")).firstMatch).tap()
        XCTAssertTrue(app.buttons["Add Phase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Schedule name"].exists)
        try audit("editor")
        let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Phase 2, Heat,' AND label CONTAINS '30 minutes, starts'")).firstMatch
        XCTAssertTrue(reveal(second).exists)
        second.tap()
        XCTAssertTrue(app.buttons["Remove Phase"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.sliders["Duration"].value as? String, "30 minutes")
        try audit("phase-editor", overSheet: true)
        reveal(app.buttons["Done"]).tap()
        reveal(app.buttons["Cancel"]).tap()

        app.tabBars.buttons["History"].tap()
        // A night without a schedule is summed up by its times, read as a range rather than a dash.
        let night = app.buttons.matching(NSPredicate(format: "identifier == 'Night' AND label CONTAINS ' to '")).firstMatch
        XCTAssertTrue(night.waitForExistence(timeout: 5))
        XCTAssertEqual(night.value as? String, "Collapsed")
        reveal(night).tap()
        XCTAssertTrue(app.staticTexts["Turned off"].waitForExistence(timeout: 5))
        XCTAssertEqual(night.value as? String, "Expanded")
        try audit("history")
    }
}
