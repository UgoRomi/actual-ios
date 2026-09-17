import CommonCrypto
import CryptoKit
import Foundation
import Security

struct EngineFailure: LocalizedError, Sendable {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

extension Dictionary where Key == String, Value == Any {
  func requiredString(_ key: String) throws -> String {
    guard let value = self[key] as? String else { throw EngineFailure("Missing \(key)") }
    return value
  }
  func requiredInt(_ key: String) throws -> Int {
    guard let value = self[key] as? Int else { throw EngineFailure("Missing \(key)") }
    return value
  }
  func data(_ key: String) throws -> Data {
    guard let value = Data(base64Encoded: try requiredString(key)) else {
      throw EngineFailure("Invalid binary data")
    }
    return value
  }
}

final class NativeHost {
  let dataDirectory: URL
  let resourceDirectory: URL
  let useKeychain: Bool
  private let service: String
  lazy var sqlite = SQLiteHost { [unowned self] in try self.resolve($0, writing: $1) }
  init(dataDirectory: URL, resourceDirectory: URL, useKeychain: Bool) throws {
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    self.dataDirectory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
    self.resourceDirectory = resourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
    self.useKeychain = useKeychain
    // iOS may relocate the app container during an update. Credentials must
    // remain reachable under an identifier independent of that filesystem path.
    self.service = (Bundle.main.bundleIdentifier ?? "org.actualnative.ios") + ".engine-settings"
  }
  func resolve(_ path: String, writing: Bool) throws -> URL {
    let base: URL
    let suffix: String
    if path == "/documents" || path.hasPrefix("/documents/") {
      base = dataDirectory
      suffix = String(path.dropFirst("/documents".count))
    } else if !writing && (path == "/resources" || path.hasPrefix("/resources/")) {
      base = resourceDirectory
      suffix = String(path.dropFirst("/resources".count))
    } else {
      throw EngineFailure("File path is outside the app's storage")
    }
    let result = base.appendingPathComponent(suffix).standardizedFileURL.resolvingSymlinksInPath()
    guard result.path == base.path || result.path.hasPrefix(base.path + "/") else {
      throw EngineFailure("Invalid file path: \(path) resolved outside its storage root")
    }
    return result
  }
  func perform(_ op: String, _ args: [String: Any]) throws -> Any {
    if op.hasPrefix("sql.") { return try sqlite.perform(op, args) }
    switch op {
    case "event": return NSNull()
    case "fs.exists":
      return FileManager.default.fileExists(
        atPath: try resolve(args.requiredString("path"), writing: false).path)
    case "fs.list":
      return try FileManager.default.contentsOfDirectory(
        atPath: resolve(args.requiredString("path"), writing: false).path)
    case "fs.mkdir":
      try FileManager.default.createDirectory(
        at: resolve(args.requiredString("path"), writing: true), withIntermediateDirectories: true)
      return NSNull()
    case "fs.read":
      return try Data(contentsOf: resolve(args.requiredString("path"), writing: false))
        .base64EncodedString()
    case "fs.write":
      let target = try resolve(args.requiredString("path"), writing: true)
      #if os(iOS)
        try args.data("data").write(
          to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      #else
        try args.data("data").write(to: target, options: .atomic)
      #endif
      return NSNull()
    case "fs.remove":
      let target = try resolve(args.requiredString("path"), writing: true)
      guard target != dataDirectory else { throw EngineFailure("Cannot remove app storage root") }
      try FileManager.default.removeItem(at: target)
      return NSNull()
    case "fs.copy":
      let source = try resolve(args.requiredString("from"), writing: false)
      let target = try resolve(args.requiredString("to"), writing: true)
      try Data(contentsOf: source).write(to: target, options: .atomic)
      return true
    case "fs.size":
      return try FileManager.default.attributesOfItem(
        atPath: resolve(args.requiredString("path"), writing: false).path)[.size] ?? 0
    case "fs.modified":
      let attributes = try FileManager.default.attributesOfItem(
        atPath: resolve(args.requiredString("path"), writing: false).path)
      guard let date = attributes[.modificationDate] as? Date else {
        throw EngineFailure("Missing modification date")
      }
      return date.timeIntervalSince1970 * 1000
    case "settings.read": return try readSettings()
    case "settings.write":
      try writeSettings(args)
      return NSNull()
    case "validate.url":
      _ = try validatedURL(args.requiredString("url"))
      return NSNull()
    case "url.parse":
      let string = try args.requiredString("url")
      guard
        let url = URL(
          string: string, relativeTo: (args["base"] as? String).flatMap(URL.init(string:)))?
          .absoluteURL,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
        let scheme = components.scheme, let host = components.host
      else { throw EngineFailure("Invalid URL") }
      let port = components.port.map { ":\($0)" } ?? ""
      var parts: [String: String] = [
        "href": url.absoluteString, "origin": "\(scheme)://\(host)\(port)",
        "protocol": "\(scheme):", "hostname": host, "host": host + port,
      ]
      parts["port"] = components.port.map { String($0) } ?? ""
      parts["pathname"] =
        components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
      parts["search"] = components.percentEncodedQuery.map { "?" + $0 } ?? ""
      parts["hash"] = components.percentEncodedFragment.map { "#" + $0 } ?? ""
      return parts
    case "crypto.random":
      let count = try args.requiredInt("size")
      guard (0...1_048_576).contains(count) else {
        throw EngineFailure("Invalid random byte count")
      }
      var bytes = [UInt8](repeating: 0, count: count)
      guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw EngineFailure("Secure randomness unavailable")
      }
      return Data(bytes).base64EncodedString()
    case "crypto.hash":
      let data = try args.data("data")
      switch try args.requiredString("algorithm").lowercased() {
      case "md5": return Data(Insecure.MD5.hash(data: data)).base64EncodedString()
      case "sha256": return Data(SHA256.hash(data: data)).base64EncodedString()
      case "sha512": return Data(SHA512.hash(data: data)).base64EncodedString()
      case "sha1": return Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
      default: throw EngineFailure("Unsupported digest")
      }
    case "crypto.derive":
      let password = Array(try args.requiredString("secret").utf8)
      let salt = Array(try args.requiredString("salt").utf8)
      var output = [UInt8](repeating: 0, count: 32)
      let result = password.withUnsafeBytes { passwordBytes in
        salt.withUnsafeBytes { saltBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
            saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 10_000, &output, output.count)
        }
      }
      guard result == kCCSuccess else { throw EngineFailure("Key derivation failed") }
      return Data(output).base64EncodedString()
    case "crypto.encrypt":
      let box = try AES.GCM.seal(args.data("data"), using: SymmetricKey(data: args.data("key")))
      return [
        "value": box.ciphertext.base64EncodedString(),
        "iv": box.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
        "authTag": box.tag.base64EncodedString(),
      ]
    case "crypto.decrypt":
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: args.data("iv")), ciphertext: args.data("data"),
        tag: args.data("authTag"))
      return try AES.GCM.open(box, using: SymmetricKey(data: args.data("key")))
        .base64EncodedString()
    default: throw EngineFailure("Unsupported native operation: \(op)")
    }
  }
  func validatedURL(_ string: String) throws -> URL {
    guard let url = URL(string: string), let scheme = url.scheme, let host = url.host,
      !host.isEmpty,
      url.user == nil, url.password == nil,
      scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    else { throw EngineFailure("Use an HTTPS Actual server address.") }
    return url
  }
  private func readSettings() throws -> [String: Any] {
    let data: Data
    if useKeychain {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: "engine", kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return [:] }
      guard status == errSecSuccess, let stored = result as? Data else {
        throw EngineFailure("Unable to read saved credentials (\(status))")
      }
      data = stored
    } else {
      let url = dataDirectory.appendingPathComponent("test-settings.json")
      guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
      data = try Data(contentsOf: url)
    }
    guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw EngineFailure("Saved engine settings are invalid")
    }
    return settings
  }
  private func writeSettings(_ settings: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: settings)
    if useKeychain {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: "engine",
      ]
      let status = SecItemUpdate(
        query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
          throw EngineFailure("Unable to save credentials (\(added))")
        }
      } else if status != errSecSuccess {
        throw EngineFailure("Unable to save credentials (\(status))")
      }
    } else {
      try data.write(
        to: dataDirectory.appendingPathComponent("test-settings.json"), options: .atomic)
    }
  }
}
