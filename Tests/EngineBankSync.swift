import Foundation

private struct BankRequest: Decodable {
    let path: String
    let accountIds: [String]
}

@main struct EngineBankSync {
    static let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    static let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    static let server = CommandLine.arguments[3]
    static let linkedIDs = ["bank-checking", "bank-rate", "bank-sf-a", "bank-sf-b", "bank-sf-no-external", "bank-broken", "bank-no-external"]

    @MainActor static func main() async throws {
        let budgetID = try await createFixture()
        if CommandLine.arguments.last == "seed-ui" {
            let target = directory.appendingPathComponent("bank-sync-regression")
            try FileManager.default.moveItem(at: directory.appendingPathComponent(budgetID), to: target)
            try Data("{\"id\":\"bank-sync-regression\",\"budgetName\":\"Bank Sync Regression\"}".utf8)
                .write(to: target.appendingPathComponent("metadata.json"))
            print("Created disposable UI fixture at \(target.path)")
            return
        }
        try configure(budgetID: budgetID)
        try await verifyGuards(expected: "Connect to your Actual server")
        try configure(budgetID: budgetID, url: server)
        try await verifyGuards(expected: "Connect to your Actual server")
        try configure(budgetID: budgetID, url: server, token: "disposable-bank-token")
        try await verifyRefresh(budgetID: budgetID)
        try configure(budgetID: budgetID, url: server, token: "disposable-bank-token", blocked: true)
        try await verifyGuards(expected: "could not be applied")
        print("PASS: bank sync blocks missing credentials, invalid account IDs, and recovery warnings")
    }

    static func engine() throws -> EngineClient {
        try EngineClient(dataDirectory: directory, resourceDirectory: resources, useKeychain: false)
    }

