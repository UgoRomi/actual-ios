import Foundation
import JavaScriptCore
import SQLite3

final class SQLFunction {
  let callback: JSValue
  init(_ callback: JSValue) { self.callback = callback }
}

final class SQLiteHost {
  private var databases: [Int: OpaquePointer] = [:]
  private var temporaryFiles: [Int: URL] = [:]
  private var nextID = 1
  private let resolve: (String, Bool) throws -> URL
  init(resolve: @escaping (String, Bool) throws -> URL) { self.resolve = resolve }
  deinit {
    for db in databases.values { sqlite3_close_v2(db) }
    for url in temporaryFiles.values { try? FileManager.default.removeItem(at: url) }
  }

  func register(id: Int, name: String, arity: Int, callback: JSValue) throws {
    let db = try database(id)
    let pointer = Unmanaged.passRetained(SQLFunction(callback)).toOpaque()
    let result = sqlite3_create_function_v2(
      db, name, Int32(arity), SQLITE_UTF8 | SQLITE_DETERMINISTIC, pointer,
      { context, count, arguments in
        guard let context, let reference = sqlite3_user_data(context) else { return }
        let fn = Unmanaged<SQLFunction>.fromOpaque(reference).takeUnretainedValue()
        var values: [Any] = []
        for index in 0..<Int(count) {
          guard let value = arguments?[index] else {
            values.append(NSNull())
            continue
          }
          switch sqlite3_value_type(value) {
          case SQLITE_NULL: values.append(NSNull())
          case SQLITE_INTEGER: values.append(sqlite3_value_int64(value))
          case SQLITE_FLOAT: values.append(sqlite3_value_double(value))
          default: values.append(String(cString: sqlite3_value_text(value)))
          }
        }
        guard let result = fn.callback.call(withArguments: values),
          fn.callback.context.exception == nil
        else {
          sqlite3_result_error(context, "SQL function failed", -1)
          return
        }
        if result.isNull || result.isUndefined {
          sqlite3_result_null(context)
        } else if result.isNumber {
          sqlite3_result_double(context, result.toDouble())
        } else {
          (result.toString() ?? "").withCString {
            sqlite3_result_text(
              context, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          }
        }
      }, nil, nil,
      { pointer in
        if let pointer { Unmanaged<SQLFunction>.fromOpaque(pointer).release() }
      })
    guard result == SQLITE_OK else { throw failure(db) }
  }

  func perform(_ op: String, _ args: [String: Any]) throws -> Any {
    if op == "sql.open" {
      var db: OpaquePointer?
      let location: String
      var temporaryFile: URL?
      if let encoded = args["data"] as? String, let data = Data(base64Encoded: encoded) {
        let url = try resolve("/documents/.import-\(UUID().uuidString).sqlite", true)
        try data.write(to: url, options: .atomic)
        location = url.path
        temporaryFile = url
      } else if let path = args["path"] as? String {
        location = path == ":memory:" ? path : try resolve(path, true).path
      } else {
        throw EngineFailure("Missing database path")
      }
      let result = sqlite3_open_v2(
        location, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
      guard result == SQLITE_OK, let db else {
        if let db { sqlite3_close_v2(db) }
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
        throw EngineFailure("Could not open local database")
      }
      sqlite3_busy_timeout(db, 5000)
      sqlite3_exec(db, "PRAGMA synchronous=FULL", nil, nil, nil)
      let id = nextID
      nextID += 1
      databases[id] = db
      temporaryFiles[id] = temporaryFile
      return id
    }
    let id = try args.requiredInt("id")
    let db = try database(id)
    switch op {
    case "sql.close":
      guard sqlite3_close(db) == SQLITE_OK else { throw failure(db) }
      databases.removeValue(forKey: id)
      if let url = temporaryFiles.removeValue(forKey: id) {
        try FileManager.default.removeItem(at: url)
      }
      return NSNull()
    case "sql.exec":
      guard sqlite3_exec(db, try args.requiredString("sql"), nil, nil, nil) == SQLITE_OK else {
        throw failure(db)
      }
      return NSNull()
    case "sql.query":
      var statement: OpaquePointer?
      guard
        sqlite3_prepare_v2(db, try args.requiredString("sql"), -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw failure(db) }
      defer { sqlite3_finalize(statement) }
      let params = args["params"] as? [Any] ?? []
      guard params.count == Int(sqlite3_bind_parameter_count(statement)) else {
        throw EngineFailure("SQL parameter count does not match")
      }
      for (index, value) in params.enumerated() {
        let position = Int32(index + 1)
        let result: Int32
        if value is NSNull {
          result = sqlite3_bind_null(statement, position)
        } else if let string = value as? String {
          result = string.withCString {
            sqlite3_bind_text(
              statement, position, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
          }
        } else if let number = value as? NSNumber {
          let double = number.doubleValue
          guard double.isFinite else { throw EngineFailure("Invalid SQL number") }
          if double.rounded() == double && abs(double) <= 9_007_199_254_740_991 {
            result = sqlite3_bind_int64(statement, position, number.int64Value)
          } else {
            result = sqlite3_bind_double(statement, position, double)
          }
        } else {
          throw EngineFailure("Unsupported SQL parameter")
        }
        guard result == SQLITE_OK else { throw failure(db) }
      }
      let count = sqlite3_column_count(statement)
      let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
      var rows: [[Any]] = []
      var status = sqlite3_step(statement)
      while status == SQLITE_ROW {
        rows.append((0..<count).map { column -> Any in
          switch sqlite3_column_type(statement, column) {
          case SQLITE_NULL: return NSNull()
          case SQLITE_INTEGER: return sqlite3_column_int64(statement, column)
          case SQLITE_FLOAT: return sqlite3_column_double(statement, column)
          case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, column) else { return "" }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column))).base64EncodedString()
          default: return String(cString: sqlite3_column_text(statement, column))
          }
        })
        status = sqlite3_step(statement)
      }
      guard status == SQLITE_DONE else { throw failure(db) }
      if args["fetchAll"] as? Bool == true {
        // Upstream reads some results by column position, such as an AQL calculation's
        // value, so rows keep SQLite's column order. Dictionaries lose it on the way to JS.
        if args["ordered"] as? Bool == true { return ["columns": columns, "rows": rows] }
        return rows.map { values in
          Dictionary(zip(columns, values), uniquingKeysWith: { _, last in last })
        }
      }
      return ["changes": Int(sqlite3_changes(db)), "insertId": sqlite3_last_insert_rowid(db)]
    case "sql.export":
      let target = try resolve("/documents/.export-\(UUID().uuidString).sqlite", true)
      defer { try? FileManager.default.removeItem(at: target) }
      var copy: OpaquePointer?
      guard sqlite3_open(target.path, &copy) == SQLITE_OK, let copy else {
        throw EngineFailure("Cannot prepare database export")
      }
      defer { sqlite3_close(copy) }
      guard let backup = sqlite3_backup_init(copy, "main", db, "main") else { throw failure(copy) }
      let result = sqlite3_backup_step(backup, -1)
      let finish = sqlite3_backup_finish(backup)
      guard result == SQLITE_DONE, finish == SQLITE_OK else { throw failure(copy) }
      return try Data(contentsOf: target).base64EncodedString()
    default: throw EngineFailure("Unknown database operation")
    }
  }
  private func database(_ id: Int) throws -> OpaquePointer {
    guard let db = databases[id] else { throw EngineFailure("Database is closed") }
    return db
  }
  private func failure(_ db: OpaquePointer) -> EngineFailure {
    EngineFailure("Database: \(String(cString: sqlite3_errmsg(db)))")
  }
}
