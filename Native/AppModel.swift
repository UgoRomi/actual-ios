import Foundation
import Observation

/// Parts of the open budget. Each loads separately, so a change reloads only what it affects.
enum BudgetPart: CaseIterable, Sendable {
    case overview, month, register
    static let all = Set(allCases)
}

@MainActor @Observable
final class AppModel {
    private var engine: EngineClient?
    private var engineTask: Task<EngineClient, Error>?
    var overview: BudgetOverview?
    var budget: BudgetMonth?
    var transactions: [Transaction] = []
    var localBudgets: [BudgetFile] = []
    var serverBudgets: [BudgetFile] = []
    var selectedMonth = Date()
    var isBusy = false
    var isOpeningBudget = false
    var isSyncingBudget = false
    /// The opening sync is holding the saved budget back; the user may continue without it.
    var isAwaitingOpeningSync = false
    var syncErrorMessage: String?
    var hasStarted = false
    var errorMessage: String?
    var syncStatus = "On this device"
    var lastSyncedAt: Date?
    var syncingAccountIDs: Set<String> = []
    var bankSyncResult: BankSyncResult?
    var bankSyncErrorMessage: String?
    var bankSyncAccountID: String?
    var reconciliation: Reconciliation?
    private var syncTask: Task<Bool, Never>?
    private var syncRequested = false
    private var budgetGeneration = 0
    private var loadRequests: [BudgetPart: Int] = [:]
    private var needsForegroundSync = false
    private var isAppActive = true
    @ObservationIgnored private var openingSyncWait: CheckedContinuation<Void, Never>?
    private var openingSyncWaits = 0

    /// Returning to the app this soon after a successful sync skips the opening sync.
    static let recentSyncInterval: TimeInterval = 5 * 60

    init(engine: EngineClient? = nil) { self.engine = engine }

    var month: String { BudgetDate.month(selectedMonth) }
    var currency: String { overview?.currencyCode ?? "" }
    var canSyncBudget: Bool { overview?.cloudFileId != nil }
    var isBudgetOpen: Bool { overview != nil }

    /// Loading the engine takes a moment, so it happens off the main thread.
    private func client() async throws -> EngineClient {
        if let engine { return engine }
        let task = engineTask ?? Task { try await EngineClient.create() }
        engineTask = task
        do {
            let created = try await task.value
            engine = created
            return created
        } catch {
            engineTask = nil
            throw error
        }
    }

