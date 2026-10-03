import SwiftUI

/// Ряд плиток на «Обзоре»: люди, долги, регулярные платежи, бюджеты, наличные, вопрос ИИ.
struct PlanningTiles: View {
    let month: DateInterval
    var inset: CGFloat = 0

    @Environment(ExpenseStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        let debts = store.debtTotals
        let recurring = RecurringStore.shared
        let upcoming = recurring.active.first { recurring.payment(for: $0, in: ExpenseStore.month(containing: .now), store: store) == nil }
        let people = store.peopleSummary(in: month).filter(\.known)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                tile(.ask, symbol: "sparkles", color: .purple, title: String(localized: "Спросить ИИ"),
                     value: String(localized: "о своих деньгах"))
                tile(.people, symbol: "person.2.fill", color: .indigo, title: String(localized: "Люди"),
                     value: people.first.map { "\($0.name) \(Money.short($0.sent))" } ?? String(localized: "кому переводите"))
                tile(.debts, symbol: "arrow.left.arrow.right.circle.fill", color: .orange, title: String(localized: "Долги"),
                     value: debts.owedToMe + debts.iOwe > 0
                        ? [debts.owedToMe > 0 ? "+" + Money.short(debts.owedToMe) : nil,
                           debts.iOwe > 0 ? "−" + Money.short(debts.iOwe) : nil].compactMap { $0 }.joined(separator: " ")
                        : String(localized: "и общий счёт"))
                tile(.recurring, symbol: "repeat.circle.fill", color: .teal, title: String(localized: "Платежи"),
                     value: upcoming.map { "\($0.title), \($0.day)-го" }
                        ?? (recurring.suggested.isEmpty ? String(localized: "регулярные") : String(localized: "найдено \(recurring.suggested.count)")))
                tile(.budgets, symbol: "gauge.with.dots.needle.50percent", color: .green, title: String(localized: "Бюджеты"),
                     value: BudgetStore.shared.total.map { String(localized: "\(Money.short($0)) в месяц") } ?? String(localized: "задать лимиты"))
                tile(.cash, symbol: "banknote.fill", color: .mint, title: String(localized: "Наличные"),
                     value: store.cashTracking ? Money.short(store.cashBalance) : String(localized: "вести кошелёк"))
            }
            .padding(.horizontal, inset)
        }
        // Первая плитка — вровень с карточками; при прокрутке ряд доходит до края экрана.
        .scrollClipDisabled()
    }

    private func tile(_ sheet: AppNavigation.Sheet, symbol: String, color: Color, title: String, value: String) -> some View {
        Button { navigation.sheet = sheet } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .padding(12)
            .frame(width: 128, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Календарь месяца: чем темнее день, тем больше потрачено. Нажатие — операции этого дня.
struct SpendingCalendar: View {
    let month: DateInterval
    let cards: Set<String>
    let open: (Date) -> Void

    @Environment(ExpenseStore.self) private var store

    var body: some View {
        let calendar = Calendar.current
        let days = calendar.range(of: .day, in: .month, for: month.start)!.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: month.start)
        }
        var spent: [Date: Double] = [:]
        for expense in store.expenses(in: month, cards: cards) where !expense.isIncome && !expense.isInternal && expense.currency == "UZS" {
            spent[calendar.startOfDay(for: expense.date), default: 0] += expense.amount
        }
        let maxSpent = spent.values.max() ?? 1
        // Пустые клетки до первого дня — неделя начинается с понедельника, как принято в Узбекистане.
        let offset = (calendar.component(.weekday, from: month.start) + 5) % 7
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        let symbols = Self.weekdaySymbols

        return VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { Text($0.element).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 42) }
                ForEach(days, id: \.self) { day in
                    let amount = spent[day] ?? 0
                    let intensity = amount > 0 ? 0.15 + 0.85 * sqrt(amount / maxSpent) : 0
                    let future = day > .now
                    Button { open(day) } label: {
                        VStack(spacing: 1) {
                            Text("\(calendar.component(.day, from: day))")
                                .font(.caption.weight(calendar.isDateInToday(day) ? .bold : .medium))
                            Text(amount > 0 ? Money.short(amount).replacingOccurrences(of: " сум", with: "") : " ")
                                .font(.system(size: 8, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .foregroundStyle(intensity > 0.55 ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(amount > 0 ? Color.orange.opacity(intensity) : Color(.tertiarySystemFill).opacity(future ? 0.4 : 1))
                        )
                        .overlay {
                            if calendar.isDateInToday(day) {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.green, lineWidth: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(future)
                }
            }
            Text("Темнее — больше потрачено. Нажмите на день, чтобы увидеть операции.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private static var weekdaySymbols: [String] {
        let f = DateFormatter()
        f.locale = DueFormat.locale
        let symbols = f.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        return Array(symbols[1...]) + [symbols[0]]
    }
}

extension View {
    /// Секция списка без боковых полей (iOS 26+): свои карточки с отступом не обрезаются скруглением секции.
    @ViewBuilder
    func fullWidthSection() -> some View {
        if #available(iOS 26.0, *) {
            listSectionMargins(.horizontal, 0)
                .listSectionSeparator(.hidden)
                .listRowSeparator(.hidden)
        } else {
            self
        }
    }
}
