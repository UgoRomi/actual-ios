import SwiftUI

/// Actual's schedules: upcoming bills and income, with the schedules table's actions.
struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var schedules: [Schedule] = []
    @State private var loadError: String?
    @State private var search = ""
    @State private var showsCompleted = false
    @State private var editing: ScheduleEditRoute?
    @State private var deleting: Schedule?

    private var shown: [Schedule] {
        schedules.filter { schedule in
            guard showsCompleted || !schedule.completed else { return false }
            guard !search.isEmpty else { return true }
            return [schedule.name, payeeName(schedule), accountName(schedule), amountText(schedule),
                    ScheduleStatusBadge.label(schedule.status)]
                .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted { ($0.nextDate ?? "9999") < ($1.nextDate ?? "9999") }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage ?? loadError {
                    Section { ErrorNotice(message: error) { Task { await load() } } }
                }
                if shown.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No schedules" : "No matching schedules",
                                           systemImage: "calendar.badge.clock",
                                           description: Text(search.isEmpty
                                                             ? "Add a schedule for bills and income that repeat."
                                                             : "Try a different name, payee, or amount."))
                }
                ForEach(shown) { schedule in
                    Button { editing = ScheduleEditRoute(schedule: schedule) } label: { row(schedule) }
                        .buttonStyle(.plain)
                        .contextMenu { actions(schedule) }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = schedule }
                        }
                }
                if schedules.contains(where: \.completed) {
                    Section {
                        Toggle("Show completed schedules", isOn: $showsCompleted)
                    }
                }
                Section { SyncFooter() }.listRowBackground(Color.clear)
            }
            .navigationTitle("Schedules")
            .searchable(text: $search, prompt: "Name, payee, account, or amount")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add schedule", systemImage: "plus") { editing = ScheduleEditRoute(schedule: nil) }
                        .disabled(model.isBusy)
                }
                ToolbarItem(placement: .topBarTrailing) { upcomingMenu }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .refreshable { await model.refresh(); await load() }
            .task(id: model.dataRevision) { await load() }
            .sheet(item: $editing) { route in ScheduleEditor(schedule: route.schedule) }
            .confirmationDialog("Delete this schedule?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible,
                                presenting: deleting) { schedule in
                Button("Delete Schedule", role: .destructive) { run("deleteSchedule", schedule) }
            } message: { _ in Text("Transactions it already added stay in your accounts.") }
        }
    }

    /// Actual's upcoming length: how far ahead registers list scheduled transactions.
    private var upcomingMenu: some View {
        Menu("Upcoming", systemImage: "calendar.day.timeline.right") {
            Picker("Show upcoming transactions for", selection: Binding(
                get: { model.overview?.format?.upcomingLength ?? "7" },
                set: { value in
                    Task { await model.manage("savePreference", ["id": .string("upcomingScheduledTransactionLength"),
                                                                 "value": .string(value)]) }
                })) {
                Text("1 day").tag("1")
                Text("1 week").tag("7")
                Text("2 weeks").tag("14")
                Text("1 month").tag("oneMonth")
                Text("End of the current month").tag("currentMonth")
            }
        }
        .disabled(model.isBusy)
    }

    private func load() async {
        do {
            schedules = try await model.schedules()
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    /// Actual's schedules table menu.
    @ViewBuilder private func actions(_ schedule: Schedule) -> some View {
        if schedule.status == .completed {
            Button("Restart", systemImage: "arrow.clockwise") { run("completeSchedule", schedule, ["completed": .bool(false)]) }
        } else {
            Button("Post Transaction", systemImage: "plus.circle") { run("postSchedule", schedule) }
            Button("Post Transaction Today", systemImage: "calendar.badge.plus") {
                run("postSchedule", schedule, ["today": .bool(true)])
            }
            Button("Skip Next Date", systemImage: "forward") { run("skipSchedule", schedule) }
            Button("Complete", systemImage: "checkmark.circle") { run("completeSchedule", schedule, ["completed": .bool(true)]) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = schedule }
    }

    private func run(_ method: String, _ schedule: Schedule, _ extra: [String: JSONValue] = [:]) {
        var arguments = extra
        arguments["id"] = .string(schedule.id)
        Task { if await model.manage(method, arguments) { await load() } }
    }

    private func payeeName(_ schedule: Schedule) -> String? {
        schedule.payeeId.flatMap { id in model.overview?.payees.first { $0.id == id }?.name }
    }
    private func accountName(_ schedule: Schedule) -> String? {
        schedule.accountId.flatMap { id in model.overview?.accounts.first { $0.id == id }?.name }
    }
    /// As Actual's schedules list: "~" for approximate, "+" for income, payments without a sign.
    private func amountText(_ schedule: Schedule) -> String {
        func signed(_ value: Int) -> String {
            (value > 0 ? "+" : "") + Money.formatted(abs(value), currency: model.currency)
        }
        switch schedule.amount {
        case .exact(let value): return (schedule.amountOp == .isapprox ? "~" : "") + signed(value)
        case .range(let low, let high): return "\(signed(low)) to \(signed(high))"
        }
    }

    private func row(_ schedule: Schedule) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(schedule.name ?? payeeName(schedule) ?? "Unnamed schedule").font(.body.weight(.medium))
                Text([payeeName(schedule).flatMap { $0 == schedule.name ? nil : $0 }, accountName(schedule)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ScheduleStatusBadge(status: schedule.status)
                    if let next = schedule.nextDate {
                        Text(BudgetDate.display(next)).font(.caption).foregroundStyle(.secondary)
                    }
                    if case .recurring = schedule.date {
                        Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Repeats")
                    }
                }
            }
            Spacer(minLength: 8)
            Text(amountText(schedule)).monospacedDigit().font(.body.weight(.semibold))
                .foregroundStyle(schedule.amount.scheduled > 0 ? Color.green : Color.primary)
        }.padding(.vertical, 4).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

struct ScheduleEditRoute: Identifiable {
    let id = UUID()
    let schedule: Schedule?
}

/// A schedule's status, colored as Actual's status badges.
struct ScheduleStatusBadge: View {
    let status: Schedule.Status

    static func label(_ status: Schedule.Status) -> String {
        switch status {
        case .completed: "Completed"
        case .paid: "Paid"
        case .due: "Due"
        case .upcoming: "Upcoming"
        case .missed: "Missed"
        case .scheduled: "Scheduled"
        }
    }

    var body: some View {
        let color: Color = switch status {
        case .missed: .red
        case .due: .orange
        case .upcoming: ActualTheme.purple
        case .paid: .green
        case .completed, .scheduled: .secondary
        }
        Text(Self.label(status)).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}

/// Creates or edits a schedule, as Actual's schedule editor does.
struct ScheduleEditor: View {
    let schedule: Schedule?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var payee = ""
    @State private var noTransfer = ""
    @State private var account = ""
    @State private var isOutflow = true
    @State private var amountOp = Schedule.AmountOp.isapprox
    @State private var amount = ""
    @State private var highAmount = ""
    @State private var start = Date()
    @State private var repeats = true
    @State private var recurrence = ScheduleDate.Recurrence(start: BudgetDate.day(Date()), frequency: .monthly)
    @State private var endDate = Date()
    @State private var postsTransaction = false
    @State private var upcoming: [String] = []
    @State private var validation: String?
    @State private var confirmsDelete = false
    @State private var initialized = false

    private var date: ScheduleDate {
        guard repeats else { return .once(BudgetDate.day(start)) }
        var value = recurrence
        value.start = BudgetDate.day(start)
        value.endDate = value.endMode == .onDate ? BudgetDate.day(endDate) : value.endDate
        return .recurring(value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Optional, such as Rent"))
                        .accessibilityLabel("Name")
                    NavigationLink {
                        PayeePicker(selection: $payee, transferAccount: $noTransfer,
                                    payees: model.overview?.payees ?? [], accounts: [])
                    } label: { LabeledContent("Payee", value: payee.isEmpty ? "None" : payee) }
                    Picker("Account", selection: $account) {
                        Text("None").tag("")
                        ForEach(model.overview?.openAccounts ?? []) { Text($0.name).tag($0.id) }
                    }
                } footer: { Text("Without an account, a schedule can’t add its transactions.") }
                Section("Amount") {
                    Picker("Type", selection: $isOutflow) {
                        Text("Payment").tag(true)
                        Text("Deposit").tag(false)
                    }.pickerStyle(.segmented)
                    Picker("Matches", selection: $amountOp) {
                        Text("Exactly").tag(Schedule.AmountOp.is)
                        Text("Approximately").tag(Schedule.AmountOp.isapprox)
                        Text("Between").tag(Schedule.AmountOp.isbetween)
                    }
                    AmountField(label: amountOp == .isbetween ? "From" : "Amount", text: $amount)
                    if amountOp == .isbetween { AmountField(label: "To", text: $highAmount) }
                }
                Section {
                    DatePicker(repeats ? "Starts" : "Date", selection: $start, displayedComponents: .date)
                    Toggle("Repeats", isOn: $repeats)
                    if repeats {
                        Stepper(recurrence.interval == 1 ? "Every \(unit)" : "Every \(recurrence.interval) \(unit)",
                                value: $recurrence.interval, in: 1...365)
                        Picker("Frequency", selection: $recurrence.frequency) {
                            Text("Daily").tag(ScheduleDate.Recurrence.Frequency.daily)
                            Text("Weekly").tag(ScheduleDate.Recurrence.Frequency.weekly)
                            Text("Monthly").tag(ScheduleDate.Recurrence.Frequency.monthly)
                            Text("Yearly").tag(ScheduleDate.Recurrence.Frequency.yearly)
                        }
                        Picker("Ends", selection: $recurrence.endMode) {
                            Text("Never").tag(ScheduleDate.Recurrence.EndMode.never)
                            Text("After a number of times").tag(ScheduleDate.Recurrence.EndMode.afterOccurrences)
                            Text("On a date").tag(ScheduleDate.Recurrence.EndMode.onDate)
                        }
                        if recurrence.endMode == .afterOccurrences {
                            Stepper("\(recurrence.endOccurrences) times", value: $recurrence.endOccurrences, in: 1...999)
                        } else if recurrence.endMode == .onDate {
                            DatePicker("End date", selection: $endDate, displayedComponents: .date)
                        }
                        Toggle("Move off weekends", isOn: $recurrence.skipWeekend)
                        if recurrence.skipWeekend {
                            Picker("Move to", selection: $recurrence.weekendSolveMode) {
                                Text("Friday before").tag(ScheduleDate.Recurrence.WeekendMode.before)
                                Text("Monday after").tag(ScheduleDate.Recurrence.WeekendMode.after)
                            }
                        }
                    }
                } header: { Text("Date") }
                if repeats && recurrence.frequency == .monthly {
                    // As Actual's date editor: repeat on days of the month, or the nth weekday.
                    Section {
                        ForEach(recurrence.specificDays.indices, id: \.self) { index in
                            HStack {
                                Picker("Which", selection: Binding(
                                    get: { recurrence.specificDays[safe: index]?.value ?? 1 },
                                    set: { value in recurrence.specificDays[index].value = value })) {
                                    Text("Last").tag(-1)
                                    ForEach(1...31, id: \.self) { Text(ordinal($0)).tag($0) }
                                }.labelsHidden()
                                Picker("Day", selection: Binding(
                                    get: { recurrence.specificDays[safe: index]?.type ?? "day" },
                                    set: { type in recurrence.specificDays[index].type = type })) {
                                    Text("Day").tag("day")
                                    ForEach(Array(ScheduleDate.Recurrence.Pattern.weekdays.enumerated()), id: \.element) { index, day in
                                        Text(Calendar(identifier: .gregorian).weekdaySymbols[index]).tag(day)
                                    }
                                }.labelsHidden()
                            }
                        }
                        .onDelete { recurrence.specificDays.remove(atOffsets: $0) }
                        Button("Add Specific Day", systemImage: "plus") {
                            recurrence.specificDays.append(.init(type: "day", value: Calendar.current.component(.day, from: start)))
                        }
                    } header: { Text("Specific days") } footer: {
                        Text(recurrence.specificDays.isEmpty
                             ? "Repeats on the start date’s day. Add days such as the 1st and 15th, or the last Friday."
                             : "Swipe to remove a day.")
                    }
                }
                if let schedule {
                    Section {
                        NavigationLink { ScheduleTransactionsView(schedule: schedule) } label: {
                            Label("Linked Transactions", systemImage: "link")
                        }
                    } footer: { Text("Link transactions that paid this schedule, as Actual does when they match.") }
                }
                if !upcoming.isEmpty {
                    Section("Next dates") {
                        ForEach(upcoming, id: \.self) { day in
                            if let parsed = BudgetDate.date(day) {
                                Text(parsed, format: .dateTime.weekday(.wide).month(.wide).day().year())
                            }
                        }
                    }
                }
                Section {
                    Toggle("Automatically add transaction", isOn: $postsTransaction)
                } footer: {
                    Text("On each date, Actual adds the transaction for you. Otherwise it waits for a matching transaction.")
                }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let error = model.errorMessage { Section { ErrorNotice(message: error) } }
                if schedule != nil {
                    Section { Button("Delete Schedule", role: .destructive) { confirmsDelete = true } }
                }
            }
            .disabled(model.isBusy)
            .navigationTitle(schedule == nil ? "New Schedule" : "Schedule").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).bold() }
            }
            .confirmationDialog("Delete this schedule?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Schedule", role: .destructive) {
                    guard let schedule else { return }
                    Task { if await model.manage("deleteSchedule", ["id": .string(schedule.id)]) { dismiss() } }
                }
            } message: { Text("Transactions it already added stay in your accounts.") }
            .onAppear(perform: initialize)
            .task(id: "\(date)") {
                upcoming = (try? await model.upcomingDates(date)) ?? []
            }
        }
    }

    private func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: number as NSNumber) ?? String(number)
    }

    private var unit: String {
        let unit = switch recurrence.frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
        return recurrence.interval == 1 ? unit : unit + "s"
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        guard let schedule else {
            account = model.overview?.openAccounts.first?.id ?? ""
            return
        }
        name = schedule.name ?? ""
        payee = schedule.payeeId.flatMap { id in model.overview?.payees.first { $0.id == id }?.name } ?? ""
        account = schedule.accountId ?? ""
        amountOp = schedule.amountOp
        switch schedule.amount {
        case .exact(let value):
            isOutflow = value <= 0
            amount = Money.editable(abs(value))
        case .range(let low, let high):
            isOutflow = low + high <= 0
            amount = Money.editable(abs(isOutflow ? high : low))
            highAmount = Money.editable(abs(isOutflow ? low : high))
        }
        postsTransaction = schedule.postsTransaction
        switch schedule.date {
        case .once(let day):
            repeats = false
            start = BudgetDate.date(day) ?? Date()
        case .recurring(let value):
            repeats = true
            recurrence = value
            start = BudgetDate.date(value.start) ?? Date()
            endDate = value.endDate.flatMap(BudgetDate.date) ?? start
        }
    }

    private func save() {
        func cents(_ text: String) -> Int? { Money.parse(text).flatMap { $0 >= 0 ? (isOutflow ? -$0 : $0) : nil } }
        guard let first = cents(amount) else { validation = "A valid amount is required"; return }
        var arguments: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "accountId": account.isEmpty ? .null : .string(account),
            "amountOp": .string(amountOp.rawValue),
            "date": date.json,
            "postsTransaction": .bool(postsTransaction),
        ]
        if amountOp == .isbetween {
            guard let second = cents(highAmount) else { validation = "A valid amount is required"; return }
            arguments["amount"] = ScheduleAmount.range(min(first, second), max(first, second)).json
        } else {
            arguments["amount"] = .number(first)
        }
        if repeats, recurrence.endMode == .onDate, endDate < start {
            validation = "Choose an end date after the start."
            return
        }
        let cleanedPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = model.overview?.payees.first(where: { $0.name == cleanedPayee }) {
            arguments["payeeId"] = .string(match.id)
        } else if !cleanedPayee.isEmpty {
            arguments["payeeName"] = .string(cleanedPayee)
        }
        if let schedule { arguments["id"] = .string(schedule.id) }
        validation = nil
        Task { if await model.manage("saveSchedule", arguments) { dismiss() } }
    }
}

