import Charts
import SwiftUI

/// Actual's report colors: income and savings green, spending red.
@MainActor
enum ReportColor {
    static var positive: Color { ActualTheme.positive }
    static var negative: Color { ActualTheme.negative }
    static let neutral = Color.secondary
    static let comparison = Color.gray

    static func of(_ value: Int) -> Color { value > 0 ? positive : value < 0 ? negative : neutral }
}

/// A report's container on the dashboard.
struct ReportCardFrame<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(ActualTheme.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

/// Change.tsx: an increase with a plus sign in green, a decrease in red.
struct ChangeText: View {
    let amount: Int
    let currency: String
    var body: some View {
        Text((amount > 0 ? "+" : "") + Money.formatted(amount, currency: currency))
            .font(.subheadline.weight(.medium)).monospacedDigit()
            .foregroundStyle(ReportColor.of(amount))
    }
}

/// Chart values in major units, so axes read as amounts.
enum ChartAmount {
    static func value(_ minorUnits: Int) -> Double { Double(minorUnits) / 100 }

    /// Short axis labels, such as $1.2K.
    static func axisLabel(_ value: Double, currency: String) -> String {
        if currency.isEmpty { return value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3))) }
        return value.formatted(.currency(code: currency).notation(.compactName).precision(.significantDigits(1...3)))
    }
}

extension View {
    /// Amount labels on a chart's vertical axis.
    func amountAxis(currency: String) -> some View {
        chartYAxis {
            AxisMarks { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let value = mark.as(Double.self) { Text(ChartAmount.axisLabel(value, currency: currency)) }
                }
            }
        }
    }
}

/// A detail page's range: the widget's saved range, or one of Actual's quick-select presets.
struct ReportRangeMenu: View {
    @Binding var preset: ReportRangePreset?
    var oneMonth = false
    var body: some View {
        Menu {
            Picker("Range", selection: $preset) {
                Text("Saved range").tag(ReportRangePreset?.none)
                ForEach(ReportRangePreset.available(oneMonth: oneMonth)) { preset in
                    Text(preset.title).tag(Optional(preset))
                }
            }
        } label: {
            Label(preset?.title ?? "Saved range", systemImage: "calendar")
        }
        .buttonStyle(.glass)
    }
}

/// A loading or failed report, in place of its content.
struct ReportPlaceholder: View {
    let error: String?
    var height: CGFloat = 120
    var retry: (() -> Void)? = nil
    var body: some View {
        Group {
            if let error {
                VStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let retry { Button("Try again", action: retry).buttonStyle(.bordered).controlSize(.small) }
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: height)
    }
}

/// A text widget's Markdown: headings, paragraphs, lists, and inline styles.
struct MarkdownBlocks: View {
    let content: String
    var alignment: String = "left"

    private enum Block: Hashable {
        case heading(Int, String), paragraph(String), bullet(String), numbered(String, String), rule
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
               line[hashes] == " ", line.distance(from: line.startIndex, to: hashes) <= 6 {
                flush()
                blocks.append(.heading(line.distance(from: line.startIndex, to: hashes),
                                       String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(line) {
                flush(); blocks.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush(); blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); blocks.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private var horizontal: HorizontalAlignment { alignment == "center" ? .center : alignment == "right" ? .trailing : .leading }
    private var textAlignment: TextAlignment { alignment == "center" ? .center : alignment == "right" ? .trailing : .leading }
    private var frameAlignment: Alignment { alignment == "center" ? .center : alignment == "right" ? .trailing : .leading }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    var body: some View {
        VStack(alignment: horizontal, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .paragraph(let text):
                    inline(text)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); inline(text) }
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(number)."); inline(text) }
                case .rule:
                    Divider()
                }
            }
        }
        .multilineTextAlignment(textAlignment)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

/// One month of a calendar report, with bars for each day's share of the month's
/// income and spending, as CalendarGraph.tsx draws them.
struct CalendarMonthGrid: View {
    let month: CalendarReport.Month
    let firstDayOfWeekIdx: Int
    var compact = false
    var currency = ""
    var selectedDate: String? = nil
    var onSelect: ((String) -> Void)? = nil

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = firstDayOfWeekIdx + 1
        return calendar
    }

    /// Leading blanks, then each day of the month.
    private var cells: [String?] {
        guard let start = ReportDate.date(month.month),
              let count = calendar.range(of: .day, in: .month, for: start)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: start)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: blanks) + (1...count).map { String(format: "%@-%02d", month.month, $0) }
    }

    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(firstDayOfWeekIdx + $0) % 7] }
    }

    var body: some View {
        let days = Dictionary(uniqueKeysWithValues: month.days.map { ($0.date, $0) })
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                if let date {
                    cell(date, days[date])
                } else {
                    Color.clear.frame(height: compact ? 26 : 44)
                }
            }
        }
    }

    private func cell(_ date: String, _ day: CalendarReport.Day?) -> some View {
        let income = month.totalIncome > 0 ? Double(day?.income ?? 0) / Double(month.totalIncome) : 0
        let expense = month.totalExpense > 0 ? Double(day?.expense ?? 0) / Double(month.totalExpense) : 0
        let content = VStack(spacing: 2) {
            Text(String(Int(date.suffix(2)) ?? 0)).font(compact ? .caption2 : .caption).monospacedDigit()
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 1) {
                    Capsule().fill(ReportColor.positive).frame(width: max(proxy.size.width * income, income > 0 ? 2 : 0))
                    Capsule().fill(ReportColor.negative).frame(width: max(proxy.size.width * expense, expense > 0 ? 2 : 0))
                }
            }.frame(height: compact ? 5 : 7)
        }
        .padding(.vertical, compact ? 2 : 5).padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: compact ? 26 : 44)
        .background(selectedDate == date ? ActualTheme.accent.opacity(0.18) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6))
        return Group {
            if let onSelect, day != nil {
                Button { onSelect(date) } label: { content }.buttonStyle(.plain)
                    .accessibilityHint("Show this day’s transactions")
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(date, day))
    }

    private func accessibilityLabel(_ date: String, _ day: CalendarReport.Day?) -> String {
        let name = ReportDate.date(date)?.formatted(date: .long, time: .omitted) ?? date
        guard let day else { return name }
        return "\(name), income \(Money.formatted(day.income, currency: currency)), spending \(Money.formatted(day.expense, currency: currency))"
    }
}
