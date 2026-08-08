import XCTest

final class NimculusUITests: XCTestCase {
  func testToolbarSaveIsAddressableByAccessibilityIdentifier() {
    let app = XCUIApplication(bundleIdentifier: "com.asopitech.nimculus")
    app.launch()

    let saveButton = app.buttons["toolbar.save"]
    XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
    saveButton.click()
  }
}
