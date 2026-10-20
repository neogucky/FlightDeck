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
    private func authenticate(_ app: XCUIApplication, username: String, register: Bool, address: String = "http://localhost:18787") {
        let field = app.textFields["serverAddress"]
        XCTAssertTrue(field.waitForExistence(timeout:10))
        let slashes = CharacterSet(charactersIn:"/")
        // Reuse the saved canonical URL after sign-out instead of tapping into its middle.
        if (field.value as? String)?.trimmingCharacters(in:slashes) != address.trimmingCharacters(in:slashes) {
            fill(field,address,app)
        }
        XCTAssertEqual((field.value as? String)?.trimmingCharacters(in:slashes),address.trimmingCharacters(in:slashes))
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
        let app = XCUIApplication();app.launchArguments = ["--uitesting-start"];app.launch()
        let username = "ui-"+UUID().uuidString.prefix(10).lowercased()
        let address = "http://localhost:18787/flights/"
        authenticate(app,username:username,register:true,address:address)
        XCTAssertTrue(app.secureTextFields["providerAPIKey"].waitForExistence(timeout:10))
        capture("API key setup",app)
        fill(app.secureTextFields["providerAPIKey"],"flightdeck-test-ui-key-"+username,app)
        app.swipeUp()
        app.buttons["saveAPIKey"].tap()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["signedInUsername"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["signedInUsername"].label,username)
        capture("Signed in account",app)
        app.tabBars.buttons["Usage"].tap()
        XCTAssertTrue(app.staticTexts["FlightAware reported"].waitForExistence(timeout:10))
        capture("Account usage",app)
        app.tabBars.buttons["Trips"].tap()
        app.buttons["addFlight"].tap()
        fill(app.textFields["flightNumber0"],"lh 2055",app)
        XCTAssertFalse(app.textFields["origin0"].exists)
        XCTAssertFalse(app.textFields["destination0"].exists)
        capture("Add flight without airport entry",app)
        app.buttons["saveTrip"].tap()
        XCTAssertTrue(app.buttons["nextTrip"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["nextTrip"].label.contains("HAM to MUC, flight LH2055"))
        XCTAssertFalse(app.buttons["nextTrip"].label.contains("LH 2055"))
        app.terminate();app.launchArguments = ["--uitesting-session"];app.launch()
        XCTAssertTrue(app.buttons["nextTrip"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["signedInUsername"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["signedInUsername"].label,username)
        app.buttons["signOut"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout:10))
        authenticate(app,username:username+"-b",register:true,address:address)
        XCTAssertTrue(app.buttons["Set up later"].waitForExistence(timeout:10));app.buttons["Set up later"].tap()
        app.tabBars.buttons["Trips"].tap()
        XCTAssertTrue(app.staticTexts["Where to next?"].waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["nextTrip"].exists)
        app.tabBars.buttons["Settings"].tap();app.buttons["signOut"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout:10))
        authenticate(app,username:username,register:false,address:address)
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["signedInUsername"].waitForExistence(timeout:10))
        XCTAssertFalse(app.secureTextFields["providerAPIKey"].exists)
        app.tabBars.buttons["Trips"].tap();XCTAssertTrue(app.buttons["nextTrip"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap();app.buttons["signOut"].tap()
    }
    func testUsageAfterFlightLookup() {
        let app = XCUIApplication();app.launchArguments = ["--uitesting-start"];app.launch()
        let username = "usage-"+UUID().uuidString.prefix(8).lowercased()
        authenticate(app,username:username,register:true)
        XCTAssertTrue(app.secureTextFields["providerAPIKey"].waitForExistence(timeout:10))
        fill(app.secureTextFields["providerAPIKey"],"flightdeck-test-usage-key-"+username,app)
        app.swipeUp();app.buttons["saveAPIKey"].tap()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
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
    func testStartPageRequiresExplicitDemoChoice() {
        let app = XCUIApplication();app.launchArguments = ["--uitesting-start"];app.launch()
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout:10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["nextTrip"].exists)
        capture("Connect to your server",app)
        app.buttons["exploreDemo"].tap()
        XCTAssertTrue(app.buttons["nextTrip"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["leaveDemo"].tap()
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout:10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        app.terminate();app.launch()
        XCTAssertTrue(app.buttons["connectServer"].waitForExistence(timeout:10))
    }
    func testServerURLFieldIsEmptyEditableAndUsesURLKeyboard() {
        let app = XCUIApplication();app.launchArguments = ["--uitesting-start"];app.launch()
        let field = app.textFields["serverAddress"]
        XCTAssertTrue(field.waitForExistence(timeout:10))
        XCTAssertEqual(field.placeholderValue,"Server URL")
        XCTAssertTrue(["", "Server URL"].contains(field.value as? String ?? ""))
        XCTAssertFalse(app.buttons["connectServer"].isEnabled)
        capture("Empty server URL field",app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5))
        let address = "https://192.0.2.10:8080/flights"
        field.typeText(address)
        XCTAssertEqual(field.value as? String,address)
        XCTAssertTrue(app.buttons["connectServer"].isEnabled)
        capture("Editable server URL with URL keyboard",app)
        field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:address.count))
        XCTAssertTrue(["", "Server URL"].contains(field.value as? String ?? ""))
        XCTAssertFalse(app.buttons["connectServer"].isEnabled)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        app.terminate();app.launch()
        XCTAssertTrue(field.waitForExistence(timeout:10))
        XCTAssertTrue(["", "Server URL"].contains(field.value as? String ?? ""))
    }
    func testCalendarSuggestionsDismissalImportAndManualSearchPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting","--uitesting-calendar","--uitesting-calendar-reset","--uitesting-calendar-loading"];app.launch()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
        let settings = app.buttons["calendarImportSettings"]
        for _ in 0..<3 where !settings.isHittable { app.swipeUp() }
        settings.tap()
        XCTAssertTrue(app.switches["calendar-fixture"].waitForExistence(timeout:10))
        app.switches["calendar-fixture"].tap()
        app.switches["automaticCalendarSuggestions"].tap()
        capture("Calendar import settings",app)
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Trips"].tap()
        XCTAssertTrue(app.buttons["reviewCalendarSuggestions"].waitForExistence(timeout:10))
        capture("Calendar flight suggestions banner",app)
        app.buttons["reviewCalendarSuggestions"].tap()
        XCTAssertTrue(app.staticTexts["2 CONNECTED FLIGHTS"].waitForExistence(timeout:5))
        capture("Review calendar connections",app)
        XCTAssertFalse(app.buttons["dismissCalendar-LH2055"].exists)
        let declined = app.buttons["dismissJourney-LH1189"]
        for _ in 0..<4 where !declined.isHittable { app.swipeUp() }
        XCTAssertTrue(declined.isHittable);declined.tap()
        let add = app.buttons["addCalendarJourney-LH2055"]
        for _ in 0..<4 where !add.isHittable { app.swipeDown() }
        add.tap()
        XCTAssertTrue(add.label.contains("Adding trip"))
        XCTAssertFalse(add.isEnabled)
        XCTAssertFalse(app.buttons["dismissJourney-LH2055"].isEnabled)
        capture("Calendar import in progress",app)
        XCTAssertTrue(add.waitForNonExistence(timeout:10))
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["reviewCalendarSuggestions"].waitForNonExistence(timeout:10))
        app.terminate()
        app.launchArguments = ["--uitesting-preserve","--uitesting-calendar"];app.launch()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
        for _ in 0..<3 where !app.buttons["calendarImportSettings"].isHittable { app.swipeUp() }
        app.buttons["calendarImportSettings"].tap()
        XCTAssertTrue(app.buttons["searchCalendarFlights"].waitForExistence(timeout:5))
        app.buttons["searchCalendarFlights"].tap()
        XCTAssertTrue(app.staticTexts["noCalendarFlightSuggestions"].waitForExistence(timeout:10))
        capture("Calendar scan excludes imported and dismissed flights",app)
        app.buttons["Done"].tap()
        let reset = app.buttons["resetDismissedCalendarFlights"]
        for _ in 0..<4 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        let search = app.buttons["searchCalendarFlights"]
        for _ in 0..<4 where !search.isHittable { app.swipeDown() }
        search.tap()
        XCTAssertTrue(app.staticTexts["LH1189"].waitForExistence(timeout:10))
        XCTAssertFalse(app.staticTexts["LH2055"].exists)
        app.buttons["dismissJourney-LH1189"].tap()
        app.buttons["Done"].tap()
    }
    func testCalendarBulkImportShowsProgressAndDisablesActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting","--uitesting-calendar","--uitesting-calendar-reset","--uitesting-calendar-loading"];app.launch()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        app.tabBars.buttons["Settings"].tap()
        let settings = app.buttons["calendarImportSettings"]
        for _ in 0..<3 where !settings.isHittable { app.swipeUp() }
        settings.tap()
        XCTAssertTrue(app.switches["calendar-fixture"].waitForExistence(timeout:10))
        app.switches["calendar-fixture"].tap()
        app.buttons["searchCalendarFlights"].tap()
        let add = app.buttons["addAllCalendarFlights"]
        XCTAssertTrue(add.waitForExistence(timeout:10))
        add.tap()
        XCTAssertTrue(add.label.contains("Adding flights"))
        XCTAssertFalse(add.isEnabled)
        XCTAssertFalse(app.buttons["dismissJourney-LH2055"].isEnabled)
        capture("Bulk calendar import in progress",app)
        XCTAssertTrue(add.waitForNonExistence(timeout:10))
        app.buttons["searchCalendarFlights"].tap()
        XCTAssertTrue(app.staticTexts["noCalendarFlightSuggestions"].waitForExistence(timeout:10))
        app.buttons["Done"].tap()
    }
    func testPublishedScheduleShowsRouteWithoutClaimingLiveStatus() {
        let app = XCUIApplication();app.launchArguments = ["--uitesting-start"];app.launch()
        let username = "schedule-"+UUID().uuidString.prefix(8).lowercased()
        authenticate(app,username:username,register:true)
        XCTAssertTrue(app.secureTextFields["providerAPIKey"].waitForExistence(timeout:10))
        fill(app.secureTextFields["providerAPIKey"],"flightdeck-test-schedule-key-"+username,app)
        app.swipeUp();app.buttons["saveAPIKey"].tap()
        XCTAssertTrue(app.buttons["addFlight"].waitForExistence(timeout:10))
        app.buttons["addFlight"].tap();fill(app.textFields["flightNumber0"],"LX 1052",app)
        app.buttons["saveTrip"].tap()
        let trip = app.buttons["nextTrip"]
        XCTAssertTrue(trip.waitForExistence(timeout:10))
        XCTAssertTrue(trip.label.contains("ZRH to HAM, flight LX1052"))
        XCTAssertTrue(trip.label.contains("Schedule only"))
        XCTAssertFalse(trip.label.contains("On time"))
        XCTAssertTrue(app.buttons["incoming-LX1052"].label.contains("Available closer to departure"))
        capture("Published schedule overview",app)
        trip.tap()
        XCTAssertTrue(app.staticTexts["PLANNED AIRCRAFT TYPE"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Airbus A220-300"].exists)
        capture("Published schedule details",app)
        app.navigationBars.buttons.firstMatch.tap()
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
        fill(app.textFields["flightNumber0"],"LH 2061",app)
        XCTAssertFalse(app.textFields["origin0"].exists)
        XCTAssertFalse(app.textFields["destination0"].exists)
        app.swipeUp()
        app.buttons["addConnection"].tap()
        app.swipeUp()
        let second = app.textFields["flightNumber1"]
        fill(second,"LX 1111",app)
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
        app.buttons["leaveDemo"].tap()
        XCTAssertTrue(app.textFields["serverAddress"].waitForExistence(timeout:5))
        capture("Settings",app)
    }
}
