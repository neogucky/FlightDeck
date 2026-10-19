import XCTest

final class FlightDeckUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(screenshot:app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func fill(_ field: XCUIElement, _ text: String, _ app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout:10)); field.tap(); field.typeText(text)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
    }
    func testOverviewDescribesTheWholeTripAndBothIncomingAircraft() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        let trip = app.buttons["nextTrip"]
        XCTAssertTrue(trip.waitForExistence(timeout:10))
        for text in ["LH2055", "LX1107", "HAM → MUC → ZRH", "All on time"] {
            XCTAssertTrue(trip.label.contains(text), "Missing trip information: \(text)")
        }
        XCTAssertFalse(trip.label.contains("A weekend in Zurich"))
        let first = app.buttons["incoming-LH2055"]
        let second = app.buttons["incoming-LX1107"]
        XCTAssertTrue(first.exists)
        XCTAssertTrue(second.exists)
        XCTAssertTrue(first.label.contains("MUC → HAM"))
        XCTAssertTrue(second.label.contains("ZRH → MUC"))
        capture("Dashboard",app)
    }
    func testConnectedTripCanBeAddedAndOpened() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        app.buttons["addFlight"].tap()
        XCTAssertFalse(app.textFields["tripTitle"].exists)
        fill(app.textFields["flightNumber0"],"LH2061",app)
        fill(app.textFields["origin0"],"HAM",app)
        fill(app.textFields["destination0"],"MUC",app)
        app.swipeUp()
        app.buttons["addConnection"].tap()
        app.swipeUp()
        let second = app.textFields["flightNumber1"]
        fill(second,"LX1111",app)
        fill(app.textFields["destination1"],"ZRH",app)
        capture("Add connected flights",app)
        app.buttons["saveTrip"].tap()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:8))
        app.terminate()
        app.launchArguments = ["--uitesting-preserve"]
        app.launch()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        let trip = app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "LH2061")).firstMatch
        for _ in 0..<3 where !trip.isHittable { app.swipeUp() }
        XCTAssertTrue(trip.waitForExistence(timeout:5))
        trip.tap()
        XCTAssertTrue(app.staticTexts["LH2061"].waitForExistence(timeout:5))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["LX1111"].waitForExistence(timeout:5))
    }

    func testJournalAndDetailAndSettings() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        app.buttons["nextTrip"].tap()
        XCTAssertTrue(app.staticTexts["Airbus A320neo"].firstMatch.waitForExistence(timeout:5))
        capture("Trip details",app)
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Past adventures"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Johannesburg"].exists)
        capture("History",app)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout:5))
        capture("Settings",app)
    }
}
