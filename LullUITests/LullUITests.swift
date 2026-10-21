import XCTest

/// Walks the main flows against the simulated BedJet and keeps a screenshot of each screen.
final class LullUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-ephemeral"]
        app.launch()
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    func testOpensOnRemote() {
        XCTAssertTrue(app.staticTexts["Remote"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.buttons.firstMatch.label, "Remote")
        XCTAssertTrue(app.tabBars.buttons["Remote"].isSelected)
    }

    func testStartAndEndNight() {
        app.tabBars.buttons["Schedule"].tap()
        let start = app.buttons["Start Night"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        // The button enables once the simulated BedJet connects.
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 10)
        start.tap()

        let end = app.buttons["End Night"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'PHASE 1 OF'")).firstMatch.exists)
        sleep(2)
        capture("schedule-running")

        end.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
    }

    func testEditScheduleAndUseItTonight() {
        app.tabBars.buttons["Schedule"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Warm Welcome'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Add Phase"].waitForExistence(timeout: 5))
        capture("editor")

        // Remote stays loaded behind the editor and has its own Turbo and Gentle heat buttons,
        // so match the phase row by its duration and take the frontmost mode button.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Turbo' AND label CONTAINS '10 min'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Remove Phase"].waitForExistence(timeout: 5))
        let gentleHeat = app.buttons.matching(identifier: "Gentle heat")
        gentleHeat.element(boundBy: gentleHeat.count - 1).tap()
        sleep(1)
        capture("phase-editor")
        app.buttons["Done"].tap()

        // On taller screens Add Phase can sit behind the bottom bar until the list is scrolled up.
        app.swipeUp()
        app.buttons["Add Phase"].tap()
        XCTAssertTrue(app.buttons["Remove Phase"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Use Tonight"].tap()

        // Warm Welcome is now the featured schedule, so Cool Drift moves down and offers the swap back.
        XCTAssertTrue(app.buttons["Use Cool Drift tonight"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Use Warm Welcome tonight"].exists)
        capture("schedule-planned")

        app.buttons["Use Cool Drift tonight"].tap()
        XCTAssertTrue(app.buttons["Use Warm Welcome tonight"].waitForExistence(timeout: 5))
    }

    func testHistoryKeepsTheNight() {
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No nights yet"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Remote"].tap()
        let heat = app.buttons["Heat"]
        XCTAssertTrue(heat.waitForExistence(timeout: 10))
        sleep(2)
        heat.tap()
        XCTAssertTrue(app.sliders["Turns off in"].waitForExistence(timeout: 5))
        // A setting is recorded once the BedJet has held it for a few seconds.
        sleep(4)
        app.buttons["Off"].tap()
        sleep(4)

        // A schedule's phases are its own; only its start and end are recorded.
        app.tabBars.buttons["Schedule"].tap()
        let start = app.buttons["Start Night"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let end = app.buttons["End Night"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        sleep(4)
        end.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        sleep(4)

        app.tabBars.buttons["History"].tap()
        // The night is one row named after the schedule that ran, and opens up to the whole night.
        let night = app.buttons["Night"]
        XCTAssertTrue(night.waitForExistence(timeout: 5))
        XCTAssertTrue(night.label.hasSuffix("Cool Drift"))
        XCTAssertFalse(app.staticTexts["Turned off"].exists)
        capture("history-collapsed")
        night.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Heat ·'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Turned off"].exists)
        XCTAssertTrue(app.staticTexts["Started Cool Drift"].exists)
        XCTAssertTrue(app.staticTexts["Ended Cool Drift"].exists)
        // Nothing else: the schedule's first phase and the BedJet turning off with it are not separate entries.
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cool ·'")).count, 0)
        sleep(1)
        capture("history-expanded")

        night.tap()
        XCTAssertTrue(app.staticTexts["Turned off"].waitForNonExistence(timeout: 5))
    }

    func testHistoryListsNightsAsRows() {
        app.terminate()
        app.launchArguments = ["-ephemeral", "-demoHistory"]
        app.launch()
        app.tabBars.buttons["History"].tap()

        let nights = app.buttons.matching(identifier: "Night")
        XCTAssertTrue(nights.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(nights.count, 3)
        // Newest first; a night without a schedule is summed up by its times instead.
        XCTAssertTrue(nights.element(boundBy: 0).label.hasSuffix("Cool Drift"))
        XCTAssertTrue(nights.element(boundBy: 1).label.contains(" – "))
        capture("history-rows")

        nights.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["Turned off"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Timer ran out'")).firstMatch.exists)
        sleep(1)
        capture("history-row-expanded")
    }

    func testRemoteAndDevice() {
        let heat = app.buttons["Heat"]
        XCTAssertTrue(heat.waitForExistence(timeout: 10))
        sleep(2)
        heat.tap()
        // Turning a mode on asks for the longest run the simulated BedJet allows: 4 hours of heat.
        let timer = app.sliders["Turns off in"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == '4 hr'"), evaluatedWith: timer)
        waitForExpectations(timeout: 5)

        // A shorter time picked by hand sticks, and survives a fan change.
        timer.adjust(toNormalizedSliderPosition: 0)
        sleep(3)
        XCTAssertEqual(timer.value as? String, "5 min")
        app.sliders["Fan"].adjust(toNormalizedSliderPosition: 0.8)
        sleep(3)
        XCTAssertEqual(timer.value as? String, "5 min")

        // Switching mode starts over at that mode's longest run.
        app.buttons["Cool"].tap()
        expectation(for: NSPredicate(format: "value == '12 hr'"), evaluatedWith: timer)
        waitForExpectations(timeout: 5)
        app.buttons["Heat"].tap()
        expectation(for: NSPredicate(format: "value == '4 hr'"), evaluatedWith: timer)
        waitForExpectations(timeout: 5)
        capture("remote-heat")
        app.buttons["Off"].tap()

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'BedJet'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Saved on the BedJet"].waitForExistence(timeout: 5) || app.staticTexts["SAVED ON THE BEDJET"].waitForExistence(timeout: 2))
        capture("device")
    }
}
