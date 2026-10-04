import Foundation

// MARK: - Бюджеты

/// Лимиты на месяц: общий и по категориям. Хранятся в UserDefaults.
@MainActor
@Observable
final class BudgetStore {
    static let shared = BudgetStore()

    /// categoryRaw → лимит в сумах; ключ `total` — общий лимит.
    private(set) var limits: [String: Double] = Account.defaults.dictionary(forKey: "budgets") as? [String: Double] ?? [:]

    var total: Double? { limits["total"] }

    func limit(for category: ExpenseCategory) -> Double? { limits[category.rawValue] }

    func set(_ value: Double?, for key: String) {
        limits[key] = (value ?? 0) > 0 ? value : nil
        Account.defaults.set(limits, forKey: "budgets")
        WidgetSnapshot.update(from: ExpenseStore.shared)
    }

    var isEmpty: Bool { limits.isEmpty }

    /// Сколько можно тратить в день до конца месяца, чтобы уложиться в общий бюджет.
    func dailyAllowance(spent: Double, now: Date = .now) -> Double? {
        guard let total, total > spent else { return total == nil ? nil : 0 }
        let calendar = Calendar.current
        let month = ExpenseStore.month(containing: now)
        let daysLeft = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: month.end).day ?? 1)
        return (total - spent) / Double(daysLeft)
    }

    /// Предупреждения, которые уже показали в этом месяце: «budget-2026-10-cafe-80».
    func shouldAlert(_ key: String, level: Int, month: DateInterval) -> Bool {
        let c = Calendar.current.dateComponents([.year, .month], from: month.start)
        let id = "budgetAlert-\(c.year ?? 0)-\(c.month ?? 0)-\(key)-\(level)"
        guard !Account.defaults.bool(forKey: id) else { return false }
        Account.defaults.set(true, forKey: id)
        return true
    }
}

// MARK: - Регулярные платежи

struct RecurringPayment: Codable, Identifiable, Equatable {
    /// Ключ группы: имя человека или название в нижнем регистре.
    var id: String
    var title: String
    var amount: Double
    /// День месяца, когда обычно платите.
    var day: Int
    var categoryRaw: String
    var remind = true
    /// Найден автоматически и ещё не подтверждён.
    var suggested = false
    var hidden = false

    var category: ExpenseCategory { ExpenseCategory(rawValue: categoryRaw) ?? .other }

    /// Ближайшая дата платежа: в этом месяце, если ещё не оплачено и день не прошёл, иначе в следующем.
    func nextDate(paidThisMonth: Bool, now: Date = .now) -> Date {
        let calendar = Calendar.current
        func date(in month: Date) -> Date {
            let range = calendar.range(of: .day, in: .month, for: month) ?? 1..<29
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = min(day, range.upperBound - 1)
            return calendar.date(from: components) ?? month
        }
        let thisMonth = date(in: now)
        if !paidThisMonth && thisMonth >= calendar.startOfDay(for: now) { return thisMonth }
        return date(in: calendar.date(byAdding: .month, value: 1, to: now)!)
    }
}

@MainActor
@Observable
final class RecurringStore {
    static let shared = RecurringStore()

    private(set) var items: [RecurringPayment] = {
        guard let data = Account.defaults.data(forKey: "recurring") else { return [] }
        return (try? JSONDecoder().decode([RecurringPayment].self, from: data)) ?? []
    }()

    var active: [RecurringPayment] { items.filter { !$0.suggested && !$0.hidden }.sorted { $0.day < $1.day } }
    var suggested: [RecurringPayment] { items.filter { $0.suggested && !$0.hidden } }
    var monthlyTotal: Double { active.reduce(0) { $0 + $1.amount } }

