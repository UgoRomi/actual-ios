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

        // The Overspent quick filter shows only overspent rows, or says there are none.
        // Group headers are buttons too, which open the group's menu.
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Budgeted' AND label CONTAINS 'Balance' AND identifier != 'group-header'"))
        XCTAssertTrue(rows.firstMatch.exists, "Category rows should show budgeted and balance amounts")
        app.buttons["Overspent"].tap()
        XCTAssertTrue(app.buttons["Overspent"].isSelected)
        let none = app.staticTexts["No overspent categories"]
        XCTAssertTrue(none.waitForExistence(timeout: 2) || rows.firstMatch.exists)
        for index in 0..<rows.count { XCTAssertTrue(rows.element(boundBy: index).label.hasSuffix("Overspent")) }
        capture("budget-overspent")
        app.buttons["All"].tap()

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
        // As in Actual's mobile budget, tapping a group opens its menu.
        let options = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(group), ")).firstMatch
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
        // Edit Category is at the end of the budget editor, below the fold.
        let edit = app.buttons["Edit Category"]
        XCTAssertTrue(app.buttons["Copy Last Month’s Budget"].waitForExistence(timeout: 10))
        scroll(app, to: edit)
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
        // Upcoming scheduled transactions come first, so the split may be below the fold.
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 10))
        scroll(app, to: row)
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

    /// Shows upcoming scheduled transactions with their menu, and a category's transactions.
    @MainActor
    func testDemoUpcomingAndCategoryTransactions() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        let transactions = app.tabBars.buttons["Transactions"]
        XCTAssertTrue(transactions.waitForExistence(timeout: 60), "The demo budget should open")
        transactions.tap()
        XCTAssertTrue(app.staticTexts["Upcoming"].waitForExistence(timeout: 10), "The demo's schedules are upcoming")
        let scheduled = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                                         "Missed", "Due", "Upcoming")).firstMatch
        XCTAssertTrue(scheduled.waitForExistence(timeout: 10))
        capture("register-upcoming")
        scheduled.tap()
        XCTAssertTrue(app.buttons["Post Transaction Today"].waitForExistence(timeout: 5), "The scheduled menu offers posting")
        capture("register-upcoming-menu")
        // On iOS 27 the menu is a popover without Cancel; tap outside it.
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if dismissRegion.exists { dismissRegion.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
        XCTAssertTrue(wait(forAbsence: app.buttons["Post Transaction Today"]), "The scheduled menu should close")

        app.tabBars.buttons["Budget"].tap()
        let food = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Food")).firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 10))
        food.tap()
        let link = app.buttons["category-transactions"]
        scroll(app, to: link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Food"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Total"].waitForExistence(timeout: 10), "Food has transactions this month")
        capture("category-transactions")
    }

    /// Opens payees and rules from Settings, checks a rule's validation, and changes the number format.
    @MainActor
    func testDemoPayeesRulesAndFormatting() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 60), "The demo budget should open")
        app.tabBars.buttons["Budget"].tap()
        app.buttons["Settings"].firstMatch.tap()

        app.buttons["Payees"].tap()
        XCTAssertTrue(app.navigationBars["Payees"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells.element(boundBy: 1).waitForExistence(timeout: 10), "The demo's payees are listed")
        capture("payees")
        app.navigationBars["Payees"].buttons.firstMatch.tap()

        app.buttons["Rules"].tap()
        XCTAssertTrue(app.navigationBars["Rules"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "If ")).firstMatch
            .waitForExistence(timeout: 10), "Rules read as sentences")
        capture("rules")
        // A new rule starts as Actual's does: if the payee is nothing, set the category.
        app.buttons["Add rule"].tap()
        XCTAssertTrue(app.navigationBars["New Rule"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["payee is nothing"].exists)
        capture("rule-new")
        app.navigationBars["New Rule"].buttons["Cancel"].tap()
        app.navigationBars["Rules"].buttons.firstMatch.tap()

        let numbers = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Numbers")).firstMatch
        scroll(app, to: numbers)
        numbers.tap()
        app.buttons["1.000,33"].tap()
        XCTAssertTrue(numbers.waitForExistence(timeout: 10))
        XCTAssertTrue(numbers.label.contains("1.000,33"), numbers.label)
        capture("formatting")
        app.buttons["Done"].tap()
        let summary = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Available to budget")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        capture("budget-dot-comma")
    }

    /// Chooses each theme from Settings, then makes, renames, and deletes a theme.
    @MainActor
    func testDemoThemes() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 60), "The demo budget should open")
        app.tabBars.buttons["Budget"].tap()
        app.buttons["Settings"].firstMatch.tap()

        let setting = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Theme")).firstMatch
        scroll(app, to: setting)
        setting.tap()
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 10))
        for name in ["Sterling", "Payday"] {
            app.buttons[name].tap()
            XCTAssertTrue(app.buttons[name].isSelected)
            XCTAssertFalse(app.buttons["Actual"].isSelected)
            capture("theme-\(name.lowercased())")
        }

        // A new theme copies the one in use and opens for editing.
        app.buttons["New Theme"].tap()
        XCTAssertTrue(app.navigationBars["My Theme"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["Accent"].firstMatch.exists, "Each color can be changed")
        capture("theme-editor")
        // Wherever the name is typed, the change saves at once.
        let name = app.textFields["Name"]
        name.tap()
        name.typeText("Seaside")
        let renamed = NSPredicate(format: "identifier CONTAINS %@", "Seaside")
        let editor = app.navigationBars.matching(renamed).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Changes save as they are made")
        editor.buttons.firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label BEGINSWITH %@", "Seaside", "Edit")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.isSelected, "A new theme is put to use")

        // Deleting the theme in use returns to Actual's.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit ")).firstMatch.tap()
        let delete = app.buttons["Delete Theme"]
        scroll(app, to: delete)
        delete.tap()
        app.buttons["Delete Theme"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait(forAbsence: row))
        XCTAssertTrue(app.buttons["Actual"].isSelected)
        app.navigationBars["Theme"].buttons.firstMatch.tap()
        XCTAssertTrue(setting.waitForExistence(timeout: 10))
        XCTAssertTrue(setting.label.contains("Actual"), setting.label)
    }

    /// Adds a tag from Settings, and gives a monthly schedule a specific day.
    @MainActor
    func testDemoTagsAndSpecificDays() {
        let app = XCUIApplication()
        app.launch()
        let demoButton = app.buttons["Explore a demo budget"]
        if demoButton.waitForExistence(timeout: 15) { demoButton.tap() }
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 60), "The demo budget should open")
        app.tabBars.buttons["Budget"].tap()
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Tags"].tap()
        XCTAssertTrue(app.navigationBars["Tags"].waitForExistence(timeout: 10))
        let tag = "uitag\(Int(Date().timeIntervalSince1970) % 100_000)"
        app.buttons["Add tag"].tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(tag)
        app.buttons["Add"].tap()
        // Tags are listed alphabetically, among the demo's; search for the new one.
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        search.tap()
        search.typeText(tag)
        XCTAssertTrue(app.staticTexts["#\(tag)"].waitForExistence(timeout: 10), "The new tag should be listed")
        capture("tags")
        // Searching replaces the navigation bar on iOS 27; start the schedule part afresh.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Schedules"].waitForExistence(timeout: 60))

        app.tabBars.buttons["Schedules"].tap()
        app.buttons["Add schedule"].tap()
        XCTAssertTrue(app.navigationBars["New Schedule"].waitForExistence(timeout: 10))
        let add = app.buttons["Add Specific Day"]
        scroll(app, to: add)
        add.tap()
        XCTAssertTrue(app.staticTexts["Swipe to remove a day."].waitForExistence(timeout: 5), "A specific day should be added")
        capture("schedule-specific-day")
        app.buttons["Cancel"].tap()
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

    /// Edits the demo dashboard's widgets: a summary's name, range, and filters from its card,
    /// a range saved from its page, a spending widget's comparison, and the text widget.
    /// It edits widgets the other report test does not open, and keeps their names' beginnings.
    @MainActor
    func testDemoReportEditing() {
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
        /// Rows show as one element with their value, so match the beginning of any label.
        func row(_ label: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        }
        /// A picker's row reads as its title and value; its section's header may share the title.
        func picker(_ title: String) -> XCUIElement { card(title + ",") }
        XCTAssertTrue(card("Total Income (YTD)").waitForExistence(timeout: 30), "The default dashboard should load")
        let editor = app.navigationBars["Edit Widget"]
        func edit(_ title: String) {
            let widget = card(title)
            scroll(app, to: widget)
            widget.press(forDuration: 1.2)
            let editWidget = app.buttons["Edit Widget"]
            XCTAssertTrue(editWidget.waitForExistence(timeout: 10), "Touching and holding a card offers its editor")
            editWidget.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
        }

        // Spending: a month and what to compare it with. Nothing is saved on Cancel.
        edit("Budget Overview")
        XCTAssertTrue(picker("Compare to").waitForExistence(timeout: 20), "The widget's settings should load")
        XCTAssertTrue(card("Month, Current month").exists, "The default widget follows the current month")
        XCTAssertFalse(editor.buttons["Save"].isEnabled, "There is nothing to save until a setting changes")
        picker("Compare to").tap()
        app.buttons["Average"].tap()
        XCTAssertTrue(picker("Average of").waitForExistence(timeout: 10), "An average offers Actual's ranges")
        XCTAssertTrue(wait(for: editor.buttons["Save"], enabled: true))
        capture("report-editor-spending")
        editor.buttons["Cancel"].tap()
        XCTAssertTrue(card("Budget Overview").waitForExistence(timeout: 10))

        // A summary: its name, range, how it shows, and a filter.
        let title = "Recent Net Worth Change"
        edit(title)
        let save = editor.buttons["Save"]
        XCTAssertTrue(picker("Range").waitForExistence(timeout: 20))
        let name = app.textFields["Name"]
        name.tap()
        name.typeText(" edited\n")
        XCTAssertTrue(wait(for: save, enabled: true))
        picker("Range").tap()
        XCTAssertTrue(app.buttons["1 year"].waitForExistence(timeout: 10), "Actual's range presets are offered")
        app.buttons["Fixed months…"].tap()
        XCTAssertTrue(picker("From").waitForExistence(timeout: 10), "Fixed months choose a first and last month")
        XCTAssertTrue(picker("To").exists)
        picker("Range").tap()
        app.buttons["1 year"].tap()
        picker("Show as").tap()
        app.buttons["Percentage"].tap()
        let allTime = app.switches["All time divisor"]
        scroll(app, to: allTime)
        XCTAssertTrue(allTime.exists, "A percentage has filters and a range for what it divides by")
        capture("report-editor-percentage")
        for _ in 0..<4 where !picker("Show as").isHittable { app.swipeDown() }
        picker("Show as").tap()
        app.buttons["Sum"].tap()
        // A filter: only transactions that are not transfers.
        let addFilter = app.buttons["Add Filter"]
        scroll(app, to: addFilter)
        addFilter.tap()
        let filter = row("Category is nothing")
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "A new filter starts on the category")
        filter.tap()
        XCTAssertTrue(app.navigationBars["Filter"].waitForExistence(timeout: 10))
        picker("Field").tap()
        app.buttons["Transfer"].tap()
        XCTAssertTrue(app.switches["Transfer"].waitForExistence(timeout: 10), "Yes-or-no fields show a switch")
        capture("report-editor-filter")
        app.navigationBars["Filter"].buttons.firstMatch.tap()
        XCTAssertTrue(row("Transfer is false").waitForExistence(timeout: 10))
        capture("report-editor")
        save.tap()
        let renamed = card(title + " edited")
        XCTAssertTrue(renamed.waitForExistence(timeout: 20), "The dashboard shows the new name")
        capture("reports-dashboard-edited")

        // A range tried on the report's page can be saved to the widget, as Actual's Save widget does.
        scroll(app, to: renamed)
        renamed.tap()
        let page = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", title + " edited")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "The page has the saved name")
        let saveChoice = app.buttons["Save to Widget"]
        XCTAssertTrue(app.buttons["Saved range"].waitForExistence(timeout: 20))
        XCTAssertFalse(saveChoice.exists, "The page shows the saved widget until something is chosen")
        app.buttons["Saved range"].tap()
        app.buttons["3 months"].tap()
        XCTAssertTrue(saveChoice.waitForExistence(timeout: 10))
        capture("report-save-to-widget")
        saveChoice.tap()
        XCTAssertTrue(app.buttons["Saved range"].waitForExistence(timeout: 20), "Saved choices become the widget's own")
        XCTAssertFalse(saveChoice.exists)
        page.buttons["Edit"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(card("Range, 3 months").waitForExistence(timeout: 20), "The editor opens with the saved range")
        XCTAssertTrue(row("Transfer is false").exists, "The saved filter stays")
        editor.buttons["Cancel"].tap()
        page.buttons.firstMatch.tap()

        // The text widget's Markdown.
        let tips = app.staticTexts["Dashboard Tips"]
        scroll(app, to: tips)
        XCTAssertTrue(tips.waitForExistence(timeout: 10))
        tips.press(forDuration: 1.2)
        let editText = app.buttons["Edit Text"]
        XCTAssertTrue(editText.waitForExistence(timeout: 10))
        editText.tap()
        XCTAssertTrue(app.navigationBars["Edit Text"].waitForExistence(timeout: 10))
        let text = app.textViews["Text"]
        XCTAssertTrue(text.waitForExistence(timeout: 20))
        text.tap()
        // The cursor starts before the heading, which stays a heading on its own line.
        text.typeText("Edited on a phone.\n\n")
        capture("report-text-editor")
        app.navigationBars["Edit Text"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Edited on a phone.")).firstMatch
            .waitForExistence(timeout: 20), "The dashboard shows the edited text")
        capture("reports-text-edited")
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

    /// Adds a transaction without a category beside a reconciliation adjustment: only the first needs one.
    @MainActor
    func testDemoUncategorizedBadge() {
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
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5), "The amount should be focused")
        tapKeys(app, "12")
        app.navigationBars["New transaction"].buttons["Save"].tap()
        XCTAssertTrue(wait(forAbsence: app.navigationBars["New transaction"]), "The transaction should save")
        let uncategorized = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "No payee", "Uncategorized")).firstMatch
        XCTAssertTrue(uncategorized.waitForExistence(timeout: 10), "A transaction without a category says so")

        // An earlier run may have left the account reconciled to this balance.
        checking.buttons["Reconcile"].tap()
        XCTAssertTrue(app.navigationBars["Reconcile"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Clear"].waitForExistence(timeout: 5))
        app.buttons["Clear"].tap()
        tapKeys(app, "7")
        app.navigationBars["Reconcile"].buttons["Reconcile"].tap()
        let create = app.buttons["Create reconciliation transaction"]
        if create.waitForExistence(timeout: 10) { create.tap() }
        XCTAssertTrue(app.buttons["Lock transactions"].waitForExistence(timeout: 10), "The adjustment should balance the account")
        XCTAssertTrue(app.staticTexts["Reconciliation balance adjustment"].firstMatch.waitForExistence(timeout: 10))
        capture("register-uncategorized")
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
