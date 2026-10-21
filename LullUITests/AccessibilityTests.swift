import XCTest

/// Walks every screen as a VoiceOver user meets it: Xcode's accessibility audit on each, plus what the key controls say.
final class AccessibilityTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = ["-ephemeral", "-demoHistory"]
        app.launch()
    }

    /// The checks that matter to VoiceOver. Contrast, Dynamic Type and clipped text are about how things look, not what's read.
    private func audit(_ screen: String, allowingHiddenText: Bool = false) throws {
        try app.performAccessibilityAudit(for: [.elementDetection, .sufficientElementDescription, .trait, .hitRegion]) { issue in
            // Slider titles are hidden because the slider reads them, and a sheet leaves the screen beneath it on view.
            if allowingHiddenText && issue.auditType == .elementDetection { return true }
            XCTFail("\(screen): \(issue.compactDescription) – \(issue.element?.debugDescription ?? "")")
            return true
        }
    }

    private func element(_ predicate: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: predicate)).firstMatch
    }

    func testEveryScreen() throws {
        let heat = app.buttons["Heat"]
        XCTAssertTrue(heat.waitForExistence(timeout: 10))
        XCTAssertTrue(element("label BEGINSWITH 'Off, room'").waitForExistence(timeout: 10))
        try audit("remote-off")

        heat.tap()
        let timer = app.sliders["Turns off in"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == '4 hours'"), evaluatedWith: timer)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(element("label BEGINSWITH 'Heating, set to'").exists)
        try audit("remote-heat", allowingHiddenText: true)
        app.buttons["Off"].tap()

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BedJet,'")).firstMatch.tap()
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
        start.tap()
        XCTAssertTrue(app.buttons["End Night"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("label BEGINSWITH 'Cooling,' AND label ENDSWITH 'left'").exists)
        try audit("schedule-running")
        app.buttons["End Night"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Warm Welcome,'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Add Phase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Schedule name"].exists)
        let second = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Phase 2, Heat,' AND label CONTAINS '30 minutes, starts'")).firstMatch
        XCTAssertTrue(second.exists)
        try audit("editor")
        second.tap()
        XCTAssertTrue(app.buttons["Remove Phase"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.sliders["Duration"].value as? String, "30 minutes")
        try audit("phase-editor", allowingHiddenText: true)
        app.buttons["Done"].tap()
        app.buttons["Cancel"].tap()

        app.tabBars.buttons["History"].tap()
        // A night without a schedule is summed up by its times, read as a range rather than a dash.
        let night = app.buttons.matching(NSPredicate(format: "identifier == 'Night' AND label CONTAINS ' to '")).firstMatch
        XCTAssertTrue(night.waitForExistence(timeout: 5))
        XCTAssertEqual(night.value as? String, "Collapsed")
        night.tap()
        XCTAssertTrue(app.staticTexts["Turned off"].waitForExistence(timeout: 5))
        XCTAssertEqual(night.value as? String, "Expanded")
        try audit("history")
    }
}
