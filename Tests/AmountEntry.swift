import Foundation

/// Amount entry, including the calculations Actual's amount fields accept.
@main struct AmountEntry {
    static func expect(_ input: String, _ expected: Int?, locale: Locale = Locale(identifier: "en_US"),
                       line: UInt = #line) {
        let parsed = Money.parse(input, locale: locale)
        precondition(parsed == expected, "\(locale.identifier) \(input.debugDescription): expected \(expected.map(String.init) ?? "nil"), got \(parsed.map(String.init) ?? "nil")", line: line)
    }

    static func main() {
        // Lone numbers keep their existing rules.
        expect("12.34", 1234)
        expect(" 12 ", 1200)
        expect("-5", -500)
        expect("−5", -500)
        expect("+5", 500)
        expect("1,234.56", 123456)
        expect(".5", 50)
        expect("5.", 500)
        expect("12.340", 1234)
        expect("12.345", nil)
        expect("1,2,3", nil)
        expect("90071992547409.91", 9_007_199_254_740_991)
        expect("90071992547409.92", nil)
        print("PASS: lone numbers")

        // Calculations, with the keypad's symbols or typed ones.
        expect("20+5", 2500)
        expect("20 + 5.50", 2550)
        expect("10−2.5", 750)
        expect("10-2.5", 750)
        expect("3×4.25", 1275)
        expect("3*4.25", 1275)
        expect("10+5×2", 2000)
        expect("(10+5)×2", 3000)
        expect("-(10+5)", -1500)
        expect("5--3", 800)
        expect("5×-2", -1000)
        expect("0.1+0.2", 30)
        expect("1,000+1", 100100)
        print("PASS: operators, precedence, parentheses, and signs")

        // As in Actual, a calculation is rounded to the cent, halves upward.
        expect("100÷3", 3333)
        expect("100/3", 3333)
        expect("200÷3", 6667)
        expect("12.345×1", 1235)
        expect("0.01÷2", 1)
        expect("-0.01÷2", 0)
        expect("-0.03÷2", -1)
        print("PASS: rounding")

        for input in ["", "  ", "+", "-", "5+", "×5", "5×", "(5", "5)", "()", "5(3)", "5÷0", "5÷(2−2)", "abc", "5..5", "1.2.3", "2^3"] {
            expect(input, nil)
        }
        print("PASS: invalid input")

        let german = Locale(identifier: "de_DE")
        expect("1.234,56", 123456, locale: german)
        expect("12,5+1", 1350, locale: german)
        expect("1.5", nil, locale: german)
        let french = Locale(identifier: "fr_FR")
        expect("1\u{202F}234,56", 123456, locale: french)
        expect("1 234,56−0,56", 123400, locale: french)
        let arabic = Locale(identifier: "ar_EG")
        expect("١٢٫٥+١", 1350, locale: arabic)
        for locale in [Locale(identifier: "en_US"), german, french, Locale(identifier: "de_CH"), arabic] {
            for value in [0, 5, -1234, 123456789, -98765432100] {
                expect(Money.editable(value, locale: locale), value, locale: locale)
                expect(Money.editable(value, locale: locale) + "+1", value + 100, locale: locale)
            }
        }
        print("PASS: localized numbers and round trips")
    }
}
