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
    var hasStarted = false
    var errorMessage: String?
    var syncStatus = "On this device"
    var lastSyncedAt: Date?

    var month: String { BudgetDate.month(selectedMonth) }
    var currency: String { snapshot?.currencyCode ?? "" }

    private func client() throws -> EngineClient {
        if let engine { return engine }
        let created = try EngineClient()
        engine = created
        return created
    }

    func start() async {
        guard !hasStarted, !isBusy else { return }
        isBusy = true
        defer { isBusy = false; hasStarted = true }
        do {
            let result = try await client().call("bootstrap")
            let bootstrap = try JSONDecoder().decode(Bootstrap.self, from: result)
            localBudgets = bootstrap.budgets
            if let id = bootstrap.activeBudgetId {
                _ = try await client().call("open", arguments: ["id": .string(id)])
                try await loadSnapshot()
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadSnapshot() async throws {
        let result = try await client().call("snapshot", arguments: ["month": .string(month)])
        snapshot = try JSONDecoder().decode(BudgetSnapshot.self, from: result)
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await loadSnapshot(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func perform(_ method: String, arguments: [String: JSONValue] = [:]) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let switchesBudget = ["open", "download", "demo"].contains(method)
        do {
            _ = try await client().call(method, arguments: arguments)
            if switchesBudget {
                lastSyncedAt = nil
                syncStatus = "On this device"
            }
            if method == "sync" {
                lastSyncedAt = Date()
                syncStatus = "Synced with server"
            } else if method == "saveTransaction" || method == "deleteTransaction" || method == "budget" {
                syncStatus = "Saved on this device"
            }
            do { try await loadSnapshot() }
            catch {
                if switchesBudget { snapshot = nil }
                // The write succeeded. Do not invite a duplicate transaction by reporting it as unsaved.
                let action = ["open", "download", "demo"].contains(method) ? "Budget opened" : method == "sync" ? "Synced" : "Saved"
                errorMessage = "\(action), but the latest view could not load. Refresh to try again. \(error.localizedDescription)"
            }
            return true
        } catch {
            let operationError = error.localizedDescription
            if switchesBudget {
                // The bridge restores the previous budget before failing. Keep
                // the sheet and its draft alive while reloading that budget.
                // isBusy prevents writes until the engine state is confirmed.
                do { try await loadSnapshot() }
                catch { snapshot = nil; lastSyncedAt = nil; syncStatus = "On this device" }
            }
            if method == "sync" { syncStatus = "Sync needs attention" }
            errorMessage = operationError
            return false
        }
    }

    func openBudget(_ id: String) async {
        guard !isBusy else { return }
        // A failed open must not display a different budget's stale figures.
        snapshot = nil
        _ = await perform("open", arguments: ["id": .string(id)])
    }

    @discardableResult
    func connect(url: String, password: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
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
        defer { isBusy = false }
        do {
            _ = try await client().call("close")
            // The engine is closed even if the subsequent budget listing fails.
            snapshot = nil
            lastSyncedAt = nil
            syncStatus = "On this device"
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
