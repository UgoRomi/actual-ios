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
        let payeeRow = app.buttons["payee-row"]
        let categoryRow = app.buttons["category-row"]
        XCTAssertTrue(payeeRow.exists && categoryRow.exists)
        XCTAssertTrue(app.buttons["Save"].exists)
        capture("05-transaction-editor")

        // Search for a new payee and add it.
        payeeRow.tap()
        XCTAssertTrue(app.navigationBars["Payee"].waitForExistence(timeout: 10))
        let payeeSearch = app.searchFields.firstMatch
        XCTAssertTrue(payeeSearch.waitForExistence(timeout: 5))
        payeeSearch.tap()
        payeeSearch.typeText("Resume draft")
        let addPayee = app.buttons["Add “Resume draft”"]
        XCTAssertTrue(addPayee.waitForExistence(timeout: 5), "Searching for a new name should offer to add it")
        capture("06-payee-search")
        addPayee.tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(describes(payeeRow, "Resume draft"))

        // Search categories and choose one.
        categoryRow.tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 10))
        let categorySearch = app.searchFields.firstMatch
        categorySearch.tap()
        categorySearch.typeText("Food")
        let food = app.buttons["Food"].firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 5), "Category search should find Food")
        XCTAssertFalse(app.buttons["Restaurants"].exists, "Category search should hide other categories")
        capture("07-category-search")
        food.tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(describes(categoryRow, "Food"))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(describes(payeeRow, "Resume draft") && describes(categoryRow, "Food"),
                      "Foreground handling must preserve an open editor's draft")
    }

    /// Reconciles a demo account to zero: toggle cleared, adjust, lock, then review a locked transaction.
    @MainActor
    func testDemoReconciliation() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        let accountsTab = app.tabBars.buttons["Accounts"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        XCTAssertTrue(accountsTab.waitForExistence(timeout: 60), "The demo budget should open")
        accountsTab.tap()
        let account = app.staticTexts["Capital One Checking"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()
        XCTAssertTrue(app.navigationBars["Capital One Checking"].waitForExistence(timeout: 10))

        app.navigationBars["Capital One Checking"].buttons["Reconcile"].tap()
        let sheet = app.navigationBars["Reconcile"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let balance = app.textFields["Bank balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        let prefilled = balance.value as? String ?? ""
        XCTAssertFalse(prefilled.isEmpty, "The cleared balance should be prefilled")
        balance.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: prefilled.count + 2) + "0")
        capture("08-reconcile-sheet")
        sheet.buttons["Reconcile"].tap()

        let create = app.buttons["Create reconciliation transaction"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), "An unbalanced reconciliation offers an adjustment")
        let unclear = app.buttons["Mark uncleared"].firstMatch
        XCTAssertTrue(unclear.waitForExistence(timeout: 5), "Rows offer a cleared toggle while reconciling")
        unclear.tap()
        let clear = app.buttons["Mark cleared"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.tap()
        XCTAssertTrue(wait(for: create, enabled: true))
        capture("09-reconciling")
        create.tap()

        let lock = app.buttons["Lock transactions"]
        XCTAssertTrue(lock.waitForExistence(timeout: 10), "The adjustment should balance the account")
        XCTAssertTrue(app.staticTexts["All reconciled!"].exists)
        capture("10-reconciled")
        lock.tap()
        let locked = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Reconciled'")).firstMatch
        XCTAssertTrue(locked.waitForExistence(timeout: 10), "Cleared transactions should lock")
        XCTAssertFalse(lock.exists)
        capture("11-locked")

        // A reconciled transaction is editable after a warning.
        app.staticTexts["Reconciliation balance adjustment"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["Reconciled"].exists)
        app.navigationBars["Transaction"].buttons["Save"].tap()
        let confirm = app.buttons["Save changes"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Saving a reconciled transaction warns first")
        capture("12-reconciled-edit")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Capital One Checking"].waitForExistence(timeout: 10))
    }

    /// Transfers from one demo account to another, then deletes the transfer from the other side.
    @MainActor
    func testDemoTransfer() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        let accountsTab = app.tabBars.buttons["Accounts"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        XCTAssertTrue(accountsTab.waitForExistence(timeout: 60), "The demo budget should open")
        accountsTab.tap()
        app.staticTexts["Capital One Checking"].tap()
        let checking = app.navigationBars["Capital One Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        checking.buttons["Add transaction"].tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        let amount = app.textFields["Amount"]
        amount.tap()
        amount.typeText("43" + (Locale.current.decimalSeparator ?? ".") + "21")

        let payeeRow = app.buttons["payee-row"]
        let categoryRow = app.buttons["category-row"]
        payeeRow.tap()
        XCTAssertTrue(app.navigationBars["Payee"].waitForExistence(timeout: 10))
        let savings = app.buttons["Transfer to or from Ally Savings"]
        XCTAssertTrue(savings.waitForExistence(timeout: 5), "Other accounts are offered for transfers")
        XCTAssertFalse(app.buttons["Transfer to or from Capital One Checking"].exists, "An account cannot transfer to itself")
        capture("13-transfer-payee")
        savings.tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(describes(payeeRow, "Transfer to Ally Savings"))
        XCTAssertTrue(describes(categoryRow, "Transfer") && !categoryRow.isEnabled,
                      "Transfers between on-budget accounts have no category")
        capture("14-transfer-editor")
        app.navigationBars["New transaction"].buttons["Save"].tap()
        // The editor shows the same title, so look for the row once it has closed.
        XCTAssertTrue(wait(forAbsence: app.navigationBars["New transaction"]), "The transfer should save")

        // The demo has no transfers, so each title names this test's transaction.
        let sent = app.staticTexts["Transfer to Ally Savings"]
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "The transfer should appear in the sending account")
        capture("15-transfer-register")
        app.navigationBars.buttons["Accounts"].tap()
        app.staticTexts["Ally Savings"].tap()
        XCTAssertTrue(app.navigationBars["Ally Savings"].waitForExistence(timeout: 10))
        let received = app.staticTexts["Transfer from Capital One Checking"]
        XCTAssertTrue(received.waitForExistence(timeout: 10), "The linked transaction should appear in the other account")
        capture("16-transfer-linked")

        received.tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(describes(payeeRow, "Transfer from Capital One Checking"))
        app.buttons["Delete transaction"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["This removes the transfer from both accounts and updates your balances."]
            .waitForExistence(timeout: 5))
        capture("17-transfer-delete")
        // The dialog repeats the form's button label.
        app.sheets["Delete this transaction?"].buttons["Delete transaction"].tap()
        XCTAssertTrue(wait(forAbsence: app.navigationBars["Transaction"]), "Deleting closes the editor")
        XCTAssertTrue(wait(forAbsence: received), "Deleting removes this side")
        app.navigationBars.buttons["Accounts"].tap()
        app.staticTexts["Capital One Checking"].tap()
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(forAbsence: app.staticTexts["Transfer to Ally Savings"]), "Deleting removes the linked side too")
    }

    @MainActor
    private func wait(forAbsence element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    /// A row's label and value, as VoiceOver reads them.
    @MainActor
    private func describes(_ element: XCUIElement, _ text: String) -> Bool {
        element.label.contains(text) || (element.value as? String)?.contains(text) == true
    }

    @MainActor
    private func wait(for element: XCUIElement, enabled: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
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
