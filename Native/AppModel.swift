import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    private var engine: EngineClient?
    var snapshot: BudgetSnapshot?
    var localBudgets: [BudgetFile] = []
    var serverBudgets: [BudgetFile] = []
    var selectedMonth = Date()
    var isBusy = false
    var isOpeningBudget = false
    var isSyncingBudget = false
    var syncErrorMessage: String?
    var hasStarted = false
    var errorMessage: String?
    var syncStatus = "On this device"
    var lastSyncedAt: Date?
    var syncingAccountIDs: Set<String> = []
    var bankSyncResult: BankSyncResult?
    var bankSyncErrorMessage: String?
    var bankSyncAccountID: String?
    private var syncTask: Task<Bool, Never>?
    private var syncRequested = false
    private var budgetGeneration = 0
    private var snapshotRequest = 0
    private var needsForegroundSync = false
    private var isAppActive = true

    init(engine: EngineClient? = nil) { self.engine = engine }

    var month: String { BudgetDate.month(selectedMonth) }
    var currency: String { snapshot?.currencyCode ?? "" }
    var canSyncBudget: Bool { snapshot?.cloudFileId != nil }

    private func client() throws -> EngineClient {
        if let engine { return engine }
        let created = try EngineClient()
        engine = created
        return created
    }

    func start() async {
        guard !hasStarted, !isBusy else { return }
        isBusy = true
        isOpeningBudget = true
        defer { hasStarted = true; finishOperation() }
        do {
            let result = try await client().call("bootstrap")
            let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: result)
            localBudgets = bootstrap.budgets
            if let id = bootstrap.activeBudgetId {
                _ = try await client().call("open", arguments: ["id": .string(id)])
                try await loadSnapshot()
                _ = await beginBudgetSync()?.value
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadSnapshot() async throws {
        snapshotRequest += 1
        let request = snapshotRequest, generation = budgetGeneration, requestedMonth = month
        let result = try await client().call("snapshot", arguments: ["month": .string(requestedMonth)])
        let value = try JSONDecoder().decode(BudgetSnapshot.self, from: result)
        guard request == snapshotRequest, generation == budgetGeneration, requestedMonth == month else { return }
        snapshot = value
    }

    func enteredBackground() {
        isAppActive = false
        needsForegroundSync = true
    }

    func activate() async {
        isAppActive = true
        if !hasStarted { await start(); return }
        guard needsForegroundSync, !isBusy else { return }
        needsForegroundSync = false
        guard canSyncBudget else { return }
        isBusy = true
        isOpeningBudget = true
        defer { finishOperation() }
        _ = await beginBudgetSync()?.value
    }

    private func finishOperation() {
        isBusy = false
        isOpeningBudget = false
        if isAppActive && needsForegroundSync { Task { await activate() } }
    }

    @discardableResult
    private func beginBudgetSync() -> Task<Bool, Never>? {
        guard canSyncBudget else { return nil }
        syncRequested = true
        syncStatus = "Syncing with server…"
        if let syncTask { return syncTask }
        isSyncingBudget = true
        syncErrorMessage = nil
        let generation = budgetGeneration
        let task = Task { await drainBudgetSync(generation: generation) }
        syncTask = task
        return task
    }

    private func drainBudgetSync(generation: Int) async -> Bool {
        var succeeded = true
        while syncRequested && generation == budgetGeneration {
            syncRequested = false
            do {
                _ = try await client().call("sync")
                lastSyncedAt = Date()
                syncErrorMessage = nil
            } catch {
                succeeded = false
                syncErrorMessage = "Your changes are saved on this device. \(error.localizedDescription)"
            }
            // Sync can receive changes even when a later step fails. Do not
            // erase a local save error or overwrite an editor's draft.
            do { try await loadSnapshot() }
            catch {
                succeeded = false
                let message = "The latest view could not load. Refresh to try again. \(error.localizedDescription)"
                syncErrorMessage = [syncErrorMessage, message].compactMap { $0 }.joined(separator: "\n")
            }
            // Never spin on an unavailable server. Retry on the next edit,
            // foreground entry, or explicit Sync now.
            if !succeeded { break }
        }
        syncTask = nil
        isSyncingBudget = false
        syncStatus = succeeded ? "Synced with server" : "Sync needs attention"
        return succeeded
    }

    private func resetBudgetSyncState() {
        budgetGeneration += 1
        syncRequested = false
        syncErrorMessage = nil
        lastSyncedAt = nil
        syncStatus = "On this device"
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do { try await loadSnapshot(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func refreshAccounts(accountID: String? = nil) async {
        guard !isBusy else { return }
        let accounts = snapshot?.accounts.filter { $0.canSyncBank && (accountID == nil || $0.id == accountID) } ?? []
        guard !accounts.isEmpty else { await refresh(); return }
        isBusy = true
        syncingAccountIDs = Set(accounts.map(\.id))
        bankSyncAccountID = accountID
        bankSyncResult = nil
        bankSyncErrorMessage = nil
        errorMessage = nil
        defer { syncingAccountIDs = []; finishOperation() }
        do {
            let arguments: [String: JSONValue] = accountID.map { ["accountId": .string($0)] } ?? [:]
            let data = try await client().call("syncAccounts", arguments: arguments)
            bankSyncResult = try JSONDecoder().decode(BankSyncResult.self, from: data)
            // Even a partial refresh can save imports and connection status locally.
            if bankSyncResult?.accounts.isEmpty == false { syncStatus = "Saved on this device" }
        } catch { bankSyncErrorMessage = error.localizedDescription }
        // A failure may follow successful imports. Always reload the saved state.
        do { try await loadSnapshot() }
        catch { errorMessage = "The latest view could not load. Refresh to try again. \(error.localizedDescription)" }
        if bankSyncResult?.accounts.isEmpty == false { beginBudgetSync() }
    }

    private func clearBankSyncState() {
        bankSyncResult = nil
        bankSyncErrorMessage = nil
        bankSyncAccountID = nil
    }

    @discardableResult
    func perform(_ method: String, arguments: [String: JSONValue] = [:]) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { finishOperation() }
        let switchesBudget = ["open", "download", "demo"].contains(method)
        if method == "sync" {
            guard let task = beginBudgetSync() else {
                errorMessage = "This budget is local only. Open a synced budget to synchronize."
                return false
            }
            return await task.value
        }
        if switchesBudget {
            isOpeningBudget = true
            _ = await syncTask?.value
        }
        do {
            _ = try await client().call(method, arguments: arguments)
            if switchesBudget {
                clearBankSyncState()
                resetBudgetSyncState()
            }
            if method == "saveTransaction" || method == "deleteTransaction" || method == "budget" {
                syncStatus = "Saved on this device"
            }
            do { try await loadSnapshot() }
            catch {
                if switchesBudget { snapshot = nil }
                // The write succeeded. Do not invite a duplicate transaction by reporting it as unsaved.
                let action = switchesBudget ? "Budget opened" : "Saved"
                errorMessage = "\(action), but the latest view could not load. Refresh to try again. \(error.localizedDescription)"
            }
            if switchesBudget { _ = await beginBudgetSync()?.value }
            else if ["saveTransaction", "deleteTransaction", "budget"].contains(method) { beginBudgetSync() }
            return true
        } catch {
            let operationError = error.localizedDescription
            if switchesBudget {
                // The bridge restores the previous budget before failing. Keep
                // the sheet and its draft alive while reloading that budget.
                // isBusy prevents writes until the engine state is confirmed.
                do { try await loadSnapshot() }
                catch { snapshot = nil; resetBudgetSyncState(); clearBankSyncState() }
            }
            errorMessage = operationError
            return false
        }
    }

    func openBudget(_ id: String) async {
        guard !isBusy else { return }
        _ = await perform("open", arguments: ["id": .string(id)])
    }

    @discardableResult
    func connect(url: String, password: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { finishOperation() }
        _ = await syncTask?.value
        serverBudgets = []
        do {
            let result = try await client().call("connect", arguments: ["url": .string(url), "password": .string(password)])
            serverBudgets = try JSONDecoder().decode(BudgetListing.self, from: result).budgets
            errorMessage = nil
            syncStatus = "Connected to server"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func moveMonth(_ offset: Int) async {
        guard !isBusy, let newMonth = Calendar(identifier: .gregorian).date(byAdding: .month, value: offset, to: selectedMonth) else { return }
        let previousMonth = selectedMonth
        selectedMonth = newMonth
        await refresh()
        if snapshot?.month != month { selectedMonth = previousMonth }
    }

    func closeBudget() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { finishOperation() }
        _ = await syncTask?.value
        do {
            _ = try await client().call("close")
            // The engine is closed even if the subsequent budget listing fails.
            snapshot = nil
            clearBankSyncState()
            resetBudgetSyncState()
            do {
                let data = try await client().call("bootstrap")
                localBudgets = try JSONDecoder().decode(Bootstrap.self, from: data).budgets
                errorMessage = nil
            } catch {
                errorMessage = "Budget closed, but saved budgets could not be loaded. Tap Try again to reload them. \(error.localizedDescription)"
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