/// A schedule's linked transactions, and ones its conditions match, to link or unlink.
private struct ScheduleTransactionsView: View {
    let schedule: Schedule
    @Environment(AppModel.self) private var model
    @State private var transactions: ScheduleTransactions?
    @State private var loadError: String?

    var body: some View {
        List {
            if let error = model.errorMessage ?? loadError { Section { ErrorNotice(message: error) } }
            if let transactions {
                Section {
                    if transactions.linked.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(transactions.linked) { item in
                        row(item).swipeActions {
                            Button("Unlink", systemImage: "link.badge.minus") { link(item, false) }.tint(.orange)
                        }
                    }
                } header: { Text("Linked") } footer: {
                    if !transactions.linked.isEmpty { Text("Swipe to unlink.") }
                }
                Section {
                    if transactions.matching.isEmpty { Text("No other transactions match").foregroundStyle(.secondary) }
                    ForEach(transactions.matching) { item in
                        Button { link(item, true) } label: {
                            HStack { row(item); Image(systemName: "link.badge.plus").foregroundStyle(ActualTheme.purple) }
                        }.buttonStyle(.plain)
                    }
                } header: { Text("Matching") } footer: {
                    Text("Transactions with this schedule’s payee, account, and amount. Tap one to link it.")
                }
            } else if loadError == nil {
                ProgressView()
            }
        }
        .disabled(model.isBusy)
        .navigationTitle("Linked Transactions").navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataRevision) { await load() }
    }

    private func row(_ item: ScheduleTransactions.Item) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.payeeId.flatMap { id in model.overview?.payees.first { $0.id == id }?.name } ?? "No payee")
                Text([BudgetDate.display(item.date),
                      item.accountId.flatMap { id in model.overview?.accounts.first { $0.id == id }?.name }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(value: item.amount, currency: model.currency, positiveColor: .green)
        }
    }

    private func load() async {
        do { transactions = try await model.scheduleTransactions(schedule.id); loadError = nil }
        catch { loadError = error.localizedDescription }
    }

    private func link(_ item: ScheduleTransactions.Item, _ link: Bool) {
        Task {
            if await model.manage("linkScheduleTransactions", [
                "id": .string(schedule.id), "transactionIds": .array([.string(item.id)]), "link": .bool(link),
            ]) { await load() }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
