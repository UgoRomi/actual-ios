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

    /// Opt-in: install a disposable local budget named "Delete Budget Regression" first.
    /// Deletes it from this device.
    @MainActor
    func testDeleteLocalBudget() throws {
        let app = XCUIApplication()
        app.launch()
        let fixture = app.buttons["Delete Budget Regression"]
        guard fixture.waitForExistence(timeout: 10) else {
            throw XCTSkip("Requires the disposable delete-budget fixture; see docs/validation.md")
        }
        XCTAssertTrue(app.staticTexts["Touch and hold a budget to delete it from this device."].exists)
        let delete = app.buttons["Delete from This Device"]
        let message = app.staticTexts["This budget is not on a server. Deleting it removes it permanently."]

        fixture.press(forDuration: 1)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        capture("16-delete-budget-menu")
        delete.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        // As a popover, the dialog has no Cancel button; tapping outside dismisses it.
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertTrue(fixture.exists, "Cancelling must keep the budget")

        fixture.press(forDuration: 1)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        capture("17-delete-budget-confirmation")
        delete.firstMatch.tap()
        XCTAssertTrue(fixture.waitForNonExistence(timeout: 10), "The deleted budget must leave the list")
        XCTAssertFalse(app.staticTexts["Something needs attention"].exists)
        XCTAssertTrue(app.buttons["Explore a demo budget"].exists)
        capture("18-budget-deleted")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Explore a demo budget"].waitForExistence(timeout: 30))
        XCTAssertFalse(fixture.exists, "The deleted budget must stay deleted after relaunch")
    }

    /// Opt-in: signs in to a disposable OpenID server; run `scripts/test-openid.sh --simulator`.
    @MainActor
    func testOpenIDSignIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["ACTUAL_OPENID_TEST_SERVER"],
              let password = environment["ACTUAL_OPENID_TEST_PASSWORD"] else {
            throw XCTSkip("Requires a disposable OpenID server; see docs/validation.md")
        }
        let app = XCUIApplication()
        app.launch()
        let connect = app.buttons["Connect to your server"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30), "Start from a fresh simulator")
        connect.tap()
        let address = app.textFields["Server address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(server)
        app.buttons["Continue"].tap()

        let openID = app.buttons["Sign in with OpenID"]
        XCTAssertTrue(openID.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Sign in with password"].exists)
        XCTAssertFalse(openID.isEnabled, "The first OpenID sign-in confirms the server password")
        let field = app.secureTextFields["Server password"]
        field.tap()
        field.typeText(password)
        capture("13-openid-sign-in")
        openID.tap()

        // iOS asks before the app opens the provider's page, which approves at once.
        // Its last button continues, whatever the simulator's language.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alerts = [app.alerts.firstMatch, springboard.alerts.firstMatch]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !alerts.contains(where: \.exists) { Thread.sleep(forTimeInterval: 0.25) }
        if let alert = alerts.first(where: \.exists) {
            capture("14-openid-consent")
            alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
        }

        let budget = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Native Sync Fixture'")).firstMatch
        XCTAssertTrue(budget.waitForExistence(timeout: 60), "OpenID sign-in should list the server's budgets")
        XCTAssertFalse(app.staticTexts["Something needs attention"].exists)
        XCTAssertTrue(openID.isEnabled, "Once an owner exists, OpenID sign-in needs no server password")
        capture("15-openid-connected")
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

        // Budget a calculation with the keypad, which opens with the editor.
        let foodBudget = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Food'")).firstMatch
        foodBudget.tap()
        XCTAssertTrue(app.navigationBars["Food"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5), "The calculator keypad should open with the editor")
        app.buttons["Clear"].tap()
        tapKeys(app, "120+30")
        let budgeted = app.textFields["Budgeted amount"]
        XCTAssertEqual(budgeted.value as? String, "120+30")
        capture("budget-calculator")
        tapKeys(app, "=")
        XCTAssertEqual(budgeted.value as? String, "150\(decimalSeparator)00", "= shows the calculation's result")
        app.navigationBars["Food"].buttons["Save"].tap()
        XCTAssertTrue(wait(forAbsence: app.navigationBars["Food"]), "The calculated amount should save")
        XCTAssertTrue(describes(foodBudget, "150\(decimalSeparator)00"))

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
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5), "A new transaction should open the calculator keypad")
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

    /// Adds a fixed monthly target to a demo category, saves it, and applies it to the month.
    @MainActor
    func testDemoTargets() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 60), "The demo budget should open")
        app.tabBars.buttons["Budget"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Food")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let targets = app.buttons["Add Targets"]
        XCTAssertTrue(targets.waitForExistence(timeout: 10), "The budget editor should offer targets")
        targets.tap()
        XCTAssertTrue(app.navigationBars["Targets"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Projected for")).firstMatch
            .waitForExistence(timeout: 10))

        app.buttons["Add Automation"].tap()
        XCTAssertTrue(app.navigationBars["Fixed amount"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Amount"].exists)
        capture("targets-fixed-amount")
        app.navigationBars["Fixed amount"].buttons.firstMatch.tap()
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Budget ")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "The list should summarize the target")
        let save = app.navigationBars["Targets"].buttons["Save"]
        XCTAssertTrue(wait(for: save, enabled: true),"A valid target should be savable once previewed")
        capture("targets-list")
        save.tap()

        let apply = app.buttons["Apply Target"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10), "A category with targets can apply them")
        apply.tap()
        // The demo's spending is random. As in Actual, overspending shows before target funding.
        let funded = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@ AND (label CONTAINS %@ OR label CONTAINS %@)",
            "Food", "Budgeted 100", "funded", "Overspent")).firstMatch
        XCTAssertTrue(funded.waitForExistence(timeout: 10), "The budget row should show the applied target")
        capture("targets-budget")
    }

    /// Runs a month action, moves money from the budget summary, and opens a category's budget and balance actions.
    @MainActor
    func testDemoBudgetActions() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 60), "The demo budget should open")
        app.tabBars.buttons["Budget"].tap()
        capture("budget-actions-banners")

        let menu = app.buttons["Month actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.buttons["Copy Last Month’s Budget"].waitForExistence(timeout: 5))
        capture("budget-actions-month-menu")
        app.buttons["Set Budgets to Zero"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Set Budgets to Zero")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Month actions should ask for confirmation")
        confirm.tap()
        let zero = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", "Food", "Budgeted 0")).firstMatch
        XCTAssertTrue(zero.waitForExistence(timeout: 10), "Every category should be set to zero")

        // With nothing budgeted, To Budget has money to move.
        let summary = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Available to budget")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        summary.tap()
        XCTAssertTrue(app.navigationBars["Budget Summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Available funds"].exists)
        capture("budget-actions-summary")
        app.buttons["Move to a Category"].tap()
        XCTAssertTrue(app.navigationBars["Move to a Category"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Transfer this amount"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5), "The amount should open the keypad")
        app.buttons["Clear"].tap()
        tapKeys(app, "25=")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Food")).firstMatch.tap()
        capture("budget-actions-move")
        app.navigationBars["Move to a Category"].buttons["Transfer"].tap()
        XCTAssertTrue(app.navigationBars["Budget Summary"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        let moved = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", "Food", "Budgeted 25\(decimalSeparator)00")).firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 10), "The category should receive the money")

        moved.tap()
        XCTAssertTrue(app.buttons["Copy Last Month’s Budget"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(app.switches["Rollover Overspending"].waitForExistence(timeout: 5))
        capture("budget-actions-category")
    }

    /// Adds a category group and a category, hides and reveals it, and adds and closes an account.
    @MainActor
    func testDemoManagement() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 60), "The demo budget should open")
        app.tabBars.buttons["Budget"].tap()

        // The demo budget stays between runs, so names are unique to this one.
        let suffix = String(Int(Date().timeIntervalSince1970) % 100_000)
        let group = "UI Group \(suffix)", category = "UI Category \(suffix)", wallet = "UI Wallet \(suffix)"
        func name(_ text: String) {
            let field = app.textFields["Name"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(text)
        }
        app.buttons["Month actions"].tap()
        app.buttons["Add Category Group"].tap()
        name(group)
        app.buttons["Add"].tap()
        let options = app.buttons["\(group) group options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10), "The new group should show")
        scroll(app, to: options)
        options.tap()
        XCTAssertTrue(app.navigationBars[group].waitForExistence(timeout: 10))
        app.buttons["Add Category"].tap()
        name(category)
        app.buttons["Add"].tap()
        capture("manage-group")
        app.buttons["Done"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", category)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The new category should show")
        scroll(app, to: row)
        row.tap()
        let edit = app.buttons["Edit Category"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        app.swipeUp()
        edit.tap()
        let hidden = app.switches["Hidden"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 10))
        capture("manage-category")
        hidden.switches.firstMatch.tap()
        XCTAssertTrue(wait(for: hidden, value: "1"), "The category should be hidden")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Cancel"].tap()
        func toggleHidden() {
            app.buttons["Month actions"].tap()
            app.buttons["Show Hidden Categories"].tap()
        }
        // The choice is remembered, so an earlier run may have left hidden categories showing.
        if !wait(forAbsence: row) { toggleHidden() }
        XCTAssertTrue(wait(forAbsence: row), "A hidden category should leave the budget")
        toggleHidden()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Hidden categories should show on request")
        toggleHidden()

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Add account"].tap()
        name(wallet)
        app.buttons["Add"].tap()
        let walletRow = app.staticTexts[wallet]
        XCTAssertTrue(walletRow.waitForExistence(timeout: 10), "The new account should show")
        scroll(app, to: walletRow)
        walletRow.tap()
        app.buttons["Account options"].tap()
        app.buttons["Close Account"].tap()
        XCTAssertTrue(app.staticTexts["This account has no transactions, so it will be permanently deleted."]
            .waitForExistence(timeout: 10))
        capture("manage-close-account")
        app.navigationBars["Close Account"].buttons["Close Account"].tap()
        XCTAssertTrue(wait(forAbsence: walletRow), "An account without transactions is deleted")
    }

    /// Adds a transaction split between two parts, then reopens it to see its parts.
    @MainActor
    func testDemoSplitTransaction() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        let transactions = app.tabBars.buttons["Transactions"]
        XCTAssertTrue(transactions.waitForExistence(timeout: 60), "The demo budget should open")
        transactions.tap()
        app.buttons["Add transaction"].tap()
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 10))
        app.buttons["Clear"].tap()
        tapKeys(app, "30=")
        let payee = "Split UI \(Int(Date().timeIntervalSince1970) % 100_000)"
        app.buttons["payee-row"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText(payee)
        app.buttons["Add “\(payee)”"].tap()

        app.swipeUp()
        app.buttons["Split Transaction"].tap()
        let parts = app.textFields.matching(identifier: "Split amount")
        XCTAssertTrue(parts.element(boundBy: 1).waitForExistence(timeout: 5), "Splitting should add two parts")
        parts.element(boundBy: 0).tap()
        app.buttons["Clear"].tap()
        tapKeys(app, "20=")
        let left = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Amount left")).firstMatch
        scroll(app, to: left)
        XCTAssertTrue(left
            .waitForExistence(timeout: 5), "An unbalanced split shows what is left")
        parts.element(boundBy: 1).tap()
        app.buttons["Clear"].tap()
        tapKeys(app, "10=")
        let category = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Category")).firstMatch
        category.tap()
        let food = app.buttons["Food"].firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 5))
        food.tap()
        let balanced = app.staticTexts["The parts add up to the total."]
        scroll(app, to: balanced)
        XCTAssertTrue(balanced.waitForExistence(timeout: 5))
        capture("split-editor")
        app.navigationBars["New transaction"].buttons["Save"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
                                                   payee, "Split · 2 parts")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The register should show the split")
        row.tap()
        let secondPart = app.staticTexts["Split 2"]
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 10))
        scroll(app, to: secondPart)
        XCTAssertTrue(secondPart.exists, "Reopening shows the parts")
        capture("split-reopened")
    }

    /// Adds a repeating schedule, sees it listed with its status, and deletes it.
    @MainActor
    func testDemoSchedules() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        let tab = app.tabBars.buttons["Schedules"]
        XCTAssertTrue(tab.waitForExistence(timeout: 60), "The demo budget should open")
        tab.tap()
        app.buttons["Add schedule"].tap()
        XCTAssertTrue(app.navigationBars["New Schedule"].waitForExistence(timeout: 10))
        let name = "UI Rent \(Int(Date().timeIntervalSince1970) % 100_000)"
        let field = app.textFields["Name"]
        field.tap()
        field.typeText(name)
        let amount = app.textFields["Amount"]
        amount.tap()
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5))
        app.buttons["Clear"].tap()
        tapKeys(app, "50=")
        let nextDates = app.staticTexts["Next dates"]
        scroll(app, to: nextDates)
        XCTAssertTrue(nextDates.waitForExistence(timeout: 10), "A repeating schedule previews its dates")
        capture("schedule-editor")
        app.navigationBars["New Schedule"].buttons["Save"].tap()

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The new schedule should be listed")
        XCTAssertTrue(row.label.contains("Due"), "Starting today, it is due: \(row.label)")
        capture("schedules-list")
        row.tap()
        let delete = app.buttons["Delete Schedule"]
        scroll(app, to: delete)
        let formButton = delete.frame
        delete.tap()
        // The confirmation's button, not the form's.
        let confirmations = app.buttons.matching(NSPredicate(format: "label == %@", "Delete Schedule"))
        XCTAssertTrue(confirmations.element(boundBy: 1).waitForExistence(timeout: 5))
        confirmations.allElementsBoundByIndex.first { $0.frame != formButton && $0.isHittable }?.tap()
        XCTAssertTrue(wait(forAbsence: row), "The deleted schedule should leave the list")
    }

    /// Opens the demo's default dashboard and each kind of report on it.
    @MainActor
    func testDemoReports() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        let reportsTab = app.tabBars.buttons["Reports"]
        XCTAssertTrue(reportsTab.waitForExistence(timeout: 60), "The demo budget should open")
        reportsTab.tap()
        func card(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }
        XCTAssertTrue(card("Total Income (YTD)").waitForExistence(timeout: 30), "The default dashboard should load")
        XCTAssertTrue(app.staticTexts["Net Worth"].waitForExistence(timeout: 30))
        capture("reports-dashboard")

        /// Rows show as one element with their value, so match the beginning of any label.
        func shows(_ label: String) -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
                .waitForExistence(timeout: 20)
        }
        func open(_ title: String, _ check: () -> Void = {}) {
            let button = card(title)
            XCTAssertTrue(button.waitForExistence(timeout: 20), "\(title) should be on the dashboard")
            button.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            check()
            capture("reports-" + title.lowercased().replacingOccurrences(of: " ", with: "-"))
            app.navigationBars[title].buttons.firstMatch.tap()
        }
        // In dashboard order, so each card is reached by scrolling down.
        open("Avg Per Month") {
            XCTAssertTrue(shows("Months"), "Averages show how they divide")
        }
        open("Net Worth") {
            XCTAssertTrue(app.buttons["Monthly"].waitForExistence(timeout: 20))
            app.buttons["Saved range"].tap()
            app.buttons["1 year"].tap()
            XCTAssertTrue(app.buttons["1 year"].waitForExistence(timeout: 10), "The chosen range should show")
        }
        open("Cash Flow") {
            XCTAssertTrue(shows("Income"))
            XCTAssertTrue(app.switches["Show balance"].exists)
        }
        open("This Month") {
            XCTAssertTrue(app.buttons["Average"].waitForExistence(timeout: 20))
            app.buttons["Budgeted"].tap()
            XCTAssertTrue(shows("Budgeted to date"))
        }
        open("Transaction Calendar") {
            let day = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "spending")).firstMatch
            XCTAssertTrue(day.waitForExistence(timeout: 20), "Days with transactions can be chosen")
            day.tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "·")).firstMatch
                .waitForExistence(timeout: 10), "The day's transactions should list")
        }
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Dashboard Tips"].waitForExistence(timeout: 10), "Text widgets show their Markdown")
        capture("reports-text")
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
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5), "The calculator keypad should open with the sheet")
        app.buttons["Clear"].tap()
        tapKeys(app, "0")
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
        let locked = app.buttons["Unlock reconciled transaction"].firstMatch
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
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5), "The amount should be focused")
        tapKeys(app, "40+3\(decimalSeparator)21")
        XCTAssertEqual(amount.value as? String, "40+3\(decimalSeparator)21")
        capture("transfer-calculator")
        tapKeys(app, "=")
        XCTAssertEqual(amount.value as? String, "43\(decimalSeparator)21", "= shows the calculation's result")

        // Choosing another date closes the calendar.
        app.datePickers.firstMatch.tap()
        let nextMonth = app.buttons["DatePicker.NextMonth"]
        XCTAssertTrue(nextMonth.waitForExistence(timeout: 5), "Tapping the date opens a calendar")
        // The month's last other day, so the transfer stays near the top of the register.
        let days = app.datePickers.containing(.button, identifier: "DatePicker.NextMonth").collectionViews.buttons
            .matching(NSPredicate(format: "isSelected == false"))
        days.element(boundBy: days.count - 1).tap()
        XCTAssertTrue(wait(forAbsence: nextMonth), "Choosing a date closes the calendar")

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
        // Each row clears from its checkmark.
        let sentRow = app.cells.containing(.staticText, identifier: "Transfer to Ally Savings").firstMatch
        sentRow.buttons["Mark cleared"].tap()
        XCTAssertTrue(sentRow.buttons["Mark uncleared"].waitForExistence(timeout: 10), "Tapping the checkmark clears the transaction")
        app.navigationBars.buttons["Accounts"].tap()
        app.staticTexts["Ally Savings"].tap()
        XCTAssertTrue(app.navigationBars["Ally Savings"].waitForExistence(timeout: 10))
        let received = app.staticTexts["Transfer from Capital One Checking"]
        XCTAssertTrue(received.waitForExistence(timeout: 10), "The linked transaction should appear in the other account")
        capture("16-transfer-linked")

        received.tap()
        XCTAssertTrue(app.navigationBars["Transaction"].waitForExistence(timeout: 10))
        XCTAssertTrue(describes(payeeRow, "Transfer from Capital One Checking"))
        XCTAssertEqual(app.textFields["Amount"].value as? String, "43\(decimalSeparator)21", "The calculated amount should save")
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

    private var decimalSeparator: String { Locale.current.decimalSeparator ?? "." }

    /// Taps calculator keypad keys, by symbol.
    @MainActor
    private func tapKeys(_ app: XCUIApplication, _ keys: String) {
        let names: [Character: String] = ["+": "Plus", "−": "Minus", "×": "Multiply", "÷": "Divide", "=": "Equals"]
        for key in keys { app.buttons[names[key] ?? String(key)].tap() }
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
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
    }

    @MainActor
    private func wait(for element: XCUIElement, value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
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
