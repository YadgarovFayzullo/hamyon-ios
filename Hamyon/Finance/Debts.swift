import Foundation
import SwiftData

/// Долг: вы дали в долг (`lent`) или взяли. Хранится рядом с операциями.
@Model
final class Debt {
    var id: UUID = UUID()
    var person: String = ""
    var amount: Double = 0
    var currency: String = "UZS"
    /// true — вам должны, false — должны вы.
    var lent: Bool = true
    var date: Date = Date.now
    /// Когда обещали вернуть — в этот день придёт напоминание.
    var dueDate: Date?
    var note: String = ""
    /// Сколько уже вернули.
    var repaid: Double = 0
    var closedAt: Date?
    var createdAt: Date = Date.now
    /// История возвратов (JSON) — для ленты «вернули 200 000 · 5 окт».
    var paymentsData: Data?
    /// Название общего счёта, из которого появился долг («Ужин в Beshqozon»), — не меняется.
    var billTitle: String?

    init(person: String, amount: Double, lent: Bool, date: Date = .now, dueDate: Date? = nil, note: String = "") {
        self.id = UUID()
        self.person = person
        self.amount = amount
        self.lent = lent
        self.date = date
        self.dueDate = dueDate
        self.note = note
        self.createdAt = .now
    }

    var left: Double { max(0, amount - repaid) }

    var payments: [DebtPayment] {
        get { paymentsData.flatMap { try? JSONDecoder().decode([DebtPayment].self, from: $0) } ?? [] }
        set { paymentsData = try? JSONEncoder().encode(newValue) }
    }
    var isOpen: Bool { closedAt == nil && left > 0 }
    var isOverdue: Bool {
        guard isOpen, let dueDate else { return false }
        return dueDate < Calendar.current.startOfDay(for: .now)
    }
}

/// Один возврат долга (частичный или полный).
struct DebtPayment: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let amount: Double
}

/// Черновик долга — из формы или из фразы «дал Азизу 500 тысяч до пятницы».
struct DebtDraft: Equatable {
    var person = ""
    var amount: Double = 0
    var lent = true
    var date = Date.now
    var dueDate: Date?
    var note = ""
    var billTitle: String?
}

extension ExpenseStore {
    var openDebts: [Debt] { debts.filter(\.isOpen) }

    /// Разово: долги из «Разделить счёт», созданные до поля `billTitle` (срок ровно через 3 дня, название в заметке).
    func moveBillTitles() {
        guard !Account.defaults.bool(forKey: "debtBillTitles1") else { return }
        for debt in debts where debt.billTitle == nil && !debt.note.isEmpty {
            guard let due = debt.dueDate,
                  let expected = Calendar.current.date(byAdding: .day, value: 3, to: debt.createdAt),
                  abs(due.timeIntervalSince(expected)) < 120 else { continue }
            debt.billTitle = debt.note
            debt.note = ""
        }
        try? modelContext.save()
        Account.defaults.set(true, forKey: "debtBillTitles1")
    }

    /// Сколько всего должны вам и сколько должны вы.
    var debtTotals: (owedToMe: Double, iOwe: Double) {
        openDebts.reduce((0, 0)) { sum, debt in
            debt.lent ? (sum.0 + debt.left, sum.1) : (sum.0, sum.1 + debt.left)
        }
    }

    @discardableResult
    func addDebt(_ draft: DebtDraft) -> Debt {
        let debt = Debt(person: draft.person.trimmed.capitalizedFirst, amount: draft.amount, lent: draft.lent,
                        date: draft.date, dueDate: draft.dueDate, note: draft.note.trimmed)
        debt.billTitle = draft.billTitle
        modelContext.insert(debt)
        save()
        Notifier.scheduleDebt(debt)
        return debt
    }

    func updateDebt(_ debt: Debt, with draft: DebtDraft) {
        debt.person = draft.person.trimmed.capitalizedFirst
        debt.amount = draft.amount
        debt.lent = draft.lent
        debt.date = draft.date
        debt.dueDate = draft.dueDate
        debt.note = draft.note.trimmed
        if debt.left <= 0, debt.closedAt == nil { debt.closedAt = .now }
        if debt.left > 0 { debt.closedAt = nil }
        save()
        Notifier.scheduleDebt(debt)
    }

    /// Вернули часть или всё. Полностью — долг закрывается, напоминание снимается.
    func repay(_ debt: Debt, amount: Double? = nil) {
        let paid = min(debt.left, amount ?? debt.left)
        guard paid > 0 else { return }
        debt.payments.append(DebtPayment(date: .now, amount: paid))
        debt.repaid = min(debt.amount, debt.repaid + paid)
        if debt.left <= 0 { debt.closedAt = .now }
        save()
        Notifier.scheduleDebt(debt)
    }

    func reopen(_ debt: Debt) {
        debt.closedAt = nil
        if debt.left <= 0 {
            debt.repaid = 0
            debt.payments = []
        }
        save()
        Notifier.scheduleDebt(debt)
    }

    func deleteDebt(_ debt: Debt) {
        Notifier.cancel("debt-\(debt.id)")
        modelContext.delete(debt)
        save()
    }

    /// Открытый долг этого человека в нужную сторону (для вопроса «это возврат долга?»).
    func openDebt(person: String, lent: Bool) -> Debt? {
        openDebts.first { $0.person.lowercased() == person.trimmed.lowercased() && $0.lent == lent }
    }
}
