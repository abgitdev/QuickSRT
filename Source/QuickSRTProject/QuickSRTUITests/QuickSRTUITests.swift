import XCTest

@MainActor
final class QuickSRTUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchExposesPrimaryWorkflowAndDataLifecycleCommands() throws {
        let app = launchApp()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["queue.addVideo"].exists)
        XCTAssertTrue(app.buttons["queue.start"].exists)
        XCTAssertTrue(
            app.buttons["model.download"].exists || app.buttons["model.update"].exists,
            "The model card must expose either the clean-download or update action."
        )

        let appMenu = app.menuBars.menuBarItems["QuickSRT"]
        XCTAssertTrue(appMenu.exists)
        appMenu.click()
        XCTAssertTrue(app.menuItems["Delete QuickSRT Data…"].exists)
        XCTAssertTrue(app.menuItems["Uninstall QuickSRT…"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    func testApplicationShutdownTerminatesTheLaunchedInstance() {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.terminate()

        XCTAssertEqual(app.state, .notRunning)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-QuickSRT.appLanguage", "en",
        ]
        app.launch()
        return app
    }
}
