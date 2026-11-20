import XCTest

/// Drives the example checkout with real touches so a full session reaches
/// the local ReplayIQ stack. Run against `./dev.sh up`; the session id is
/// printed as `RIQ_SESSION=<id>` and attached to the test result.
final class CheckoutFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCheckoutSession() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RIQ_KEY"] = "verify"
        app.launchEnvironment["RIQ_MODE"] = ProcessInfo.processInfo.environment["RIQ_MODE"] ?? "auto"
        app.launch()

        // A screen that is mostly a map (auto mode records it as screenshots),
        // then scrolling on the shop list.
        tapWhenReady(app.buttons["Store map"])
        sleep(2)
        app.swipeLeft()
        sleep(2)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        app.swipeDown()
        sleep(1)

        // Shop: add two products.
        tapWhenReady(app.buttons["Add Trail Runner Shoes"])
        app.buttons["Add Merino Hoodie"].tap()
        app.buttons["Cart (2)"].tap()
        app.buttons["Checkout"].tap()

        // SwiftUI checkout: every field is masked on the device.
        type(app.textFields["Full name"], "Jane Appleseed", in: app)
        type(app.textFields["Email"], "jane@example.com", in: app)
        type(app.secureTextFields["Account password"], "hunter22", in: app)
        type(app.textFields["Card number"], "4242424242424242", in: app)
        dismissKeyboard(app)

        let coupon = app.buttons["Apply coupon"]
        coupon.tap(withNumberOfTaps: 3, numberOfTouches: 1) // rage click
        coupon.tap(withNumberOfTaps: 2, numberOfTouches: 1)
        app.buttons["Pay now"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Pay'")).firstMatch.waitForExistence(timeout: 10))
        sleep(2)

        // Back to the shop, then the UIKit checkout.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        dismissSavePassword(app)
        tapWhenReady(app.buttons["UIKit checkout"])
        type(app.textFields["Email"], "jane@example.com", in: app)
        type(app.secureTextFields["Password"], "secret", in: app)
        dismissKeyboard(app)
        tapWhenReady(app.buttons["Place order"])
        XCTAssertTrue(app.buttons["UIKit checkout"].waitForExistence(timeout: 5))

        // Debug tools: console lines, a URLSession.shared request, session id.
        sleep(2) // sheet dismissal
        dismissSavePassword(app)
        tapWhenReady(app.buttons["Debug tools"])
        tapWhenReady(app.buttons["Log info"])
        app.buttons["Log warning"].tap()
        app.buttons["Log error"].tap()
        app.buttons["Fetch via URLSession.shared"].tap()
        let sid = app.staticTexts["sessionId"]
        var n = 0
        while !sid.exists && n < 5 { app.swipeUp(); n += 1 }
        XCTAssertTrue(sid.waitForExistence(timeout: 5))
        let id = sid.label
        print("RIQ_SESSION=\(id)")
        let attachment = XCTAttachment(string: id)
        attachment.name = "session_id"
        attachment.lifetime = .keepAlways
        add(attachment)

        sleep(3)
        // Background flushes the buffer; foreground resumes the same session.
        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        sleep(3)
        forceTap(app.buttons["Flush now"])

        // A crash, reported to the same session on the next launch.
        sleep(6) // let the 5 s flush send the events before the crash
        forceTap(app.buttons["Throw NSException"])
        sleep(2)
        app.launch()
        sleep(8)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The same scripted minute in any mode (RIQ_MODE), for measurements:
    /// prints RIQ_SESSION and RIQ_DIAG (the SDK's diagnostics) at the end.
    func testMeasureMinute() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RIQ_KEY"] = "verify"
        app.launchEnvironment["RIQ_MODE"] = ProcessInfo.processInfo.environment["RIQ_MODE"] ?? "auto"
        app.launch()
        tapWhenReady(app.buttons["Debug tools"])
        tapWhenReady(app.buttons["Reset diagnostics"])
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let start = Date()
        var round = 0
        while Date().timeIntervalSince(start) < 60 {
            round += 1
            tapWhenReady(app.buttons["Add Trail Runner Shoes"])
            app.buttons["Add Insulated Bottle"].tap()
            tapWhenReady(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Cart ('")).firstMatch)
            tapWhenReady(app.buttons["Checkout"])
            type(app.textFields["Full name"], "Jane \(round)", in: app)
            type(app.textFields["Card number"], "4242", in: app)
            dismissKeyboard(app)
            app.buttons["Apply coupon"].tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.swipeUp()
            app.swipeDown()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.swipeUp()
            sleep(1)
            app.swipeDown()
            tapWhenReady(app.buttons["UIKit checkout"])
            type(app.textFields["Email"], "jane@example.com", in: app)
            dismissKeyboard(app)
            tapWhenReady(app.navigationBars["UIKit Checkout"].buttons.element(boundBy: 0))
            sleep(1)
        }
        tapWhenReady(app.buttons["Debug tools"])
        tapWhenReady(app.buttons["Refresh diagnostics"])
        let diag = app.staticTexts["diagnostics"]
        XCTAssertTrue(diag.waitForExistence(timeout: 5))
        print("RIQ_ROUNDS=\(round)")
        print("RIQ_DIAG=\(diag.label)")
        swipeToSession(app)
    }

    private func swipeToSession(_ app: XCUIApplication) {
        let sid = app.staticTexts["sessionId"]
        var n = 0
        while !sid.exists && n < 4 { app.swipeUp(); n += 1 }
        if sid.exists { print("RIQ_SESSION=\(sid.label)") }
    }

    /// Taps by coordinate: after returning from the background XCTest can
    /// report list rows as not hittable while they are on screen.
    private func forceTap(_ el: XCUIElement) {
        XCTAssertTrue(el.waitForExistence(timeout: 5))
        el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// iOS offers to save the typed password after a form with a secure field.
    private func dismissSavePassword(_ app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
    }

    /// Taps an element, scrolling the list until it exists and is hittable
    /// (SwiftUI lists don't create off-screen rows).
    private func tapWhenReady(_ el: XCUIElement) {
        if !el.waitForExistence(timeout: 3) {
            var n = 0
            while !el.exists && n < 5 { XCUIApplication().swipeUp(); n += 1 }
        }
        XCTAssertTrue(el.waitForExistence(timeout: 5), "missing \(el)")
        var tries = 0
        while !el.isHittable && tries < 4 {
            XCUIApplication().swipeUp()
            sleep(1)
            tries += 1
        }
        el.tap()
    }

    private func type(_ field: XCUIElement, _ text: String, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "missing \(field)")
        field.tap()
        field.typeText(text)
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        if app.keyboards.count > 0 {
            if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
            else if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
        }
        app.navigationBars.firstMatch.tap()
    }
}
