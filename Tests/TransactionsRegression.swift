import Foundation
import SQLite3

@main struct TransactionsRegression {
    static func transaction(_ id: String, date: String = "2026-09-24", account: String = "a",
                            payee: String? = "Market", category: String? = "Food", notes: String? = nil,
                            amount: Int = -1234, parent: Bool = false, child: Bool = false,
                            transfer: Bool = false, categoryID: String? = nil, transferAccount: String? = nil) -> Transaction {
        Transaction(id: id, accountId: account, date: date, payeeId: nil, payeeName: payee,
                    categoryId: categoryID, categoryName: category, amount: amount, notes: notes,
                    cleared: true, isParent: parent, isChild: child, isTransfer: transfer, reconciled: false,
                    transferAccountId: transferAccount)
    }

    static func ids(_ sections: [TransactionSection]) -> [String] {
        sections.flatMap(\.transactions).map(\.id)
    }

    static func main() throws {
        let rows = [transaction("older", date: "2025-01-01"), transaction("parent", parent: true),
                    transaction("child", child: true), transaction("transfer", account: "b", transfer: true),
                    transaction("notes", payee: nil, category: nil, notes: "Caffè holiday", amount: 98765)]
        let grouped = TransactionSection.grouped(rows)
        precondition(grouped.map(\.date) == ["2026-09-24", "2025-01-01"])
        precondition(ids(grouped) == ["parent", "transfer", "notes", "older"])
        precondition(ids(TransactionSection.grouped(rows, accountID: "b")) == ["transfer"])
        precondition(ids(TransactionSection.grouped(rows, search: "HOLIDAY")) == ["notes"])
        precondition(ids(TransactionSection.grouped(rows, search: "no payee")) == ["notes"])
        precondition(ids(TransactionSection.grouped(rows, search: "uncategorized")) == ["notes"])
        precondition(ids(TransactionSection.grouped(rows, search: "MARKET")) == ["parent", "transfer", "older"])
        precondition(ids(TransactionSection.grouped(rows, search: "food")) == ["parent", "transfer", "older"])
        precondition(TransactionSection.grouped(rows, accountID: "b", search: "HOLIDAY").isEmpty)
        precondition(TransactionSection.grouped(rows, search: "missing").isEmpty)
        precondition(TransactionSection.grouped([]).isEmpty)
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "it_IT")] {
            for currency in ["", "EUR"] {
                let amount = Money.formatted(98765, currency: currency, locale: locale)
                precondition(ids(TransactionSection.grouped(rows, search: amount, currency: currency, locale: locale)) == ["notes"])
                let negative = Money.formatted(-1234, currency: currency, locale: locale)
                precondition(ids(TransactionSection.grouped(rows, search: negative, currency: currency, locale: locale)) == ["parent", "transfer", "older"])
            }
        }
        print("PASS: dates, stable same-day order, accounts, splits/transfers, text and localized amount searches")

        // A category's month and the uncategorized list, with split parts, as Actual's queries select them.
        var split = transaction("split", parent: true)
        split.splits = [
            SplitPart(id: "part-food", amount: -1000, categoryId: "food", categoryName: "Food", notes: "", isTransfer: false),
            SplitPart(id: "part-none", amount: -234, categoryId: nil, categoryName: nil, notes: "", isTransfer: false),
            SplitPart(id: "part-transfer", amount: 0, categoryId: nil, categoryName: nil, notes: "", isTransfer: true),
        ]
        let listed = [
            transaction("food", categoryID: "food"), transaction("none"), split,
            transaction("budget-transfer", transferAccount: "b"), transaction("off-transfer", transferAccount: "off"),
            transaction("off-account", account: "off"), transaction("last-month", date: "2026-08-10", categoryID: "food"),
        ]
        let accounts = [Account(id: "a", name: "A", balance: 0, offbudget: false, closed: false),
                        Account(id: "b", name: "B", balance: 0, offbudget: false, closed: false),
                        Account(id: "off", name: "Off", balance: 0, offbudget: true, closed: false)]
        let food = CategoryEntry.entries(listed, filter: .category(id: "food", month: "2026-09"), accounts: accounts)
        precondition(food.map(\.id) == ["food", "part-food"] && food.map(\.amount) == [-1234, -1000])
        precondition(food[1].transaction.id == "split", "A part opens its whole split")
        let uncategorized = CategoryEntry.entries(listed, filter: .uncategorized, accounts: accounts)
        precondition(uncategorized.map(\.id) == ["none", "part-none", "off-transfer"], "\(uncategorized.map(\.id))")
        print("PASS: category and uncategorized lists include split parts and skip on-budget transfers and off-budget accounts")

        // The budget's number and date formats, as Actual's settings choose them.
        Money.configure(BudgetFormat(numberFormat: "dot-comma", hideFraction: false))
        precondition(Money.formatted(123_456) == "1.234,56", Money.formatted(123_456))
        precondition(Money.parse("1.234,56") == 123_456 && Money.editable(123_456) == "1234,56")
        Money.configure(BudgetFormat(numberFormat: "comma-dot", hideFraction: true))
        precondition(Money.formatted(123_456) == "1,235" && Money.parse("12.5") == 1250)
        Money.configure(BudgetFormat(numberFormat: "comma-dot-in", hideFraction: false))
        precondition(Money.formatted(10_000_000) == "1,00,000.00", Money.formatted(10_000_000))
        Money.configure(nil)
        precondition(Money.locale == .current && !Money.hidesFraction)
        BudgetDate.configure(BudgetFormat(hideFraction: false, dateFormat: "dd.MM.yyyy", firstDayOfWeekIdx: 1))
        precondition(BudgetDate.display("2026-09-24") == "24.09.2026" && BudgetDate.calendar.firstWeekday == 2)
        BudgetDate.configure(nil)
        print("PASS: number formats, hidden decimals, date formats, and the first day of the week")

        // Actual's #tags: anything but whitespace or #; ## escapes a tag.
        precondition(NoteTags.extract("lunch #food #work #food") == ["food", "work"])
        precondition(NoteTags.extract("a#b ##escaped #") == ["b"], "\(NoteTags.extract("a#b ##escaped #"))")
        precondition(NoteTags.extract("#one#two") == ["one", "two"] && NoteTags.extract(nil).isEmpty)
        print("PASS: #tags in notes, with escapes")

        // As in Actual's mobile register, a transfer names the other account and its direction.
        var sent = transaction("sent", payee: "Ally Savings", category: "Uncategorized", amount: -5000,
                               transfer: true, transferAccount: "savings")
        let received = transaction("received", account: "savings", payee: "Checking", category: "Food", amount: 5000,
                                   transfer: true, categoryID: "food", transferAccount: "a")
        precondition(sent.title == "Transfer to Ally Savings" && sent.detail == "Transfer" && sent.canEdit)
        precondition(received.title == "Transfer from Checking" && received.detail == "Food")
        precondition(ids(TransactionSection.grouped([sent, received], search: "ally")) == ["sent"])
        precondition(ids(TransactionSection.grouped([sent, received], search: "transfer from")) == ["received"])
        precondition(ids(TransactionSection.grouped([sent, received], search: "Transfer")) == ["sent", "received"])
        sent.transferInSplit = true
        precondition(!sent.canEdit, "A transfer linked to part of a split stays view only")
        print("PASS: transfer titles, categories, search, and split-linked view-only state")

        try verifyPendingEdits()

        // Thousands of days matter: a single-day fixture misses the original repeated-scan bug.
        let synthetic: [Transaction] = (0..<10_000).map { index in
            let year = 2010 + index / 336
            let month = 1 + (index / 28) % 12
            let day = 1 + index % 28
            let date = String(format: "%04d-%02d-%02d", year, month, day)
            return transaction("t-\(index)", date: date)
        }
        try benchmark(synthetic, label: "Synthetic 10,000-day budget", baseline: false)
        if let path = CommandLine.arguments.dropFirst().first {
            try benchmark(readTransactions(path), label: "Read-only SQLite fixture", baseline: CommandLine.arguments.contains("--baseline"))
        }
    }

    /// Edits shown before the engine saves them. Each applies once, even to a
    /// register that already includes it, so a reload during the save cannot count it twice.
    static func verifyPendingEdits() throws {
        func account(_ id: String, balance: Int, cleared: Int) -> Account {
            Account(id: id, name: id, balance: balance, offbudget: false, closed: false, clearedBalance: cleared)
        }
        func balances(_ accounts: [Account]) -> [String] { accounts.map { "\($0.id):\($0.balance)/\($0.clearedBalance ?? 0)" } }
        func applied(_ changes: [TransactionChange], to rows: [Transaction], _ accounts: [Account]) -> ([Transaction], [Account]) {
            var rows = rows, accounts = accounts
            for change in changes { change.apply(to: &rows, accounts: &accounts) }
            return (rows, accounts)
        }
        var uncleared = transaction("coffee", amount: -500)
        uncleared.cleared = false
        var sent = transaction("sent", date: "2026-09-20", amount: -5000, transfer: true, transferAccount: "b")
        sent.transferId = "received"
        var received = transaction("received", date: "2026-09-20", account: "b", amount: 5000, transfer: true, transferAccount: "a")
        received.transferId = "sent"
        received.reconciled = true
        sent.transferReconciled = true
        let rows = [uncleared, received, sent, transaction("rent", date: "2026-09-01", amount: -100_000)]
        let accounts = [account("a", balance: -105_500, cleared: -105_000), account("b", balance: 5000, cleared: 5000)]

        // Clearing moves the amount into the cleared balance, once.
        let clear = TransactionChange.setCleared(id: "coffee", cleared: true)
        var (cleared, clearedAccounts) = applied([clear, clear], to: rows, accounts)
        precondition(cleared.first { $0.id == "coffee" }?.cleared == true)
        precondition(balances(clearedAccounts) == ["a:-105500/-105500", "b:5000/5000"])
        (cleared, clearedAccounts) = applied([.setCleared(id: "coffee", cleared: false)], to: cleared, clearedAccounts)
        precondition(balances(clearedAccounts) == balances(accounts), "Unclearing restores the cleared balance")

        // A new transaction takes its place in the engine's order: newest date first, then ID.
        var added = transaction("new", date: "2026-09-21", amount: -700)
        added.cleared = false
        let (withNew, newAccounts) = applied([.save(added), .save(added)], to: rows, accounts)
        precondition(withNew.map(\.id) == ["coffee", "new", "received", "sent", "rent"], "\(withNew.map(\.id))")
        precondition(balances(newAccounts) == ["a:-106200/-105000", "b:5000/5000"])

        // An edit moves the difference, and moving accounts moves the amount between them.
        var moved = uncleared
        moved.amount = -800
        moved.accountId = "b"
        moved.date = "2026-08-31"
        let (edited, editedAccounts) = applied([.save(moved), .save(moved)], to: rows, accounts)
        precondition(edited.map(\.id) == ["received", "sent", "rent", "coffee"])
        precondition(balances(editedAccounts) == ["a:-105000/-105000", "b:4200/5000"])

        // A transfer's linked transaction gets the same amount and notes.
        var resent = sent
        resent.amount = -6000
        resent.notes = "Savings"
        let (transfer, transferAccounts) = applied([.save(resent)], to: rows, accounts)
        let linked = transfer.first { $0.id == "received" }
        precondition(linked?.amount == 6000 && linked?.notes == "Savings")
        precondition(balances(transferAccounts) == ["a:-106500/-106000", "b:6000/6000"])

        // Deleting a transfer deletes both sides, once.
        let (deleted, deletedAccounts) = applied([.delete(id: "sent"), .delete(id: "sent")], to: rows, accounts)
        precondition(deleted.map(\.id) == ["coffee", "rent"])
        precondition(balances(deletedAccounts) == ["a:-100500/-100000", "b:0/0"])

        // Unlocking also tells the linked transaction's editor.
        let (unlocked, _) = applied([.unlock(id: "received")], to: rows, accounts)
        precondition(unlocked.first { $0.id == "received" }?.isReconciled == false)
        precondition(unlocked.first { $0.id == "sent" }?.transferReconciled == false)

        // Applied to a register that already includes an edit, it changes nothing.
        let (once, onceAccounts) = applied([.save(moved), .delete(id: "sent"), clear], to: rows, accounts)
        let (twice, twiceAccounts) = applied([.save(moved), .delete(id: "sent"), clear], to: once, onceAccounts)
        precondition(twice.map(\.id) == once.map(\.id) && balances(twiceAccounts) == balances(onceAccounts))
        print("PASS: pending edits clear, add, edit, move, transfer, delete, and unlock once, in the engine's order")
    }

    static func benchmark(_ rows: [Transaction], label: String, baseline: Bool) throws {
        let start = Date()
        let sections = TransactionSection.grouped(rows)
        let elapsed = Date().timeIntervalSince(start)
        let expected = rows.filter { !$0.isChild }.sorted { $0.date > $1.date }.map(\.id)
        precondition(ids(sections) == expected, "Every visible transaction must remain in order")
        precondition(elapsed < 5, "Grouping should not block the UI for seconds")
        let searchStart = Date()
        precondition(TransactionSection.grouped(rows, search: "no-match-unique-search-token").isEmpty)
        let searchElapsed = Date().timeIntervalSince(searchStart)
        precondition(searchElapsed < 5, "Search must reuse its amount formatter")
        print("PASS: \(label): \(rows.count) rows / \(sections.count) days; grouping \(elapsed)s; search \(searchElapsed)s")
        if baseline {
            let oldStart = Date()
            var count = 0
            for date in sections.map(\.date) {
                // Exact old section preparation path (without search).
                count += rows.filter { !$0.isChild }.sorted { $0.date > $1.date }.filter { $0.date == date }.count
            }
            precondition(count == expected.count)
            print("Old section preparation: \(Date().timeIntervalSince(oldStart))s")
        }
    }

    // Optional user fixture stays outside the repository and is never modified or printed.
    static func readTransactions(_ path: String) throws -> [Transaction] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw NSError(domain: "Cannot open fixture", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT t.id, t.acct, t.date, p.name, c.name, t.notes, t.amount, t.isParent, t.isChild,
                   (t.transferred_id IS NOT NULL OR p.transfer_acct IS NOT NULL)
            FROM transactions t
            LEFT JOIN payees p ON p.id = t.description
            LEFT JOIN categories c ON c.id = t.category
            JOIN accounts a ON a.id = t.acct AND a.tombstone = 0
            WHERE t.tombstone = 0 ORDER BY t.date DESC, t.id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "Cannot query fixture", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        var rows: [Transaction] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let day = sqlite3_column_int(statement, 2)
            rows.append(transaction(text(0) ?? "", date: String(format: "%04d-%02d-%02d", day / 10000, day / 100 % 100, day % 100),
                                    account: text(1) ?? "", payee: text(3), category: text(4), notes: text(5),
                                    amount: Int(sqlite3_column_int64(statement, 6)), parent: sqlite3_column_int(statement, 7) != 0,
                                    child: sqlite3_column_int(statement, 8) != 0, transfer: sqlite3_column_int(statement, 9) != 0))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw NSError(domain: "Cannot read fixture", code: 3) }
        return rows
    }
}
