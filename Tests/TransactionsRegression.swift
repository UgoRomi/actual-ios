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
