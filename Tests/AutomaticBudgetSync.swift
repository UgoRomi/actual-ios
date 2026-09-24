import Foundation

private struct AutoSyncFixture: Decodable {
    let password: String
    let encryptionPassword: String
    let syncId: String
    let accountId: String
    let categoryId: String
}
private struct SyncServerState: Decodable {
    let syncRequests: Int
    let uploadAttempts: Int
    let pendingRequests: Int
    let maxInFlight: Int
}
private struct RemoteBudgetState: Decodable {
    let amount: Int
    let balance: Int
    let allocation: Int
    let deletedPresent: Bool
}
private struct RemoteTransaction: Decodable {
    let amount: Int
    let notes: String
}

@main struct AutomaticBudgetSync {
    static let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    static let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    static let server = CommandLine.arguments[4]

    @MainActor static func main() async throws {
        let fixture = try JSONDecoder().decode(AutoSyncFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        try await prepare(fixture)
        try await verifyOpeningAndEdits(fixture)
        try await verifyRestartAndSwitch(fixture)
        try await verifyFailedSnapshotUpload()
    }

    static func engine() throws -> EngineClient {
        try EngineClient(dataDirectory: directory, resourceDirectory: resources, useKeychain: false)
    }
    private static func prepare(_ fixture: AutoSyncFixture) async throws {
        let engine = try engine()
        _ = try await engine.call("connect", arguments: ["url": .string(server), "password": .string(fixture.password)])
        _ = try await engine.call("download", arguments: ["syncId": .string(fixture.syncId), "password": .string(fixture.encryptionPassword)])
        _ = try await control("remote-edit")
    }

    @MainActor private static func verifyOpeningAndEdits(_ fixture: AutoSyncFixture) async throws {
        let model = AppModel(engine: try engine())
        model.selectedMonth = BudgetDate.date("2026-09-01")!
        _ = try await control("hold")
        let opening = Task { await model.activate() }
        try await until("launch request") { try await control("state").pendingRequests == 1 }
        try require(model.isBusy && model.isOpeningBudget && !model.hasStarted, "Launch must await sync before enabling the budget")
        try require(!(await model.perform("budget")), "Editing was allowed during opening sync")
        _ = try await control("release")
        await opening.value
        try require(model.hasStarted && !model.isBusy && !model.isOpeningBudget, "Opening did not finish")
        try require(model.snapshot?.accounts.first { $0.id == fixture.accountId }?.balance == 99800,
                    "Opening balance \(model.snapshot?.accounts.first { $0.id == fixture.accountId }?.balance ?? -1); sync error: \(model.syncErrorMessage ?? "none"); view error: \(model.errorMessage ?? "none")")
        try require(model.lastSyncedAt != nil && model.syncErrorMessage == nil, "Opening sync status missing")
        let openedCount = try await control("state").syncRequests
        await model.activate()
        try require(try await control("state").syncRequests == openedCount, "Duplicate active notifications should not resync")
        print("PASS: launch awaits encrypted budget sync, blocks editing, and shows the latest remote data")

        _ = try await control("hold")
        try require(await model.perform("saveTransaction", arguments: transaction(fixture, amount: -1234)), "First local save failed")
        try await until("post-edit request") { try await control("state").pendingRequests == 1 }
        try require(model.isSyncingBudget && !model.isBusy, "Post-edit sync must leave local editing available")
        guard let saved = model.snapshot?.transactions.first(where: { $0.notes == "Automatic sync edit" }) else { throw EngineFailure("Local edit missing") }
        var edited: Bool?
        Task { edited = await model.perform("saveTransaction", arguments: transaction(fixture, id: saved.id, amount: -2345)) }
        try await until("local save while sync is held", seconds: 3) { edited != nil }
        try require(edited == true, "Second local save failed")
        try require(model.snapshot?.transactions.first { $0.id == saved.id }?.amount == -2345, "Local view did not show the second edit")
        try require(await model.perform("budget", arguments: ["month": .string("2026-09"), "categoryId": .string(fixture.categoryId), "amount": .number(12345)]), "Allocation save failed")
        var temporary = transaction(fixture, amount: -1)
        temporary["notes"] = .string("Delete automatic fixture")
        try require(await model.perform("saveTransaction", arguments: temporary), "Temporary transaction save failed")
        guard let removed = model.snapshot?.transactions.first(where: { $0.notes == "Delete automatic fixture" }) else { throw EngineFailure("Temporary transaction missing") }
        try require(await model.perform("deleteTransaction", arguments: ["id": .string(removed.id)]), "Delete failed")
        let duringEdits = try await control("state")
        try require(duringEdits.syncRequests == openedCount + 1 && duringEdits.maxInFlight == 1, "Rapid edits must share the active request")
        _ = try await control("release")
        try await until("post-edit sync completion") { !model.isSyncingBudget }
        try require(model.syncErrorMessage == nil && model.syncStatus == "Synced with server", model.syncErrorMessage ?? "Wrong sync status")
        let remote = try await remoteState()
        try require(remote.amount == -2345 && remote.balance == 97455, "Latest local edits did not reach the upstream API")
        try require(remote.allocation == 12345 && !remote.deletedPresent, "Allocation or deletion did not sync automatically")
        try require(try await control("state").syncRequests <= openedCount + 4, "Rapid edits were not coalesced")
        print("PASS: saves complete while server responses are held; additions, edits, allocations, and deletions sync automatically")

        _ = try await control("offline")
        let lastSuccess = model.lastSyncedAt
        try require(await model.perform("saveTransaction", arguments: transaction(fixture, id: saved.id, amount: -3456)), "Offline local save failed")
        try await until("offline sync failure") { !model.isSyncingBudget }
        try require(model.errorMessage == nil && model.syncErrorMessage != nil, "Sync failure must not be reported as a failed local save")
        try require(model.lastSyncedAt == lastSuccess, "A failed sync changed the success timestamp")
        try require(model.snapshot?.transactions.first { $0.id == saved.id }?.amount == -3456, "Offline edit was lost")
        print("PASS: failed automatic sync preserves the local save and last successful sync time")
    }

    @MainActor private static func verifyRestartAndSwitch(_ fixture: AutoSyncFixture) async throws {
        let model = AppModel(engine: try engine())
        model.selectedMonth = BudgetDate.date("2026-09-01")!
        await model.activate()
        try require(model.snapshot != nil && !model.isBusy && model.syncErrorMessage != nil, "Offline launch must preserve access to the saved budget")
        guard let saved = model.snapshot?.transactions.first(where: { $0.notes == "Automatic sync edit" }) else { throw EngineFailure("Offline edit missing after restart") }
        try require(saved.amount == -3456, "Offline edit did not survive engine recreation")
        _ = try await control("online")
        _ = try await control("remote-edit")
        _ = try await control("hold")
        model.enteredBackground()
        let reopening = Task { await model.activate() }
        try await until("foreground request") { try await control("state").pendingRequests == 1 }
        try require(model.isOpeningBudget && model.isBusy, "Foreground must wait for sync")
        _ = try await control("release")
        await reopening.value
        let remote = try await remoteState()
        try require(remote.amount == -3456 && remote.balance == 96144, "Foreground did not exchange offline and remote edits")
        try require(model.snapshot?.accounts.first { $0.id == fixture.accountId }?.balance == remote.balance, "Foreground view is stale")
        try require(model.syncErrorMessage == nil && !model.isBusy, "Foreground retry did not clear sync failure")
        print("PASS: offline data survives restart and foreground sync exchanges both local and remote edits")

        // Another device edits the note before this device syncs an amount-only edit.
        _ = try await control("offline")
        _ = try await control("remote-notes?id=\(saved.id)")
        try require(await model.perform("saveTransaction", arguments: transaction(fixture, id: saved.id, amount: -5678)), "Amount edit failed")
        try await until("offline sync after amount edit") { !model.isSyncingBudget }
        _ = try await control("online")
        try require(await model.perform("sync"), "Sync after concurrent edits failed: \(model.syncErrorMessage ?? "none")")
        let merged = try await remoteTransaction(saved.id)
        try require(merged.amount == -5678 && merged.notes == "Remote note", "A local edit overwrote another device's change: \(merged)")
        try require(model.snapshot?.transactions.first { $0.id == saved.id }?.notes == "Remote note", "Local view missed the remote note")
        print("PASS: edits sync only changed fields and keep another device's concurrent change")

        _ = try await control("hold")
        try require(await model.perform("saveTransaction", arguments: transaction(fixture, id: saved.id, amount: -4567)), "Save before switch failed")
        try await until("sync before budget switch") { try await control("state").pendingRequests == 1 }
        var switched: Bool?
        Task { switched = await model.perform("demo") }
        try await until("budget switch waits") { model.isOpeningBudget }
        try require(switched == nil && model.canSyncBudget, "Budget switched while its sync was still active")
        _ = try await control("release")
        try await until("budget switch completes") { switched != nil }
        try require(switched == true && !model.canSyncBudget && model.lastSyncedAt == nil, "New budget inherited old sync state")
        let requestCount = try await control("state").syncRequests
        guard let account = model.snapshot?.openAccounts.first else { throw EngineFailure("Demo account missing") }
        try require(await model.perform("saveTransaction", arguments: ["accountId": .string(account.id), "date": .string("2026-09-24"), "amount": .number(-500), "notes": .string("Local demo edit")]), "Local demo edit failed")
        model.enteredBackground()
        await model.activate()
        try require(!model.isSyncingBudget && model.syncErrorMessage == nil, "Local/demo budget attempted sync")
        try require(try await control("state").syncRequests == requestCount, "Demo generated server traffic")
        print("PASS: budget switching waits for active sync and local/demo budgets remain local")
    }

    @MainActor private static func verifyFailedSnapshotUpload() async throws {
        let engine = try engine()
        let budgets = try JSONDecoder().decode(Bootstrap.self, from: await engine.call("bootstrap")).budgets
        guard let budget = budgets.first(where: { $0.cloudFileId != nil }) else { throw EngineFailure("Server budget missing") }
        // Make the weekly snapshot upload due while the budget is closed.
        let metadataURL = directory.appendingPathComponent(budget.id).appendingPathComponent("metadata.json")
        func lastUploaded() throws -> String? {
            (try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])?["lastUploaded"] as? String
        }
        guard var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any] else { throw EngineFailure("Budget metadata missing") }
        metadata["lastUploaded"] = "2000-01-01"
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        _ = try await control("reject-uploads")
        let model = AppModel(engine: engine)
        await model.activate()
        let attempts = try await control("state").uploadAttempts
        await model.openBudget(budget.id)
        try require(model.snapshot != nil && model.errorMessage == nil, "Budget did not open: \(model.errorMessage ?? "no snapshot")")
        try require(model.syncErrorMessage == nil && model.syncStatus == "Synced with server", "A rejected snapshot upload failed sync: \(model.syncErrorMessage ?? model.syncStatus)")
        try require(try await control("state").uploadAttempts == attempts + 1, "The due snapshot upload was not attempted")
        try require(try lastUploaded() == "2000-01-01", "A rejected upload advanced the upload date")
        _ = try await control("accept-uploads")
        try require(await model.perform("sync"), "Sync failed after uploads recovered: \(model.syncErrorMessage ?? "none")")
        try require(try await control("state").uploadAttempts == attempts + 2, "The snapshot upload was not retried")
        try require(try lastUploaded() != "2000-01-01", "A successful upload did not advance the upload date")
        print("PASS: a rejected snapshot upload does not fail budget sync and retries on the next sync")
    }

    private static func transaction(_ fixture: AutoSyncFixture, id: String? = nil, amount: Int) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["accountId": .string(fixture.accountId), "date": .string("2026-09-24"), "categoryId": .string(fixture.categoryId), "amount": .number(amount), "notes": .string("Automatic sync edit"), "cleared": .bool(true)]
        if let id { arguments["id"] = .string(id) }
        return arguments
    }
    private static func control(_ action: String) async throws -> SyncServerState {
        let (data, _) = try await URLSession.shared.data(from: URL(string: server + "/test/" + action)!)
        return try JSONDecoder().decode(SyncServerState.self, from: data)
    }
    private static func remoteTransaction(_ id: String) async throws -> RemoteTransaction {
        let (data, _) = try await URLSession.shared.data(from: URL(string: server + "/test/transaction?id=" + id)!)
        return try JSONDecoder().decode(RemoteTransaction.self, from: data)
    }
    private static func remoteState() async throws -> RemoteBudgetState {
        let (data, _) = try await URLSession.shared.data(from: URL(string: server + "/test/verify")!)
        return try JSONDecoder().decode(RemoteBudgetState.self, from: data)
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineFailure(message) }
    }
    @MainActor private static func until(_ message: String, seconds: Double = 15, predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw EngineFailure("Timed out waiting for \(message)")
    }
}
