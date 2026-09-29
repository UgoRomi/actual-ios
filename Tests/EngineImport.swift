import Foundation

extension EngineSmoke {
  /// Imports OFX, CSV, and QIF files as Actual's import dialog does, with duplicates matched.
  static func importing(data: URL, resources: URL) async throws {
    let engine = try EngineClient(dataDirectory: data, resourceDirectory: resources, useKeychain: false)
    _ = try await activeBudget(engine)
    func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
      precondition(condition, message(), line: line)
    }
    struct Counts: Decodable { let added: Int; let updated: Int }
    func prepare(_ name: String, _ contents: String, settings: ImportPreview.Settings? = nil) async throws -> ImportPreview {
      var arguments: [String: JSONValue] = [
        "accountId": .string(account), "fileName": .string(name), "data": .string(Data(contents.utf8).base64EncodedString()),
      ]
      if let settings { arguments["settings"] = settings.json }
      return try await engine.call("prepareImport", arguments: arguments, as: ImportPreview.self)
    }
    func commit(_ name: String, _ preview: ImportPreview) async throws -> Counts {
      try await engine.call("commitImport", arguments: [
        "accountId": .string(account), "fileName": .string(name), "settings": preview.settings.json,
        "transactions": .array(preview.transactions.filter { !$0.ignored }.map { .object($0.payload) }),
      ], as: Counts.self)
    }
    func imported(_ notes: String) async throws -> Transaction? {
      try await engine.call("register", as: [Transaction].self).first { $0.accountId == account && $0.notes == notes }
    }

    let account = try await engine.call("createAccount", arguments: ["name": .string("Native Import")], as: Created.self).id

    // OFX: amounts as the bank sent them, payees in title case as Actual imports them;
    // importing again matches instead of duplicating.
    let ofx = """
    OFXHEADER:100
    DATA:OFXSGML
    VERSION:102

    <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>USD<BANKTRANLIST>
    <STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20260910</DTPOSTED><TRNAMT>-12.34</TRNAMT><FITID>native-ofx-1</FITID><NAME>Native OFX Shop</NAME><MEMO>ofx one</MEMO></STMTTRN>
    <STMTTRN><TRNTYPE>CREDIT</TRNTYPE><DTPOSTED>20260911</DTPOSTED><TRNAMT>100.00</TRNAMT><FITID>native-ofx-2</FITID><NAME>Native Employer</NAME><MEMO>ofx two</MEMO></STMTTRN>
    </BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
    """
    let ofxPreview = try await prepare("bank.ofx", ofx)
    check(ofxPreview.fileType == "ofx" && ofxPreview.transactions.count == 2, "\(ofxPreview.problems)")
    check(ofxPreview.transactions.map(\.amount) == [-1_234, 10_000] && !ofxPreview.transactions.contains { $0.existing })
    check(try await commit("bank.ofx", ofxPreview).added == 2)
    let first = try await imported("ofx one")
    check(first?.amount == -1_234 && first?.date == "2026-09-10" && first?.payeeName == "Native Ofx Shop", "\(String(describing: first))")
    let again = try await prepare("bank.ofx", ofx)
    check(again.transactions.allSatisfy { $0.existing || $0.ignored }, "A second import matches the first")

    // CSV: columns guessed from headers, dates in the first format that fits.
    let csv = "Date,Payee,Notes,Amount\n2026-09-15,Native Cafe,csv latte,-4.50\n2026-09-16,Native Refund,csv refund,\"1,250.00\"\n"
    let csvPreview = try await prepare("bank.csv", csv)
    check(csvPreview.columns == ["Date", "Payee", "Notes", "Amount"])
    check(csvPreview.settings.mapping?.date == "Date" && csvPreview.settings.mapping?.amount == "Amount")
    check(csvPreview.settings.dateFormat == "yyyy mm dd")
    check(csvPreview.transactions.map(\.amount) == [-450, 125_000], "\(csvPreview.transactions.map(\.amount))")
    check(try await commit("bank.csv", csvPreview).added == 2)
    check(try await imported("csv latte")?.date == "2026-09-15")

    // CSV with separate debit and credit columns and day-first dates, chosen by hand.
    let split = "When;Who;Debit;Credit;Memo\n17/09/2026;Native Split Shop;9,99;;split one\n18/09/2026;Native Split Pay;;20,00;split two\n"
    var guessed = try await prepare("split.csv", split, settings: .init(hasHeaderRow: true, delimiter: ";",
      dateFormat: nil, mapping: nil, splitMode: false, flipAmount: false))
    var settings = guessed.settings
    settings.mapping = .init(date: "When", payee: "Who", notes: "Memo", amount: nil, inflow: "Credit", outflow: "Debit")
    settings.splitMode = true
    settings.dateFormat = "dd mm yyyy"
    guessed = try await prepare("split.csv", split, settings: settings)
    check(guessed.transactions.map(\.amount) == [-999, 2_000] && guessed.transactions.map(\.date) == ["2026-09-17", "2026-09-18"],
          "\(guessed.transactions.map(\.amount)) \(guessed.transactions.map(\.date)) \(guessed.problems)")
    check(try await commit("split.csv", guessed).added == 2)

    // QIF: dates read with the guessed month-first format.
    let qif = "!Type:Bank\nD09/19/2026\nT-7.25\nPNative QIF Diner\nMqif dinner\n^\n"
    let qifPreview = try await prepare("bank.qif", qif)
    check(qifPreview.transactions.first?.date == "2026-09-19" && qifPreview.transactions.first?.amount == -725,
          "\(qifPreview.transactions.map(\.date)) \(qifPreview.problems)")

    // Other files are refused.
    var refused = false
    do { _ = try await prepare("notes.pdf", "nope") } catch {
      refused = error.localizedDescription.contains("Choose an OFX")
    }
    check(refused, "Only Actual's import formats are accepted")
    print("PASS: import OFX, CSV (guessed and mapped columns, split amounts), and QIF, matching duplicates")
  }

  struct Created: Decodable { let id: String }
}
