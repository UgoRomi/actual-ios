import XCTest

final class ActualNativeUITests: XCTestCase {
    @MainActor
    func testDemoBudgetNavigationAndTransactionEditor() {
        let app = XCUIApplication()
        app.launch()

        let demoButton = app.buttons["Explore a demo budget"]
        XCTAssertTrue(demoButton.waitForExistence(timeout: 30), "The welcome screen should offer a disposable demo budget")
        capture("01-welcome")
        demoButton.tap()

        let budgetTab = app.tabBars.buttons["Budget"]
        XCTAssertTrue(budgetTab.waitForExistence(timeout: 60), "The demo budget should open")
        XCTAssertTrue(app.staticTexts["Available to budget"].exists, "The native budget summary should load")
        capture("02-budget")

        let accountsTab = app.tabBars.buttons["Accounts"]
        XCTAssertTrue(accountsTab.exists)
        accountsTab.tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["On budget"].exists, "The demo should show its accounts")
        capture("03-accounts")

        let transactionsTab = app.tabBars.buttons["Transactions"]
        XCTAssertTrue(transactionsTab.exists)
        transactionsTab.tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        let addTransaction = app.buttons["Add transaction"]
        XCTAssertTrue(addTransaction.exists, "A demo transaction should be addable")
        capture("04-transactions")

        addTransaction.tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Amount"].exists)
        XCTAssertTrue(app.textFields["Payee"].exists)
        XCTAssertTrue(app.buttons["Save"].exists)
        capture("05-transaction-editor")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
