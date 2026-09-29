import Foundation

/// A parsed file ready to import, with Actual's preview of which rows match existing transactions.
struct ImportPreview: Decodable, Sendable {
    struct Row: Decodable, Sendable, Identifiable {
        /// The transaction as the engine imports it.
        let payload: [String: JSONValue]
        /// Matches an existing transaction, which importing updates instead of duplicating.
        let existing: Bool
        /// Matches a transaction that is already the same, or locked, so Actual skips it.
        let ignored: Bool

        var id: String { if case .string(let id) = payload["trx_id"] { id } else { UUID().uuidString } }
        var date: String { if case .string(let value) = payload["date"] { value } else { "" } }
        var amount: Int { if case .number(let value) = payload["amount"] { value } else { 0 } }
        var payee: String { if case .string(let value) = payload["payee_name"] { value } else { "" } }
        var notes: String { if case .string(let value) = payload["notes"] { value } else { "" } }
    }

    struct Settings: Codable, Sendable, Equatable {
        struct Mapping: Codable, Sendable, Equatable {
            var date: String?
            var payee: String?
            var notes: String?
            var amount: String?
            var inflow: String?
            var outflow: String?
            var category: String?
        }
        var hasHeaderRow: Bool
        var delimiter: String
        var dateFormat: String?
        var mapping: Mapping?
        var splitMode: Bool
        var flipAmount: Bool

        var json: JSONValue {
            let data = (try? JSONEncoder().encode(self)) ?? Data()
            return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        }
    }

    let fileType: String
    let columns: [String]
    let settings: Settings
    let problems: [String]
    let transactions: [Row]

    static let dateFormats = ["yyyy mm dd", "yy mm dd", "mm dd yyyy", "mm dd yy", "dd mm yyyy", "dd mm yy"]
}