    func start() async {
        guard !hasStarted, !isBusy else { return }
        isBusy = true
        isOpeningBudget = true
        defer { hasStarted = true; finishOperation() }
        do {
            let bootstrap = try await client().call("bootstrap", as: Bootstrap.self)
            localBudgets = bootstrap.budgets
            if let id = bootstrap.activeBudgetId {
                _ = try await client().call("open", arguments: ["id": .string(id)])
                try await load()
                await awaitOpeningSync()
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    /// Loads the requested parts concurrently and decodes them off the main thread.
    /// Drops results for another budget or month, or superseded by a newer request.
    private func load(_ parts: Set<BudgetPart> = BudgetPart.all) async throws {
        let generation = budgetGeneration, requestedMonth = month
        var tickets: [BudgetPart: Int] = [:]
        for part in parts {
            loadRequests[part, default: 0] += 1
            tickets[part] = loadRequests[part]
        }
        let engine = try await client()
        async let newOverview = parts.contains(.overview)
            ? engine.call("overview", as: BudgetOverview.self) : nil
        async let newBudget = parts.contains(.month)
            ? engine.call("budgetMonth", arguments: ["month": .string(requestedMonth)], as: BudgetMonth.self) : nil
        async let newTransactions = parts.contains(.register)
            ? engine.call("register", as: [Transaction].self) : nil
        let (loadedOverview, loadedBudget, loadedTransactions) = try await (newOverview, newBudget, newTransactions)
        guard generation == budgetGeneration else { return }
        func current(_ part: BudgetPart) -> Bool { tickets[part] == loadRequests[part] }
        if let loadedOverview, current(.overview) { overview = loadedOverview }
        if let loadedBudget, current(.month), requestedMonth == month { budget = loadedBudget }
        if let loadedTransactions, current(.register) { transactions = loadedTransactions }
    }

    private func clearBudget() {
        overview = nil
        budget = nil
        transactions = []
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
        guard canSyncBudget, !syncedRecently else { return }
        isBusy = true
        isOpeningBudget = true
        defer { finishOperation() }
        await awaitOpeningSync()
    }

    /// A sync succeeded a few minutes ago, and nothing has failed or started since.
    private var syncedRecently: Bool {
        guard let lastSyncedAt, syncErrorMessage == nil, syncTask == nil else { return false }
        return Date().timeIntervalSince(lastSyncedAt) < Self.recentSyncInterval
    }

    /// Waits for the opening sync, unless the user continues with the saved budget.
    private func awaitOpeningSync() async {
        guard let task = beginBudgetSync() else { return }
        openingSyncWaits += 1
        let wait = openingSyncWaits
        await withCheckedContinuation { continuation in
            openingSyncWait = continuation
            isAwaitingOpeningSync = true
            Task {
                _ = await task.value
                // A later wait may have replaced this one after Continue offline.
                if wait == openingSyncWaits { finishOpeningSyncWait() }
            }
        }
    }

    /// Shows the saved budget now. The sync continues in the background and
    /// refreshes the view when it finishes, as it does after an edit.
    func continueOffline() { finishOpeningSyncWait() }

    private func finishOpeningSyncWait() {
        isAwaitingOpeningSync = false
        openingSyncWait?.resume()
        openingSyncWait = nil
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
            do { try await load() }
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

    func refresh(_ parts: Set<BudgetPart> = BudgetPart.all) async {
        guard !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do { try await load(parts); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func refreshAccounts(accountID: String? = nil) async {
        guard !isBusy else { return }
        let accounts = overview?.accounts.filter { $0.canSyncBank && (accountID == nil || $0.id == accountID) } ?? []
        guard !accounts.isEmpty else { await refresh(); return }
        isBusy = true
        syncingAccountIDs = Set(accounts.map(\.id))
        bankSyncAccountID = accountID
        bankSyncResult = nil
        bankSyncErrorMessage = nil
        errorMessage = nil
        defer { syncingAccountIDs = []; finishOperation() }
        // Like Actual, sync the budget first so imports can match transactions
        // that other devices already imported, instead of duplicating them.
        if let budgetSync = beginBudgetSync(), await !budgetSync.value {
            bankSyncErrorMessage = "Your budget must sync before a bank refresh, so imports are not duplicated. Check your connection and try again."
            return
        }
        do {
            let arguments: [String: JSONValue] = accountID.map { ["accountId": .string($0)] } ?? [:]
            bankSyncResult = try await client().call("syncAccounts", arguments: arguments, as: BankSyncResult.self)
            // Even a partial refresh can save imports and connection status locally.
            if bankSyncResult?.accounts.isEmpty == false { syncStatus = "Saved on this device" }
        } catch { bankSyncErrorMessage = error.localizedDescription }
        // A failure may follow successful imports. Always reload the saved state.
        do { try await load() }
        catch { errorMessage = "The latest view could not load. Refresh to try again. \(error.localizedDescription)" }
        if bankSyncResult?.accounts.isEmpty == false { beginBudgetSync() }
    }

    /// Bank refresh results and reconciliation belong to the open budget.
    private func clearAccountState() {
        bankSyncResult = nil
        bankSyncErrorMessage = nil
        bankSyncAccountID = nil
        reconciliation = nil
    }

    @discardableResult
    func perform(_ method: String, arguments: [String: JSONValue] = [:]) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { finishOperation() }
        let switchesBudget = ["open", "download", "demo"].contains(method)
        let isEdit = ["saveTransaction", "deleteTransaction", "budget", "setCleared", "unlockTransaction",
                      "createReconciliationTransaction", "finishReconciliation"].contains(method)
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
                clearAccountState()
                resetBudgetSyncState()
            }
            if isEdit { syncStatus = "Saved on this device" }
            // An allocation changes only the month. Cleared and reconciled
            // states change only balances and the register. Other transaction
            // changes also affect the month and payees.
            let parts: Set<BudgetPart> = switch method {
            case "budget": [.month]
            case "setCleared", "unlockTransaction", "finishReconciliation": [.overview, .register]
            default: BudgetPart.all
            }
            do { try await load(parts) }
            catch {
                if switchesBudget { clearBudget() }
                // The write succeeded. Do not invite a duplicate transaction by reporting it as unsaved.
                let action = switchesBudget ? "Budget opened" : "Saved"
                errorMessage = "\(action), but the latest view could not load. Refresh to try again. \(error.localizedDescription)"
            }
            if switchesBudget { await awaitOpeningSync() }
            else if isEdit { beginBudgetSync() }
            return true
        } catch {
            let operationError = error.localizedDescription
            if switchesBudget {
                // The bridge restores the previous budget before failing. Keep
                // the sheet and its draft alive while reloading that budget.
                // isBusy prevents writes until the engine state is confirmed.
                do { try await load() }
                catch { clearBudget(); resetBudgetSyncState(); clearAccountState() }
            }
            errorMessage = operationError
            return false
        }
    }

    /// Accept that another device's discarded changes may show different
    /// values here, as Actual does, and resume edits and sync.
    func acknowledgeSyncWarning() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { finishOperation() }
        do {
            _ = try await client().call("acknowledgeSyncWarning")
            try await load([.overview])
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        beginBudgetSync()
    }

    func startReconciliation(accountID: String, targetBalance: Int) {
        reconciliation = Reconciliation(accountID: accountID, targetBalance: targetBalance)
    }

    /// Adds a cleared transaction for the difference from the bank balance.
    func createReconciliationTransaction() async {
        guard let reconciliation else { return }
        await perform("createReconciliationTransaction", arguments: [
            "accountId": .string(reconciliation.accountID), "targetBalance": .number(reconciliation.targetBalance),
        ])
    }

    /// Ends reconciliation. As in Actual, cleared transactions are locked only
    /// when they match the bank balance, and the time is recorded either way.
    func finishReconciliation(lock: Bool) async {
        guard let current = reconciliation else { return }
        let finished = await perform("finishReconciliation", arguments: [
            "accountId": .string(current.accountID), "targetBalance": .number(current.targetBalance),
            "lock": .bool(lock),
        ])
        if finished && reconciliation == current { reconciliation = nil }
    }

    func openBudget(_ id: String) async {
        guard !isBusy else { return }
        _ = await perform("open", arguments: ["id": .string(id)])
    }

    /// The server's sign-in methods, or nil after reporting why they could not load.
    func loginOptions(url: String) async -> LoginOptions? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { finishOperation() }
        do {
            let options = try await client().call("loginMethods", arguments: ["url": .string(url)], as: LoginOptions.self)
            errorMessage = nil
            return options
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult
    func connect(url: String, password: String) async -> Bool {
        await connect { engine in
            try await engine.call(
                "connect", arguments: ["url": .string(url), "password": .string(password)], as: BudgetListing.self)
        }
    }

    /// Signs in through the server's OpenID provider. `authenticate` shows the
    /// provider's page and returns the address it finishes on, or nil if cancelled.
    /// Actual asks for the server password only before its first OpenID sign-in.
    @discardableResult
    func connectWithOpenID(
        url: String, password: String, authenticate: (URL) async throws -> URL?
    ) async -> Bool {
        await connect { engine in
            let start = try await engine.call("openIdSignIn", arguments: [
                "url": .string(url), "password": .string(password), "returnUrl": .string(OpenIDCallback.returnURL),
            ], as: OpenIDStart.self)
            guard let provider = URL(string: start.url), ["https", "http"].contains(provider.scheme?.lowercased() ?? "")
            else { throw EngineFailure("Your server returned an invalid sign-in address.") }
            guard let callback = try await authenticate(provider) else { return nil }
            guard let token = OpenIDCallback.token(from: callback)
            else { throw EngineFailure("OpenID sign-in did not finish. Try again.") }
            return try await engine.call(
                "connect", arguments: ["url": .string(url), "token": .string(token)], as: BudgetListing.self)
        }
    }

    /// Signs in and lists the server's budgets. `signIn` returns nil if the person cancels.
    private func connect(_ signIn: (EngineClient) async throws -> BudgetListing?) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { finishOperation() }
        _ = await syncTask?.value
        let previousBudgets = serverBudgets
        serverBudgets = []
        do {
            guard let listing = try await signIn(client()) else {
                serverBudgets = previousBudgets
                errorMessage = nil
                return false
            }
            serverBudgets = listing.budgets
            errorMessage = nil
            syncStatus = "Connected to server"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func moveMonth(_ offset: Int) async {
        guard !isBusy, let newMonth = Calendar(identifier: .gregorian).date(byAdding: .month, value: offset, to: selectedMonth) else { return }
        let previousMonth = selectedMonth
        selectedMonth = newMonth
        await refresh([.month])
        if budget?.month != month { selectedMonth = previousMonth }
    }

    func closeBudget() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { finishOperation() }
        _ = await syncTask?.value
        do {
            _ = try await client().call("close")
            // The engine is closed even if the subsequent budget listing fails.
            clearBudget()
            clearAccountState()
            resetBudgetSyncState()
            do {
                localBudgets = try await client().call("bootstrap", as: Bootstrap.self).budgets
                errorMessage = nil
            } catch {
                errorMessage = "Budget closed, but saved budgets could not be loaded. Tap Try again to reload them. \(error.localizedDescription)"
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// Removes a budget's copy on this device, as Actual's "Delete file locally"
    /// does. A server budget stays on the server and can be downloaded again.
    @discardableResult
    func deleteBudget(_ id: String) async -> Bool {
        guard !isBusy, !isBudgetOpen else { return false }
        isBusy = true
        defer { finishOperation() }
        _ = await syncTask?.value
        do {
            let listing = try await client().call("deleteBudget", arguments: ["id": .string(id)], as: BudgetListing.self)
            // The engine closes a budget that is open without a loaded view.
            clearBudget()
            clearAccountState()
            resetBudgetSyncState()
            localBudgets = listing.budgets
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
