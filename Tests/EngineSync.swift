import Foundation

private struct Fixture: Decodable {
  let url: String
  let password: String
  let encryptionPassword: String
  let syncId: String
  let accountId: String
  let ruleAccountId: String
  let transferAccountId: String
  let categoryId: String
}
@main struct EngineSync {
  static func main() async throws {
    let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    let fixture = try JSONDecoder().decode(
      Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
    let phase = CommandLine.arguments[4]
    let engine = try EngineClient(
      dataDirectory: directory, resourceDirectory: resources, useKeychain: false)
    _ = try await engine.call("bootstrap")
    if phase == "download" {
      do {
        _ = try await engine.call(
          "connect",
          arguments: ["url": .string(fixture.url), "password": .string("incorrect-test-password")])
        throw EngineFailure("Incorrect server password was accepted")
      } catch { precondition(!error.localizedDescription.contains("was accepted")) }
      _ = try await engine.call(
        "connect", arguments: ["url": .string(fixture.url), "password": .string(fixture.password)])
      do {
        _ = try await engine.call(
          "download",
          arguments: [
            "syncId": .string(fixture.syncId), "password": .string("incorrect-encryption-password"),
          ])
        throw EngineFailure("Incorrect encryption password was accepted")
      } catch { precondition(!error.localizedDescription.contains("was accepted")) }
      _ = try await engine.call(
        "download",
        arguments: [
          "syncId": .string(fixture.syncId), "password": .string(fixture.encryptionPassword),
        ])
      let snapshot = try await snapshot(engine)
      precondition(
        snapshot.accounts.first(where: { $0.id == fixture.accountId })?.balance == 100000)
      _ = try await engine.call(
        "saveTransaction",
        arguments: [
          "accountId": .string(fixture.accountId), "date": .string("2026-09-17"),
          "categoryId": .string(fixture.categoryId), "payeeName": .string("Native sync test"),
          "amount": .number(-1234), "notes": .string("native online"), "cleared": .bool(false),
        ])
      _ = try await engine.call(
        "saveTransaction",
        arguments: [
          "accountId": .string(fixture.ruleAccountId), "date": .string("2026-09-17"),
          "amount": .number(-4321), "notes": .string("native transfer rule"),
          "cleared": .bool(false),
        ])
      let afterRule = try await self.snapshot(engine)
      guard
        let ruleTransfer = afterRule.transactions.first(where: {
          $0.accountId == fixture.ruleAccountId && $0.notes == "native transfer rule"
        })
      else { throw EngineFailure("Rule transfer missing") }
      precondition(ruleTransfer.isTransfer && ruleTransfer.canEdit)
      precondition(ruleTransfer.transferAccountId == fixture.transferAccountId)
      precondition(
        afterRule.accounts.first(where: { $0.id == fixture.transferAccountId })?.balance == 4321)
      _ = try await engine.call("sync")
      let beforeFailedDownload = try await self.snapshot(engine)
      do {
        _ = try await engine.call(
          "download", arguments: ["syncId": .string("missing-native-test-budget")])
        throw EngineFailure("Missing budget download should fail")
      } catch { precondition(!error.localizedDescription.contains("should fail")) }
      let afterFailedDownload = try await self.snapshot(engine)
      precondition(afterFailedDownload.budgetName == beforeFailedDownload.budgetName)
      precondition(
        afterFailedDownload.accounts.first(where: { $0.id == fixture.accountId })?.balance == 98766)
      print("PASS: failed budget download restores the prior usable budget")
      print("PASS: wrong passwords rejected, retry succeeds, encrypted budget download/add/sync")
    } else if phase == "offline" {
      let snapshot = try await snapshot(engine)
      guard let transaction = snapshot.transactions.first(where: { $0.notes == "native online" })
      else { throw EngineFailure("No synced native transaction") }
      _ = try await engine.call(
        "saveTransaction",
        arguments: [
          "id": .string(transaction.id), "accountId": .string(fixture.accountId),
          "date": .string(transaction.date), "categoryId": .string(fixture.categoryId),
          "payeeId": .string(transaction.payeeId ?? ""), "amount": .number(-2345),
          "notes": .string("native offline restart"), "cleared": .bool(true),
        ])
      // Edit the rule-created transfer from its receiving side; Actual updates the sending side.
      guard
        let received = snapshot.transactions.first(where: {
          $0.accountId == fixture.transferAccountId && $0.transferAccountId == fixture.ruleAccountId
        })
      else { throw EngineFailure("No synced transfer") }
      _ = try await engine.call(
        "saveTransaction",
        arguments: [
          "id": .string(received.id), "accountId": .string(fixture.transferAccountId),
          "date": .string(received.date), "transferAccountId": .string(fixture.ruleAccountId),
          "categoryId": .null, "amount": .number(5000), "notes": .string("native transfer edit"),
          "cleared": .bool(false),
        ])
      let edited = try await self.snapshot(engine)
      precondition(
        edited.transactions.first(where: { $0.id == received.transferId })?.amount == -5000)
      print("PASS: encrypted budget reopened in fresh process and edited offline, including a transfer")

      // This app's other edits, which Actual's API checks after they sync.
      struct Created: Decodable { let id: String }
      func call(_ method: String, _ arguments: [String: JSONValue]) async throws -> Data {
        try await engine.call(method, arguments: arguments)
      }
      _ = try await call("budget", ["month": .string("2026-09"), "categoryId": .string(fixture.categoryId),
                                    "amount": .number(12_345)])
      let rollover = BudgetAction.rollover(category: fixture.categoryId, enabled: true)
      _ = try await call("budgetAction", ["month": .string("2026-09"), "action": .string(rollover.name),
                                         "args": .object(rollover.arguments)])
      let group = try JSONDecoder().decode(Created.self, from: try await call(
        "createCategoryGroup", ["name": .string("Native Sync Group")])).id
      let category = try JSONDecoder().decode(Created.self, from: try await call(
        "createCategory", ["groupId": .string(group), "name": .string("Native Sync Category")])).id
      _ = try await call("saveNotes", ["id": .string(category), "note": .string("native sync note")])
      // A split with a transfer part: 1,000 to the new category, 2,000 to the transfer account.
      _ = try await call("saveSplit", [
        "newId": .string(UUID().uuidString.lowercased()), "accountId": .string(fixture.accountId),
        "date": .string("2026-09-26"), "payeeName": .string("Native Sync Market"),
        "notes": .string("native sync split"), "cleared": .bool(false), "amount": .number(-3_000),
        "splits": .array([
          .object(["amount": .number(-1_000), "categoryId": .string(category), "notes": .string("native part")]),
          .object(["amount": .number(-2_000), "categoryId": .null, "notes": .string("native transfer part"),
                   "transferAccountId": .string(fixture.transferAccountId)]),
        ]),
      ])
      let market = try await self.snapshot(engine).payees.first { $0.name == "Native Sync Market" }
      _ = try await call("renamePayee", ["id": .string(market!.id), "name": .string("Native Sync Store")])
      _ = try await call("saveSchedule", [
        "name": .string("Native Sync Schedule"), "accountId": .string(fixture.accountId),
        "amount": .number(-777), "amountOp": .string("is"), "postsTransaction": .bool(false),
        "date": .object(["start": .string("2026-10-01"), "frequency": .string("monthly"), "interval": .number(1),
                         "patterns": .array([]), "skipWeekend": .bool(false), "weekendSolveMode": .string("after"),
                         "endMode": .string("never"), "endOccurrences": .number(1)]),
      ])
      _ = try await call("saveRule", [
        "stage": .null, "conditionsOp": .string("and"),
        "conditions": .array([.object(["field": .string("notes"), "op": .string("contains"), "type": .string("string"),
                                       "value": .string("native sync rule")])]),
        "actions": .array([.object(["field": .string("category"), "op": .string("set"), "type": .string("id"),
                                    "value": .string(category), "options": .object(["splitIndex": .number(0)])])]),
      ])
      _ = try await call("savePreference", ["id": .string("numberFormat"), "value": .string("dot-comma")])
      // A dashboard widget's name and interval.
      struct Board: Decodable {
        struct Page: Decodable { let widgets: [Widget] }
        struct Widget: Decodable { let id: String; let type: String }
        let pages: [Page]
      }
      let board = try JSONDecoder().decode(Board.self, from: try await call("reportsDashboard", [:]))
      guard let netWorth = board.pages.first?.widgets.first(where: { $0.type == "net-worth-card" }) else {
        throw EngineFailure("The default dashboard has a net worth widget")
      }
      _ = try await call("saveReportWidget", ["id": .string(netWorth.id), "changes": .object([
        "name": .string("Native Sync Widget"), "interval": .string("Weekly"),
      ])])
      print("PASS: budget moves, categories, notes, a split with a transfer part, a payee, a schedule, a rule, a setting, and a dashboard widget saved offline")
    } else if phase == "sync" {
      _ = try await engine.call("sync")
      let snapshot = try await snapshot(engine)
      precondition(
        snapshot.transactions.contains(where: {
          $0.notes == "native offline restart" && $0.amount == -2345
        }))
      print("PASS: offline edit survived another process restart and synced")
    } else {
      throw EngineFailure("Unknown test phase")
    }
  }
  private static func snapshot(_ engine: EngineClient) async throws -> BudgetSnapshot {
    try await BudgetSnapshot.load(engine, month: "2026-09")
  }
}