    func upsert(_ item: RecurringPayment) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
        persist()
        Notifier.scheduleRecurring(item)
    }

    func confirm(_ item: RecurringPayment) {
        var item = item
        item.suggested = false
        upsert(item)
    }

    func hide(_ item: RecurringPayment) {
        var item = item
        item.hidden = true
        item.remind = false
        upsert(item)
    }

    func delete(_ item: RecurringPayment) {
        items.removeAll { $0.id == item.id }
        persist()
        Notifier.cancel("recurring-\(item.id)")
    }

    private func persist() {
        Account.defaults.set(try? JSONEncoder().encode(items), forKey: "recurring")
    }

    /// Уже оплачено в этом месяце: есть операция того же получателя на похожую сумму.
    func payment(for item: RecurringPayment, in month: DateInterval, store: ExpenseStore) -> Expense? {
        store.expenses(in: month).first { expense in
            !expense.isIncome && !expense.isInternal && Self.key(of: expense) == item.id
                && abs(expense.amount - item.amount) <= item.amount * 0.25
        }
    }

    static func key(of expense: Expense) -> String? {
        if expense.isTransfer { return expense.person.map { "p:" + $0.lowercased() } }
        let title = expense.title.trimmed.lowercased()
        return title.isEmpty ? nil : "t:" + title
    }

    /// Находит платежи, которые повторяются каждый месяц примерно в один день и на похожую сумму:
    /// интернет, связь, аренда, кредит, подписки, регулярные переводы родным.
    func detect(from store: ExpenseStore, now: Date = .now) {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .month, value: -6, to: now)!
        // Ежедневные траты (продукты, кафе, такси) повторяются, но это не «регулярный платёж».
        let everyday: Set<ExpenseCategory> = [.groceries, .cafe, .transport, .shopping, .fees, .other]
        let candidates = store.expenses.filter {
            !$0.isIncome && !$0.isInternal && $0.currency == "UZS" && $0.date >= since
                && ($0.isTransfer || !everyday.contains($0.category))
        }
        let groups = Dictionary(grouping: candidates) { Self.key(of: $0) ?? "" }
        var found: [RecurringPayment] = []
        for (key, list) in groups where !key.isEmpty {
            let byMonth = Dictionary(grouping: list) { ExpenseStore.month(containing: $0.date).start }
            // Раз в месяц: не больше двух таких платежей в одном месяце и хотя бы два месяца подряд.
            guard byMonth.count >= 2, byMonth.values.allSatisfy({ $0.count <= 2 }) else { continue }
            let amounts = list.map(\.amount).sorted()
            let median = amounts[amounts.count / 2]
            let similar = list.filter { abs($0.amount - median) <= median * 0.2 }
            let months = Set(similar.map { ExpenseStore.month(containing: $0.date).start })
            guard months.count >= 2 else { continue }
            let days = similar.map { calendar.component(.day, from: $0.date) }.sorted()
            guard let first = days.first, let last = days.last, last - first <= 6 else { continue }
            let latest = similar.max { $0.date < $1.date }!
            found.append(RecurringPayment(id: key, title: latest.title, amount: latest.amount,
                                          day: days[days.count / 2], categoryRaw: latest.category.rawValue,
                                          remind: true, suggested: true))
        }
        var changed = false
        for item in found {
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                // Подтверждённый платёж: обновляем сумму по последней операции.
                if !items[index].hidden && items[index].amount != item.amount && items[index].suggested {
                    items[index].amount = item.amount
                    changed = true
                }
            } else {
                items.append(item)
                changed = true
            }
        }
        if changed { persist() }
    }
}

// MARK: - Наличные

extension ExpenseStore {
    /// Сколько сейчас в кошельке: вписанная сумма + снятия в банкомате − покупки за наличные после неё.
    var cashBalance: Double {
        var balance = cashBase
        for expense in expenses where expense.date > cashBaseDate && expense.currency == "UZS" {
            if expense.kind == .cash && !expense.isIncome && !expense.isCash { balance += expense.amount }
            if expense.isCash { balance += expense.isIncome ? expense.amount : -expense.amount }
        }
        return balance
    }

    func setCash(_ amount: Double) {
        cashBase = amount
        cashBaseDate = .now
        cashTracking = true
        save()
    }
}

// MARK: - Курсы валют ЦБ Узбекистана

/// Курсы с cbu.uz (бесплатно, без ключа). Обновляются раз в день, хранятся на телефоне.
@MainActor
@Observable
final class Rates {
    static let shared = Rates()

    private(set) var rates: [String: Double] = Account.defaults.dictionary(forKey: "cbuRates") as? [String: Double] ?? [:]
    private(set) var updated: Date? = Account.defaults.object(forKey: "cbuRatesDate") as? Date

    func rate(_ currency: String) -> Double? { currency == "UZS" ? 1 : rates[currency] }

    func refresh() async {
        if let updated, Date.now.timeIntervalSince(updated) < 6 * 3600, !rates.isEmpty { return }
        guard let url = URL(string: "https://cbu.uz/ru/arkhiv-kursov-valyut/json/"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var result: [String: Double] = [:]
        for item in list {
            guard let code = item["Ccy"] as? String,
                  let rate = Double((item["Rate"] as? String ?? "").replacingOccurrences(of: ",", with: ".")) else { continue }
            let nominal = Double(item["Nominal"] as? String ?? "1") ?? 1
            result[code] = rate / max(nominal, 1)
        }
        guard !result.isEmpty else { return }
        rates = result
        updated = .now
        Account.defaults.set(result, forKey: "cbuRates")
        Account.defaults.set(Date.now, forKey: "cbuRatesDate")
    }
}
