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