    static func createFixture() async throws -> String {
        let engine = try engine()
        _ = try await engine.call("demo")
        let noLinkedAccounts = try JSONDecoder().decode(BankSyncResult.self, from: await engine.call("syncAccounts"))
        precondition(noLinkedAccounts.accounts.isEmpty)
        let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: await engine.call("bootstrap"))
        guard let budgetID = bootstrap.activeBudgetId else { throw EngineFailure("No fixture budget") }
        _ = try await engine.call("close")
        let host = try NativeHost(dataDirectory: directory, resourceDirectory: resources, useKeychain: false)
        guard let handle = try host.perform("sql.open", ["path": "/documents/\(budgetID)/db.sqlite"]) as? Int else {
            throw EngineFailure("Could not seed bank fixture")
        }
        _ = try host.perform("sql.query", ["id": handle, "sql": "INSERT INTO banks (id, bank_id, name, tombstone) VALUES ('fixture-bank', 'external-bank', 'Fixture Bank', 0), ('incomplete-bank', NULL, 'Incomplete Bank', 0)"])
        for id in linkedIDs + ["bank-manual", "bank-closed", "bank-deleted"] {
            // SimpleFIN may store no external bank ID; its batch sync does not need one.
            let bank: Any = id == "bank-manual" ? NSNull() : ["bank-no-external", "bank-sf-no-external"].contains(id) ? "incomplete-bank" : "fixture-bank"
            let external: Any = id == "bank-broken" || id == "bank-manual" ? NSNull() : id
            let source: Any = id == "bank-manual" ? NSNull() : id.hasPrefix("bank-sf-") ? "simpleFin" : "goCardless"
            _ = try host.perform("sql.query", ["id": handle,
                "sql": "INSERT INTO accounts (id, name, bank, account_id, account_sync_source, closed, tombstone, offbudget, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)",
                "params": [id, id, bank, external, source, id == "bank-closed" ? 1 : 0, id == "bank-deleted" ? 1 : 0, id == "bank-sf-b" ? 1 : 0]])
        }
        _ = try host.perform("sql.query", ["id": handle,
            "sql": "INSERT INTO rules (id, stage, conditions, actions, conditions_op, tombstone) VALUES (?, 'post', ?, ?, 'and', 0)",
            "params": ["bank-fixture-rule", "[{\"field\":\"notes\",\"op\":\"is\",\"value\":\"Bank fixture import\"}]", "[{\"field\":\"notes\",\"op\":\"set\",\"value\":\"Bank rule applied\"}]"]])
        for preference in ["sync-import-pending-bank-sf-b", "sync-import-notes-bank-sf-b"] {
            _ = try host.perform("sql.query", ["id": handle, "sql": "INSERT INTO preferences (id, value) VALUES (?, 'false')", "params": [preference]])
        }
        _ = try host.perform("sql.close", ["id": handle])
        _ = try await engine.call("open", arguments: ["id": .string(budgetID)])
        for id in linkedIDs + ["bank-manual", "bank-closed"] {
            _ = try await engine.call("saveTransaction", arguments: [
                "accountId": .string(id), "date": .string(BudgetDate.day(Date())),
                "payeeName": .string("Bank fixture opening"), "amount": .number(100000), "cleared": .bool(true)
            ])
        }
        _ = try await engine.call("close")
        return budgetID
    }

    static func configure(budgetID: String, url: String? = nil, token: String? = nil, blocked: Bool = false) throws {
        let host = try NativeHost(dataDirectory: directory, resourceDirectory: resources, useKeychain: false)
        guard var settings = try host.perform("settings.read", [:]) as? [String: Any] else { throw EngineFailure("Missing settings") }
        settings["native-last-budget"] = budgetID
        settings["server-url"] = url
        settings["user-token"] = token
        settings["native-dropped-sync:" + budgetID] = blocked
        _ = try host.perform("settings.write", settings)
    }

    static func verifyGuards(expected: String) async throws {
        let engine = try engine()
        _ = try await engine.call("bootstrap")
        let before = try await requests().count
        do {
            _ = try await engine.call("syncAccounts")
            throw EngineFailure("Bank sync should be blocked")
        } catch { precondition(error.localizedDescription.contains(expected), error.localizedDescription) }
        let after = try await requests().count
        precondition(before == after)
        _ = try await engine.call("close")
    }

    @MainActor static func verifyRefresh(budgetID: String) async throws {
        let engine = try engine()
        let model = AppModel(engine: engine)
        await model.start()
        precondition(model.errorMessage == nil, model.errorMessage ?? "")
        precondition(Set(model.snapshot?.accounts.filter(\.canSyncBank).map(\.id) ?? []) == Set(linkedIDs))
        precondition(model.snapshot?.accounts.contains { $0.id == "bank-deleted" } == false)

        let initialRequests = try await requests().count
        for id in ["bank-manual", "bank-closed"] {
            let result = try await sync(engine, id: id)
            precondition(result.accounts.isEmpty)
        }
        for arguments: [String: JSONValue] in [["accountId": .string("")], ["accountId": .null], ["accountId": .number(5)], ["accountId": .string("missing-account")]] {
            do {
                _ = try await engine.call("syncAccounts", arguments: arguments)
                throw EngineFailure("Invalid account selector accepted")
            } catch { precondition(!error.localizedDescription.contains("selector accepted")) }
        }
        let afterGuards = try await requests().count
        precondition(afterGuards == initialRequests)
        print("PASS: unlinked, closed, deleted, and invalid accounts never reach a bank provider")

        await model.refreshAccounts(accountID: "bank-checking")
        precondition(model.bankSyncResult?.accounts.count == 1)
        precondition(model.bankSyncResult?.accounts.first?.added == 1)
        precondition(model.bankSyncResult?.accounts.first?.error == nil)
        precondition(model.snapshot?.accounts.first { $0.id == "bank-checking" }?.balance == 98766)
        precondition(model.snapshot?.accounts.first { $0.id == "bank-checking" }?.lastBankSyncDate != nil)
        precondition(model.snapshot?.transactions.contains { $0.accountId == "bank-checking" && $0.amount == -1234 && $0.cleared } == true)
        precondition(model.snapshot?.transactions.contains { $0.accountId == "bank-checking" && $0.notes == "Bank rule applied" } == true)
        let selectedRequest = try await requests().last
        precondition(selectedRequest?.accountIds == ["bank-checking"])

        await model.refreshAccounts(accountID: "bank-checking")
        precondition(model.bankSyncResult?.accounts.first?.added == 0)
        precondition(model.snapshot?.transactions.filter { $0.accountId == "bank-checking" && $0.amount == -1234 }.count == 1)
        print("PASS: selected account imports exact cents, reports last refresh, and repeat imports do not duplicate")

        let beforeAll = try await requests().count
        await model.refreshAccounts()
        guard let result = model.bankSyncResult else { throw EngineFailure(model.bankSyncErrorMessage ?? "No bank result") }
        precondition(result.accounts.count == linkedIDs.count)
        precondition(result.accounts.filter { $0.error == nil }.count == 4)
        precondition(result.accounts.first { $0.id == "bank-rate" }?.error?.contains("refresh limit") == true)
        precondition(result.accounts.first { $0.id == "bank-no-external" }?.error?.contains("incomplete") == true)
        precondition(model.snapshot?.accounts.first { $0.id == "bank-rate" }?.bankSyncStatus == "rate-limit-exceeded")
        precondition(model.snapshot?.accounts.first { $0.id == "bank-sf-a" }?.balance == 98766)
        precondition(model.snapshot?.accounts.first { $0.id == "bank-sf-b" }?.balance == 98766)
        precondition(model.snapshot?.accounts.first { $0.id == "bank-sf-no-external" }?.balance == 98766)
        precondition(model.snapshot?.transactions.contains { $0.accountId == "bank-sf-b" && $0.amount == -100 } == false)
        precondition(model.snapshot?.transactions.first { $0.accountId == "bank-sf-b" && $0.amount == -1234 }?.notes == "")
        precondition(model.syncStatus == "Saved on this device" && model.lastSyncedAt == nil)
        precondition(!model.isBusy && model.syncingAccountIDs.isEmpty)
        let allRequests = Array(try await requests().dropFirst(beforeAll))
        precondition(allRequests.count == 3)
        precondition(allRequests.filter { $0.path == "/simplefin/transactions" }.count == 1)
        precondition(Set(allRequests.first { $0.path == "/simplefin/transactions" }?.accountIds ?? []) == Set(["bank-sf-a", "bank-sf-b", "bank-sf-no-external"]))
        print("PASS: SimpleFIN batches once, including accounts without an external bank ID; off-budget accounts import, rules/preferences apply, partial failures retain successful imports")

        await model.refreshAccounts(accountID: "bank-sf-a")
        let simpleFinRequest = try await requests().last
        precondition(simpleFinRequest?.accountIds == ["bank-sf-a"])
        precondition(model.bankSyncResult?.accounts.first?.added == 0)
        try await mode("reauth")
        await model.refreshAccounts(accountID: "bank-rate")
        precondition(model.bankSyncResult?.accounts.first?.error?.contains("Reconnect this account") == true)
        try await mode("unauthorized")
        await model.refreshAccounts(accountID: "bank-checking")
        precondition(model.bankSyncResult?.accounts.first?.error?.contains("Settings") == true)
        try await mode("simplefin-missing")
        await model.refreshAccounts(accountID: "bank-sf-a")
        precondition(model.bankSyncResult?.accounts.first?.error != nil)
        try await mode("success")
        await model.refreshAccounts(accountID: "bank-rate")
        precondition(model.bankSyncResult?.accounts.first?.error == nil)
        precondition(model.snapshot?.accounts.first { $0.id == "bank-rate" }?.bankSyncStatus == "ok")
        precondition(model.snapshot?.accounts.first { $0.id == "bank-rate" }?.balance == 98766)
        let busyRequests = try await requests().count
        model.isBusy = true
        await model.refreshAccounts()
        let afterBusy = try await requests().count
        precondition(afterBusy == busyRequests)
        model.isBusy = false
        let closed = await model.closeBudget()
        precondition(closed)
        precondition(model.bankSyncResult == nil && model.bankSyncErrorMessage == nil)
        print("PASS: retry, expired authentication, missing bank data, busy guard, and budget-switch state")

        let reopened = try self.engine()
        _ = try await reopened.call("open", arguments: ["id": .string(budgetID)])
        let restored = try await BudgetSnapshot.load(reopened, month: BudgetDate.month(Date()))
        precondition(restored.accounts.first { $0.id == "bank-rate" }?.balance == 98766)
        precondition(restored.accounts.first { $0.id == "bank-rate" }?.lastBankSyncDate != nil)
        precondition(restored.accounts.first { $0.id == "bank-sf-a" }?.bankSyncNeedsAttention == true)
        _ = try await reopened.call("close")
        print("PASS: imported transactions, balances, last refresh, and failure status persist after reopen")
    }

    static func sync(_ engine: EngineClient, id: String) async throws -> BankSyncResult {
        try JSONDecoder().decode(BankSyncResult.self, from: await engine.call("syncAccounts", arguments: ["accountId": .string(id)]))
    }
    private static func requests() async throws -> [BankRequest] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: server + "/test/requests")!)
        return try JSONDecoder().decode([BankRequest].self, from: data)
    }
    static func mode(_ value: String) async throws {
        _ = try await URLSession.shared.data(from: URL(string: server + "/test/mode/" + value)!)
    }
}
