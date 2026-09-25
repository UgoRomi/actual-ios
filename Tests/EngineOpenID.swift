import Foundation

private struct Fixture: Decodable {
  let url: String
  let password: String
  let encryptionPassword: String
  let syncId: String
  let accountId: String
}

/// Stops at each redirect so the harness can follow them like a browser.
private final class ManualRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? { nil }
}

@main struct EngineOpenID {
  @MainActor static func main() async throws {
    let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    let fixture = try JSONDecoder().decode(
      Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
    let url = fixture.url
    let engine = try EngineClient(
      dataDirectory: directory.appendingPathComponent("openid"), resourceDirectory: resources,
      useKeychain: false)
    let model = AppModel(engine: engine)

    guard let options = await model.loginOptions(url: url) else {
      throw EngineFailure(model.errorMessage ?? "Sign-in options did not load")
    }
    precondition(options.methods == [.openid, .password], "\(options.methods)")
    precondition(!options.ownerCreated)
    print("PASS: server offers its active OpenID method first, then password, before an owner exists")

    // Actual confirms the server password before the first OpenID sign-in.
    var opened = false
    let skip: (URL) async throws -> URL? = { _ in opened = true; return nil }
    var connected = await model.connectWithOpenID(url: url, password: "", authenticate: skip)
    precondition(!connected && !opened)
    precondition(model.errorMessage == "Enter the server password to confirm the first OpenID sign-in.")
    connected = await model.connectWithOpenID(url: url, password: "incorrect", authenticate: skip)
    precondition(!connected && !opened && model.errorMessage == "The server password is incorrect.")
    // Cancelling on the provider's page reports nothing and connects nothing.
    connected = await model.connectWithOpenID(url: url, password: fixture.password, authenticate: skip)
    precondition(!connected && opened && model.errorMessage == nil && model.serverBudgets.isEmpty)
    connected = await model.connectWithOpenID(url: url, password: fixture.password) { _ in
      URL(string: "\(OpenIDCallback.returnURL)/openid-cb")
    }
    precondition(!connected && model.errorMessage == "OpenID sign-in did not finish. Try again.")
    do {
      _ = try await engine.call(
        "connect", arguments: ["url": .string(url), "token": .string("not-a-session")])
      throw EngineFailure("An unknown session token was accepted")
    } catch {
      precondition(error.localizedDescription == "Your server did not accept this sign-in. Try again.")
    }
    print("PASS: first sign-in needs the server password; cancelled, unfinished and unknown sessions are rejected")

    connected = await model.connectWithOpenID(url: url, password: fixture.password, authenticate: browse)
    precondition(connected, model.errorMessage ?? "")
    precondition(model.serverBudgets.contains { $0.id == fixture.syncId })
    print("PASS: the server returns the OpenID session to the app, which lists the new owner's budgets")

    let downloaded = await model.perform(
      "download",
      arguments: ["syncId": .string(fixture.syncId), "password": .string(fixture.encryptionPassword)])
    precondition(downloaded, model.errorMessage ?? "")
    precondition(model.overview?.accounts.first { $0.id == fixture.accountId }?.balance == 100000)
    let synced = await model.perform("sync")
    precondition(synced, model.syncErrorMessage ?? "")
    print("PASS: the OpenID session downloads and syncs the encrypted budget")

    let later = await model.loginOptions(url: url)
    precondition(later?.ownerCreated == true)
    connected = await model.connectWithOpenID(url: url, password: "", authenticate: browse)
    precondition(connected, model.errorMessage ?? "")
    print("PASS: later OpenID sign-ins need no server password")

    // Actual keeps password sign-in unless the server enforces OpenID.
    let passwordModel = AppModel(
      engine: try EngineClient(
        dataDirectory: directory.appendingPathComponent("password"), resourceDirectory: resources,
        useKeychain: false))
    connected = await passwordModel.connect(url: url, password: fixture.password)
    precondition(connected, passwordModel.errorMessage ?? "")
    precondition(passwordModel.serverBudgets.contains { $0.id == fixture.syncId })
    print("PASS: password sign-in still lists the budgets while OpenID is active")
  }

  /// A browser on which the provider approves at once: follows redirects until
  /// the server sends it to the app's return address.
  static func browse(_ start: URL) async throws -> URL? {
    let session = URLSession(
      configuration: .ephemeral, delegate: ManualRedirects(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var url = start
    for _ in 0..<5 {
      let (_, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
        let location = http.value(forHTTPHeaderField: "Location"),
        let next = URL(string: location, relativeTo: url)?.absoluteURL
      else { throw EngineFailure("Sign-in stopped at \(url)") }
      if next.scheme == OpenIDCallback.scheme { return next }
      url = next
    }
    throw EngineFailure("Sign-in redirected too many times")
  }
}
