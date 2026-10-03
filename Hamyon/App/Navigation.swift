import SwiftUI

/// Какая вкладка открыта и с каким фильтром открыть «Операции» (например, из категории на «Обзоре»).
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    /// Экраны, которые открываются поверх вкладок — из уведомлений, «Обзора» и Siri.
    enum Sheet: String, Identifiable {
        case review, reviewAll, week, debts, recurring, budgets, people, ask, cash, importStatement
        var id: String { rawValue }
    }

    var sheet: Sheet? = ProcessInfo.processInfo.arguments.firstIndex(of: "-sheet").flatMap { index in
        let args = ProcessInfo.processInfo.arguments
        return index + 1 < args.count ? Sheet(rawValue: args[index + 1]) : nil
    }
    var tab: AppTab = ProcessInfo.processInfo.arguments.contains("-openCards") ? .cards
        : ProcessInfo.processInfo.arguments.contains("-openOps") ? .operations : .overview
    var filter = OperationsFilter()
    /// Растёт при каждом входе в приложение — суммы на экранах в этот момент «набегают» от нуля.
    var entry = 0

    func openOperations(_ filter: OperationsFilter) {
        self.filter = filter
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { tab = .operations }
    }
}

struct OperationsFilter: Equatable {
    enum Kind: Hashable, CaseIterable {
        case all, expenses, income, transfers

        var title: String {
            switch self {
            case .all: String(localized: "Все")
            case .expenses: String(localized: "Расходы")
            case .income: String(localized: "Доходы")
            case .transfers: String(localized: "Переводы")
            }
        }
    }

    /// Период: последние N дней, месяц или выбранные даты.
    enum Period: Equatable {
        case days(Int)
        case month(DateInterval)
        case range(Date, Date)

        var interval: DateInterval {
            let calendar = Calendar.current
            switch self {
            case .days(let count):
                let start = calendar.date(byAdding: .day, value: -(count - 1), to: calendar.startOfDay(for: .now))!
                return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!)
            case .month(let month):
                return month
            case .range(let from, let to):
                let start = calendar.startOfDay(for: min(from, to))
                let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))!
                return DateInterval(start: start, end: end)
            }
        }

        var title: String {
            let f = DateFormatter()
            f.locale = DueFormat.locale
            switch self {
            case .days(1): return String(localized: "Сегодня")
            case .days(let count): return String(localized: "\(count) дней")
            case .month(let month):
                f.dateFormat = "LLLL yyyy"
                return f.string(from: month.start).capitalizedFirst
            case .range(let from, let to):
                f.setLocalizedDateFormatFromTemplate("dMMM")
                return "\(f.string(from: min(from, to))) – \(f.string(from: max(from, to)))"
            }
        }
    }

    var kind: Kind = .all
    var category: ExpenseCategory?
    var card: String?
    var period: Period?
    /// Переводы одному человеку.
    var person: String?

    init(kind: Kind = .all, category: ExpenseCategory? = nil, card: String? = nil, month: DateInterval? = nil) {
        self.kind = kind
        self.category = category
        self.card = card
        self.period = month.map { .month($0) }
    }

    func matches(_ expense: Expense) -> Bool {
        switch kind {
        case .all: break
        case .expenses: if expense.isIncome || expense.isInternal { return false }
        case .income: if !expense.isIncome || expense.isInternal { return false }
        case .transfers: if !expense.isTransfer { return false }
        }
        if let category, expense.category != category { return false }
        if let card, expense.card != card { return false }
        if let person, expense.person.map(Expense.personKey) != Expense.personKey(person) { return false }
        if let period, !period.interval.contains(expense.date) || expense.date == period.interval.end { return false }
        return true
    }
}
