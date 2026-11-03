import Foundation

/// The payee picker's search: suggestions first, the rest after, the add choice, and its cost with many payees.
@main struct PayeeSearchTests {
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        precondition(condition, message(), line: line)
    }

    static func main() {
        let payees = [
            Payee(id: "a", name: "Amazon"), Payee(id: "b", name: "Apple", favorite: true),
            Payee(id: "c", name: "Café Nero"), Payee(id: "d", name: "Safeway"),
        ]
        let all = PayeeSearch(payees: payees, suggestedIDs: ["b", "missing", "d"], query: "")
        expect(all.suggested.map(\.id) == ["b", "d"], "suggestions keep their order and skip unknown payees")
        expect(all.others.map(\.id) == ["a", "c"], "the rest keep their order without suggestions")
        expect(!all.canAdd, "no add choice without a search")

        let caf = PayeeSearch(payees: payees, suggestedIDs: ["b", "d"], query: "CAF")
        expect(caf.suggested.isEmpty && caf.others.map(\.id) == ["c"], "case-insensitive match")
        expect(caf.canAdd, "a new name can be added")
        let safe = PayeeSearch(payees: payees, suggestedIDs: ["b", "d"], query: "safe")
        expect(safe.suggested.map(\.id) == ["d"] && safe.others.isEmpty, "a matching suggestion stays a suggestion")
        expect(!PayeeSearch(payees: payees, suggestedIDs: [], query: "amazon").canAdd, "an existing name differing in case is reused")

        // Each keystroke rebuilds the lists. With 5,000 payees, the earlier picker did
        // 25 million dictionary inserts for an empty search; this must stay linear.
        let many = (0..<5_000).map { Payee(id: "p\($0)", name: "Payee \($0)") }
        let suggestedIDs = (0..<20).map { "p\($0 * 7)" }
        let start = Date()
        for query in ["", "P", "Pa", "Pay", "Paye", "Payee", "Payee ", "Payee 1", "Payee 12"] {
            let found = PayeeSearch(payees: many, suggestedIDs: suggestedIDs, query: query.trimmingCharacters(in: .whitespaces))
            expect(found.suggested.count + found.others.count
                   == many.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces)) }.count,
                   "\(query.debugDescription): every match listed once")
        }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "9 searches over 5,000 payees: %.1f ms", elapsed * 1000))
        expect(elapsed < 1, "searching 5,000 payees took \(elapsed)s")
        print("Payee search: OK")
    }
}
