import Foundation
import JavaScriptCore

final class EngineClient: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.actualnative.engine", qos: .userInitiated)
  private let host: NativeHost
  private var context: JSContext!
  private var pending: [String: CheckedContinuation<Data, Error>] = [:]
  private var timers: [Int: DispatchWorkItem] = [:]
  private var httpTasks: [Int: URLSessionDataTask] = [:]
  private let session: URLSession
  private let delegate = EngineNetworkDelegate()

  init(dataDirectory: URL? = nil, resourceDirectory: URL? = nil, useKeychain: Bool = true) throws {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let data =
      dataDirectory ?? applicationSupport.appendingPathComponent("ActualNative", isDirectory: true)
    guard
      let resources = resourceDirectory
        ?? Bundle.main.url(forResource: "Resources", withExtension: nil, subdirectory: "Engine")
    else { throw EngineFailure("Engine resources are missing. Run the engine build script.") }
    host = try NativeHost(
      dataDirectory: data, resourceDirectory: resources, useKeychain: useKeychain)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    // Actual permits up to five minutes for a SimpleFIN batch refresh.
    config.timeoutIntervalForResource = 300
    session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    try queue.sync { try setup() }
  }
  deinit {
    session.invalidateAndCancel()
    timers.values.forEach { $0.cancel() }
  }

  func call(_ method: String, arguments: [String: JSONValue] = [:]) async throws -> Data {
    let bytes = try JSONEncoder().encode(arguments)
    guard let string = String(data: bytes, encoding: .utf8) else {
      throw EngineFailure("Invalid command encoding")
    }
    return try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        let id = UUID().uuidString
        pending[id] = continuation
        context.exception = nil
        context.objectForKeyedSubscript("ActualBridge")?.invokeMethod(
          "request", withArguments: [id, method, string])
        if let exception = context.exception {
          pending.removeValue(forKey: id)?.resume(
            throwing: EngineFailure(exception.toString() ?? "Engine command failed"))
          context.exception = nil
        }
      }
    }
  }
  private func setup() throws {
    guard let js = JSContext() else { throw EngineFailure("JavaScriptCore could not start") }
    context = js
    let native: @convention(block) (String, String) -> String = { [weak self] operation, payload in
      guard let self else { return "{\"error\":\"Engine stopped\"}" }
      return self.respond {
        guard let data = payload.data(using: .utf8),
          let args = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw EngineFailure("Invalid native operation payload") }
        return try self.host.perform(operation, args)
      }
    }
    js.setObject(native, forKeyedSubscript: "_native" as NSString)
    let reply: @convention(block) (String, String) -> Void = { [weak self] id, payload in
      guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
      do {
        guard let data = payload.data(using: .utf8),
          let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw EngineFailure("Invalid engine response") }
        if let error = result["error"] as? String { throw EngineFailure(error) }
        let resultData = try JSONSerialization.data(
          withJSONObject: result["value"] ?? NSNull(), options: [.fragmentsAllowed])
        continuation.resume(returning: resultData)
      } catch { continuation.resume(throwing: error) }
    }
    js.setObject(reply, forKeyedSubscript: "_reply" as NSString)
    let register: @convention(block) (Int, String, Int, JSValue) -> Void = {
      [weak self] id, name, arity, callback in
      guard let self else { return }
      do {
        try self.host.sqlite.register(id: id, name: name, arity: arity, callback: callback)
      } catch {
        self.context.exception = JSValue(
          newErrorFromMessage: error.localizedDescription, in: self.context)
      }
    }
    js.setObject(register, forKeyedSubscript: "_registerSQL" as NSString)
    let schedule: @convention(block) (Int, Double, Bool) -> Void = {
      [weak self] id, delay, repeats in self?.schedule(id: id, delay: delay, repeats: repeats)
    }
    let cancel: @convention(block) (Int) -> Void = { [weak self] id in
      self?.timers.removeValue(forKey: id)?.cancel()
    }
    js.setObject(schedule, forKeyedSubscript: "_scheduleTimer" as NSString)
    js.setObject(cancel, forKeyedSubscript: "_cancelTimer" as NSString)
    let http: @convention(block) (Int, String) -> Void = { [weak self] id, payload in
      self?.fetch(id: id, payload: payload)
    }
    js.setObject(http, forKeyedSubscript: "_http" as NSString)
    let cancelHTTP: @convention(block) (Int) -> Void = { [weak self] id in
      self?.httpTasks.removeValue(forKey: id)?.cancel()
    }
    js.setObject(cancelHTTP, forKeyedSubscript: "_cancelHTTP" as NSString)
    let log: @convention(block) (String) -> Void = { message in
      #if DEBUG
        print("Actual engine:", message)
      #endif
    }
    js.setObject(log, forKeyedSubscript: "_log" as NSString)
    js.evaluateScript(
      "var console = {}; ['log','warn','error','info','debug','group','groupEnd'].forEach(k=>console[k]=(...args)=>_log(args.map(String).join(' ')));"
    )
    for file in ["bootstrap.js", "engine.js"] {
      let url = host.resourceDirectory.appendingPathComponent(file)
      js.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
      if let exception = js.exception {
        let message = exception.toString() ?? "Unknown JavaScript error"
        let stack = exception.objectForKeyedSubscript("stack")?.toString() ?? ""
        throw EngineFailure("Engine initialization: \(message)\n\(stack)")
      }
    }
  }
  private func respond(_ body: () throws -> Any) -> String {
    let result: [String: Any]
    do { result = ["value": try body()] } catch { result = ["error": error.localizedDescription] }
    guard let data = try? JSONSerialization.data(withJSONObject: result),
      let string = String(data: data, encoding: .utf8)
    else { return "{\"error\":\"Native response encoding failed\"}" }
    return string
  }
  private func schedule(id: Int, delay: Double, repeats: Bool) {
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.timers[id] != nil else { return }
      if !repeats { self.timers.removeValue(forKey: id) }
      self.context.objectForKeyedSubscript("__fireTimer")?.call(withArguments: [id])
      if repeats, self.timers[id] != nil { self.schedule(id: id, delay: delay, repeats: true) }
    }
    timers[id] = work
    queue.asyncAfter(deadline: .now() + max(0, min(delay, 2_147_483_647)) / 1000, execute: work)
  }
  private func fetch(id: Int, payload: String) {
    do {
      guard let bytes = payload.data(using: .utf8),
        let args = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
      else { throw EngineFailure("Invalid network request") }
      var request = URLRequest(url: try host.validatedURL(args.requiredString("url")))
      if request.url?.path.hasSuffix("/simplefin/transactions") == true {
        request.timeoutInterval = 300
      }
      request.httpMethod = args["method"] as? String ?? "GET"
      request.allHTTPHeaderFields = args["headers"] as? [String: String]
      if let body = args["body"] as? String { request.httpBody = Data(base64Encoded: body) }
      let task = session.dataTask(with: request) { [weak self] data, response, error in
        let result: [String: Any]
        if let error {
          result = ["error": error.localizedDescription]
        } else if let response = response as? HTTPURLResponse {
          var headers: [String: String] = [:]
          for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
          }
          result = [
            "status": response.statusCode, "headers": headers,
            "body": (data ?? Data()).base64EncodedString(),
          ]
        } else {
          result = ["error": "No response from Actual server"]
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: result),
          let string = String(data: encoded, encoding: .utf8)
        else { return }
        self?.settleHTTP(id: id, payload: string)
      }
      httpTasks[id] = task
      task.resume()
    } catch {
      let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
      settleHTTP(
        id: id,
        payload: data.flatMap { String(data: $0, encoding: .utf8) }
          ?? "{\"error\":\"Network request failed\"}")
    }
  }
  private func settleHTTP(id: Int, payload: String) {
    queue.async { [weak self] in
      self?.httpTasks.removeValue(forKey: id)
      self?.context.objectForKeyedSubscript("__nativeResolve")?.call(withArguments: [id, payload])
    }
  }
}

private final class EngineNetworkDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let previous = response.url, let next = request.url, previous.scheme == next.scheme,
      previous.host == next.host, previous.port == next.port
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
