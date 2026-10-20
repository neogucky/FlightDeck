import XCTest

final class FlightDeckUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(screenshot:app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func fill(_ field: XCUIElement, _ text: String, _ app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout:10))
        for _ in 0..<3 where !field.isHittable { app.swipeUp() }
        field.tap()
        if let value = field.value as? String,value != field.placeholderValue,!value.isEmpty {
            field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:value.count))
        }
        field.typeText(text)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
    }
    private func authenticate(_ app: XCUIApplication, username: String, register: Bool) {
        fill(app.textFields["serverAddress"],"http://localhost:18787",app)
        app.buttons["connectServer"].tap()
        XCTAssertTrue(app.textFields["accountUsername"].waitForExistence(timeout:10))
        capture("Account sign in",app)
        if register { app.segmentedControls["accountMode"].buttons["Register"].tap() }
        fill(app.textFields["accountUsername"],username,app)
        fill(app.secureTextFields["accountPassword"],"UI account test password",app)
        app.swipeUp()
        capture(register ? "Account registration":"Account login filled",app)
        XCTAssertTrue(app.buttons["authenticate"].isEnabled,app.debugDescription)
        app.buttons["authenticate"].tap()
    }
    func testAccountOnboardingSessionAndUsageIsolation() {
        let app = XCUIApplication();app.launchArguments = ["--uitesting"];app.launch()
        app.tabBars.buttons["Settings"].tap()
        let username = "ui-"+UUID().uuidString.prefix(10).lowercased()
        authenticate(app,username:username,register:true)
        XCTAssertTrue(app.secureTextFields["providerAPIKey"].waitForExistence(timeout:10))
        capture("API key setup",app)
        fill(app.secureTextFields["providerAPIKey"],"flightdeck-test-ui-key-"+username,app)
        app.swipeUp()
        app.buttons["saveAPIKey"].tap()
        XCTAssertTrue(app.staticTexts["signedInUsername"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["signedInUsername"].label,username)
        capture("Signed in account",app)
        app.tabBars.buttons["Usage"].tap()
        XCTAssertTrue(app.staticTexts["FlightAware reported"].waitForExistence(timeout:10))
        capture("Account usage",app)
        app.tabBars.buttons["Trips"].tap()
        app.buttons["addFlight"].tap()
        fill(app.textFields["flightNumber0"],"LH2055",app)
        fill(app.textFields["origin0"],"HAM",app)
        fill(app.textFields["destination0"],"MUC",app)
        app.buttons["saveTrip"].tap()
        XCTAssertTrue(app.buttons["nextTrip"].waitForExistence(timeout:10))
        app.terminate();app.launchArguments = ["--uitesting-session"];app.launch()
        XCTAssertTrue(app.buttons["nextTrip"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["signedInUsername"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["signedInUsername"].label,username)
        app.buttons["signOut"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout:10))
        authenticate(app,username:username+"-b",register:true)
        XCTAssertTrue(app.buttons["Set up later"].waitForExistence(timeout:10));app.buttons["Set up later"].tap()
        app.tabBars.buttons["Trips"].tap()
        XCTAssertTrue(app.staticTexts["Where to next?"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["nextTrip"].exists)
        app.tabBars.buttons["Settings"].tap();app.buttons["signOut"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout:10))
        authenticate(app,username:username,register:false)
        XCTAssertTrue(app.staticTexts["signedInUsername"].waitForExistence(timeout:10))
        XCTAssertFalse(app.secureTextFields["providerAPIKey"].exists)
        app.tabBars.buttons["Trips"].tap();XCTAssertTrue(app.buttons["nextTrip"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap();app.buttons["signOut"].tap()
    }
    func testUsageAfterFlightLookup() {
        let app = XCUIApplication();app.launchArguments = ["--uitesting"];app.launch()
        app.tabBars.buttons["Settings"].tap()
        let username = "usage-"+UUID().uuidString.prefix(8).lowercased()
        authenticate(app,username:username,register:true)
        XCTAssertTrue(app.secureTextFields["providerAPIKey"].waitForExistence(timeout:10))
        fill(app.secureTextFields["providerAPIKey"],"flightdeck-test-usage-key-"+username,app)
        app.swipeUp();app.buttons["saveAPIKey"].tap()
        XCTAssertTrue(app.staticTexts["signedInUsername"].waitForExistence(timeout:10))
        app.tabBars.buttons["Trips"].tap();app.buttons["addFlight"].tap()
        fill(app.textFields["flightNumber0"],"LH2055",app)
        app.buttons["saveTrip"].tap()
        XCTAssertTrue(app.buttons["nextTrip"].waitForExistence(timeout:10))
        app.tabBars.buttons["Usage"].tap()
        XCTAssertTrue(app.staticTexts["safetyUsageTotal"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["safetyUsageTotal"].label.contains("0.035"))
        XCTAssertEqual(app.staticTexts["reservedLookupCount"].label,"1 paid lookup")
        capture("Usage after a flight lookup",app)
        app.swipeUp();XCTAssertTrue(app.staticTexts["Monthly history"].waitForExistence(timeout:5))
        capture("Monthly usage history",app)
        app.tabBars.buttons["Settings"].tap();app.buttons["signOut"].tap()
    }
    func testOverviewDescribesTheWholeTripAndBothIncomingAircraft() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        let trip = app.buttons["nextTrip"]
        XCTAssertTrue(trip.waitForExistence(timeout:10))
        for text in ["HAM to MUC, flight LH2055", "MUC to ZRH, flight LX1107", "All on time"] {
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
    func testRouteLayoutForDirectThreeAndFourFlightTrips() {
        let app = XCUIApplication()
        for count in [1,3,4] {
            app.launchArguments = ["--uitesting", "--uitesting-flight-count=\(count)"]
            app.launch()
            let trip = app.buttons["nextTrip"]
            XCTAssertTrue(trip.waitForExistence(timeout:10))
            switch count {
            case 1:
                XCTAssertTrue(trip.label.contains("HAM to MUC, flight LH2055"))
                XCTAssertTrue(trip.label.contains("Direct flight"))
                XCTAssertFalse(trip.label.contains("LX1107"))
            case 3:
                for segment in ["HAM to MUC, flight LH2055", "MUC to ZRH, flight LX1107", "ZRH to LHR, flight LX318"] {
                    XCTAssertTrue(trip.label.contains(segment))
                }
                XCTAssertTrue(trip.label.contains("3 flights · 2 connections"))
            default:
                XCTAssertTrue(trip.label.contains("HAM to CDG"))
                XCTAssertTrue(trip.label.contains("4 flights · 3 connections"))
                for number in ["LH2055", "LX1107", "LX318", "BA304"] { XCTAssertFalse(trip.label.contains(number)) }
            }
            capture("Overview - \(count) flights",app)
            app.terminate()
        }
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
