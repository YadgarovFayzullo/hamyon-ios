import Foundation
import UserNotifications

/// Локальные уведомления: после каждой SMS, предупреждения бюджета, напоминания о долгах и платежах, итог недели.
@MainActor
enum Notifier {
    static let transferCategory = "transfer"
    static let whoAction = "who"
    static let ownAction = "own"

    private static var center: UNUserNotificationCenter { .current() }

    static func setUp() {
        let who = UNTextInputNotificationAction(
            identifier: whoAction, title: String(localized: "Ответить, кому"),
            options: [], textInputButtonTitle: String(localized: "Сохранить"),
            textInputPlaceholder: String(localized: "Имя, например «Азиз»"))
        let own = UNNotificationAction(identifier: ownAction, title: String(localized: "Себе на другую карту"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: transferCategory, actions: [who, own], intentIdentifiers: []),
        ])
        center.delegate = NotificationHandler.shared
    }

    static func requestPermission() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-skipNotifications") { return }
        #endif
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static var notifyEachSMS: Bool {
        get { UserDefaults.standard.object(forKey: "notifyEachSMS") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyEachSMS") }
    }

    // MARK: - После SMS

    /// «−45 000 сум · Korzinka» и сколько осталось по бюджету; для перевода без имени — вопрос «Кому?».
    static func notifyAdded(_ added: [Expense], store: ExpenseStore) {
        guard notifyEachSMS, let expense = added.last else { return }
        post(content(for: expense, store: store), id: "sms-\(expense.id)")
        checkBudgets(store: store)
    }

    /// Пробное — такое же, как после SMS, через 5 секунд: успеете свернуть приложение или заблокировать экран.
    /// Берёт перевод без имени (чтобы можно было ответить «Кому»), а если таких нет — последнюю операцию.
    static func sendTest(store: ExpenseStore) async {
        await requestPermission()
        let content: UNMutableNotificationContent
        if let expense = store.expenses.first(where: \.needsReview) ?? store.expenses.first {
            content = self.content(for: expense, store: store)
        } else {
            content = UNMutableNotificationContent()
            content.title = String(localized: "Hamyon")
            content.body = String(localized: "Уведомления работают.")
            content.sound = .default
        }
        try? await center.add(UNNotificationRequest(identifier: "test-\(UUID())", content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
    }

    private static func content(for expense: Expense, store: ExpenseStore) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let amount = Money.string(expense.isIncome ? expense.amount : -expense.amount, currency: expense.currency, sign: expense.isIncome)
        content.title = "\(amount) · \(expense.title)"
        content.sound = .default
        content.userInfo = ["expense": expense.id.uuidString]
        if expense.needsReview {
            if let likely = store.likelyPerson(for: expense) {
                content.body = String(localized: "Похоже, это \(likely). Нажмите, чтобы проверить.")
            } else {
                content.body = expense.kind == .transferIn
                    ? String(localized: "От кого пришло? Удерживайте уведомление и ответьте.")
                    : String(localized: "Кому перевели? Удерживайте уведомление и ответьте.")
            }
            content.categoryIdentifier = transferCategory
        } else {
            content.body = budgetLine(for: expense, store: store) ?? balanceLine(for: expense) ?? ""
        }
        return content
    }

    private static func budgetLine(for expense: Expense, store: ExpenseStore) -> String? {
        guard !expense.isIncome, !expense.isInternal else { return nil }
        let budgets = BudgetStore.shared
        let month = ExpenseStore.month(containing: .now)
        let totals = store.totals(in: month)
        if let limit = budgets.limit(for: expense.category) {
            let left = limit - (totals.byCategory[expense.category] ?? 0)
            return left >= 0
                ? String(localized: "\(expense.category.title): осталось \(Money.string(left)) из \(Money.string(limit))")
                : String(localized: "\(expense.category.title): перерасход \(Money.string(-left))")
        }
        if let daily = budgets.dailyAllowance(spent: totals.spent) {
            return String(localized: "До конца месяца можно ≈ \(Money.string(daily)) в день")
        }
        return nil
    }

    private static func balanceLine(for expense: Expense) -> String? {
        guard let balance = expense.balance, let card = expense.card else { return nil }
        return String(localized: "Остаток на •\(card): \(Money.string(balance))")
    }

    /// 80% и 100% бюджета — по одному разу за месяц на категорию.
    static func checkBudgets(store: ExpenseStore) {
        let budgets = BudgetStore.shared
        let month = ExpenseStore.month(containing: .now)
        let totals = store.totals(in: month)
        var checks: [(key: String, title: String, spent: Double, limit: Double)] = []
        if let total = budgets.total { checks.append(("total", String(localized: "Бюджет месяца"), totals.spent, total)) }
        for category in ExpenseCategory.allCases {
            if let limit = budgets.limit(for: category) {
                checks.append((category.rawValue, category.title, totals.byCategory[category] ?? 0, limit))
            }
        }
        for check in checks where check.limit > 0 {
            let share = check.spent / check.limit
            let level = share >= 1 ? 100 : share >= 0.8 ? 80 : 0
            guard level > 0, budgets.shouldAlert(check.key, level: level, month: month) else { continue }
            let content = UNMutableNotificationContent()
            content.title = level == 100
                ? String(localized: "\(check.title): бюджет исчерпан")
                : String(localized: "\(check.title): потрачено \(Int(share * 100))%")
            content.body = String(localized: "\(Money.string(check.spent)) из \(Money.string(check.limit)).")
            content.sound = .default
            post(content, id: "budget-\(check.key)-\(level)")
        }
    }

    // MARK: - Итог недели

    /// Воскресенье, 20:00: сколько потрачено за неделю и сравнение с прошлой.
    /// Цифры пересчитываются при каждом открытии приложения и каждой SMS.
    static func scheduleWeekly(store: ExpenseStore) {
        let calendar = Calendar.current
        var components = DateComponents()
        components.weekday = 1
        components.hour = 20
        guard let fire = calendar.nextDate(after: .now, matching: components, matchingPolicy: .nextTime) else { return }
        let week = WeekStats(store: store, end: fire)
        guard week.spent > 0 else { cancel("weekly"); return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Итоги недели: \(Money.short(week.spent))")
        var lines: [String] = []
        if week.previous > 0 {
            let change = Int(((week.spent - week.previous) / week.previous * 100).rounded())
            lines.append(change >= 0 ? String(localized: "На \(change)% больше прошлой недели.")
                                     : String(localized: "На \(-change)% меньше прошлой недели."))
        }
        if let top = week.top { lines.append(String(localized: "Больше всего — \(top.category.title): \(Money.short(top.amount)).")) }
        lines.append(String(localized: "Откройте разбор от ИИ."))
        content.body = lines.joined(separator: " ")
        content.sound = .default
        content.userInfo = ["route": "week"]
        let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
        center.add(UNNotificationRequest(identifier: "weekly", content: content, trigger: trigger))
    }

    // MARK: - Напоминания

    /// Долг: в день возврата в 10:00.
    static func scheduleDebt(_ debt: Debt) {
        let id = "debt-\(debt.id)"
        cancel(id)
        guard debt.isOpen, let due = debt.dueDate else { return }
        let calendar = Calendar.current
        guard let fire = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: due), fire > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = debt.lent
            ? String(localized: "Сегодня срок: \(debt.person) возвращает \(Money.string(debt.left))")
            : String(localized: "Сегодня вернуть \(debt.person) \(Money.string(debt.left))")
        content.body = debt.billTitle ?? (debt.note.isEmpty ? String(localized: "Долг в Hamyon") : debt.note)
        content.sound = .default
        content.userInfo = ["route": "debts"]
        let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Регулярный платёж: каждый месяц за день до него в 10:00 (если платёж 1-го — в тот же день в 9:00).
    static func scheduleRecurring(_ item: RecurringPayment) {
        let id = "recurring-\(item.id)"
        cancel(id)
        guard item.remind, !item.suggested, !item.hidden else { return }
        var components = DateComponents()
        components.day = item.day > 1 ? item.day - 1 : 1
        components.hour = item.day > 1 ? 10 : 9
        let content = UNMutableNotificationContent()
        content.title = item.day > 1
            ? String(localized: "Завтра платёж: \(item.title)")
            : String(localized: "Сегодня платёж: \(item.title)")
        content.body = String(localized: "≈ \(Money.string(item.amount)). Проверьте, хватает ли на карте.")
        content.sound = .default
        content.userInfo = ["route": "recurring"]
        center.add(UNNotificationRequest(identifier: id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)))
    }

    static func cancel(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private static func post(_ content: UNMutableNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Неделя для уведомления и экрана «Итоги недели».
struct WeekStats {
    let interval: DateInterval
    let spent: Double
    let previous: Double
    let byCategory: [(category: ExpenseCategory, amount: Double)]
    var top: (category: ExpenseCategory, amount: Double)? { byCategory.first }

    @MainActor
    init(store: ExpenseStore, end: Date = .now) {
        let calendar = Calendar.current
        let endDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        let start = calendar.date(byAdding: .day, value: -7, to: endDay)!
        interval = DateInterval(start: start, end: endDay)
        let totals = store.totals(in: interval)
        spent = totals.spent
        byCategory = totals.sortedCategories
        previous = store.totals(in: DateInterval(start: calendar.date(byAdding: .day, value: -7, to: start)!, end: start)).spent
    }
}

/// Ответы из уведомлений: имя получателя прямо из баннера, переходы на нужный экран.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let expenseID = (info["expense"] as? String).flatMap(UUID.init(uuidString:))
        let route = info["route"] as? String
        await MainActor.run {
            let store = ExpenseStore.shared
            store.reload()
            let expense = expenseID.flatMap { store.expense(id: $0) }
            switch action {
            case Notifier.whoAction:
                if let expense, let text { store.assign(expense, person: text) }
            case Notifier.ownAction:
                if let expense { store.markOwn(expense) }
            case UNNotificationDefaultActionIdentifier:
                let navigation = AppNavigation.shared
                if let expense, expense.needsReview {
                    navigation.sheet = .review
                } else if route == "week" {
                    navigation.sheet = .week
                } else if route == "debts" {
                    navigation.sheet = .debts
                } else if route == "recurring" {
                    navigation.sheet = .recurring
                } else if route == "import" {
                    navigation.sheet = .importStatement
                }
            default:
                break
            }
        }
    }
}
