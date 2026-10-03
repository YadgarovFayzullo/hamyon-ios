import SwiftUI
import WidgetKit

/// Пересчитывает цифры для виджета «Баланс» после каждого изменения операций.
@MainActor
enum WidgetSnapshot {
    private static var pending: Task<Void, Never>?

    static func update(from store: ExpenseStore) {
        // Несколько сохранений подряд (SMS + связка переводов) — один пересчёт.
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            write(store)
        }
    }

    private static func write(_ store: ExpenseStore) {
        let calendar = Calendar.current
        let today = DateInterval(start: calendar.startOfDay(for: .now),
                                 end: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!)
        let month = store.totals(in: ExpenseStore.month(containing: .now))
        let cards = store.cardBalances.map { item -> HamyonSnapshot.Card in
            let bank = Bank.find(store.meta(item.card).bank)
            let color = BankStyleStore.shared.colors(for: bank).bottom
            return .init(digits: item.card, title: store.cardTitle(item.card), balance: item.balance, color: rgb(color))
        }
        let snapshot = HamyonSnapshot(
            spentToday: store.totals(in: today).spent,
            spentMonth: month.spent,
            incomeMonth: month.income,
            budget: BudgetStore.shared.total,
            cards: cards,
            cash: store.cashTracking ? store.cashBalance : nil,
            hideBalances: AppSettings.shared.hideBalances,
            updated: .now)
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func rgb(_ color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map(Double.init)
    }
}
