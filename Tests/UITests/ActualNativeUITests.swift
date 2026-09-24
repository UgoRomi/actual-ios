import XCTest

final class ActualNativeUITests: XCTestCase {
    /// Opt-in: a disposable linked-account fixture with no server credentials.
    @MainActor
    func testBankRefreshRequiresConnection() throws {
        let app = XCUIApplication()
        app.launch()
        let fixture = app.buttons["Bank Sync Regression"]
        if fixture.waitForExistence(timeout: 10) {
            fixture.tap()
        } else if !app.staticTexts["Bank Sync Regression"].exists {
            throw XCTSkip("Requires the disposable bank-sync fixture; see docs/validation.md")
        }
        let accounts = app.tabBars.buttons["Accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 60))
        accounts.tap()
        let checking = app.staticTexts["bank-checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        pullToRefresh(app)
        let error = app.staticTexts["Connect to your Actual server in Settings before refreshing bank accounts."]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(checking.exists, "Refresh errors must preserve account balances and navigation")
        capture("bank-sync-accounts-error")
        checking.tap()
        XCTAssertTrue(app.navigationBars["bank-checking"].waitForExistence(timeout: 10))
        pullToRefresh(app)
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertTrue(app.buttons["Add transaction"].isEnabled)
        capture("bank-sync-account-error")
    }

    /// Opt-in: install a disposable local budget named "Large Budget Regression" first.
    @MainActor
    func testLargeBudgetTransactionsStayResponsive() throws {
        let app = XCUIApplication()
        app.launch()
        let fixture = app.buttons["Large Budget Regression"]
        if fixture.waitForExistence(timeout: 10) {
            fixture.tap()
        } else if !app.staticTexts["Large Budget Regression"].exists {
            throw XCTSkip("Requires the disposable large-budget fixture; see docs/validation.md")
        }
        let transactions = app.tabBars.buttons["Transactions"]
        XCTAssertTrue(transactions.waitForExistence(timeout: 60))
        transactions.tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        app.swipeUp()
        app.swipeDown()
        let add = app.buttons["Add transaction"]
        add.tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()

        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap()
        search.typeText("no-match-unique-search-token")
        XCTAssertTrue(app.staticTexts["No matching transactions"].waitForExistence(timeout: 10))
        search.buttons["Clear text"].tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No matching transactions"].exists)
    }

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
        pullToRefresh(app)
        XCTAssertFalse(app.staticTexts["Something needs attention"].exists, "Unlinked accounts should refresh locally")
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
        let payee = app.textFields["Payee"]
        payee.tap()
        payee.typeText("Resume draft")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        XCTAssertEqual(payee.value as? String, "Resume draft", "Foreground handling must preserve an open editor's draft")
    }

    @MainActor
    private func pullToRefresh(_ app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
