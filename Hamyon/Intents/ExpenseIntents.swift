import AppIntents

/// Для автоматизации «Команд»: каждая SMS банка → операция в «Расходах», без открытия приложения.
/// Подходит и для фраз: «Привет, Siri, добавь расход в Hamyon».
struct AddExpenseFromTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Добавить расход из SMS"
    static let description = IntentDescription("Разбирает SMS банка или фразу («обед 45 тысяч») и сохраняет операцию в «Расходы».")

    @Parameter(title: "Текст", requestValueDialog: "Сколько и на что потратили?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = text.trimmed
        let store = ExpenseStore.shared
        let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(70)
        guard !text.isEmpty else {
            store.log("⚠️ пустой текст")
            return .result(dialog: "Пустой текст.")
        }
        // «5800» или «HUMANS» — в команду попал отправитель, а не текст SMS. Без суммы и слов разбирать нечего.
        let hasDigits = text.rangeOfCharacter(from: .decimalDigits) != nil
        let hasLetters = text.rangeOfCharacter(from: .letters) != nil
        if !hasDigits || !hasLetters {
            store.log("⚠️ пришло «\(preview)» — это отправитель, а не текст SMS. В команде выберите Body.")
            return .result(dialog: "Пришёл не текст SMS. В поле «Текст» выберите Body.")
        }
        // Длинный текст — это SMS: по нему отсекаем повторный запуск автоматизации, не обращаясь к ИИ.
        let looksLikeSMS = text.count > 40
        if looksLikeSMS && store.isProcessed(text) {
            store.log("↺ уже было: \(preview)")
            return .result(dialog: "Эта SMS уже обработана.")
        }
        do {
            let drafts = try await ExpenseParser.parse(text, config: AppSettings.shared.aiConfig, cards: store.cardOptions)
            if looksLikeSMS && drafts.isEmpty { store.markSkipped(text) }
            let added = store.add(drafts, source: looksLikeSMS ? .sms : .voice, rawText: looksLikeSMS ? text : nil)
            if looksLikeSMS { Notifier.notifyAdded(added, store: store) } else { Notifier.checkBudgets(store: store) }
            Notifier.scheduleWeekly(store: store)
            let message = SMSSetupView.describe(drafts: drafts, added: added)
            store.log("\(added.isEmpty ? "–" : "✓") \(message) ← \(preview)")
            return .result(dialog: "\(message)")
        } catch {
            store.log("✗ \(error.localizedDescription) ← \(preview)")
            throw error
        }
    }
}

/// «Привет, Siri, спроси Hamyon…» — ответ ИИ по вашим операциям, без открытия приложения.
struct AskHamyonIntent: AppIntent {
    static let title: LocalizedStringResource = "Спросить Hamyon"
    static let description = IntentDescription("Отвечает на вопрос о ваших деньгах по операциям, долгам и бюджетам.")

    @Parameter(title: "Вопрос", requestValueDialog: "Что хотите узнать?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ExpenseStore.shared
        store.reload()
        let answer = try await AskAI.answer(question, store: store, config: AppSettings.shared.aiConfig)
        return .result(dialog: "\(answer)")
    }
}

/// «Сколько я потратил сегодня» — без ИИ, мгновенно.
struct SpentTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Траты за сегодня"
    static let description = IntentDescription("Сколько потрачено сегодня и за месяц.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ExpenseStore.shared
        store.reload()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let today = store.totals(in: DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!))
        let month = store.totals(in: ExpenseStore.month(containing: .now))
        var text = String(localized: "Сегодня — \(Money.string(today.spent)), за месяц — \(Money.string(month.spent)).")
        if let limit = BudgetStore.shared.total {
            text += " " + (month.spent <= limit ? String(localized: "До лимита осталось \(Money.string(limit - month.spent)).")
                                                : String(localized: "Лимит превышен на \(Money.string(month.spent - limit))."))
        }
        return .result(dialog: "\(text)")
    }
}

struct HamyonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddExpenseFromTextIntent(),
            phrases: [
                "Добавь расход в \(.applicationName)",
                "Запиши трату в \(.applicationName)",
            ],
            shortTitle: "Расход",
            systemImageName: "wallet.bifold.fill"
        )
        AppShortcut(
            intent: SpentTodayIntent(),
            phrases: [
                "Сколько я потратил в \(.applicationName)",
                "Траты за сегодня в \(.applicationName)",
            ],
            shortTitle: "Траты за сегодня",
            systemImageName: "chart.bar.fill"
        )
        AppShortcut(
            intent: AskHamyonIntent(),
            phrases: [
                "Спроси \(.applicationName)",
                "Вопрос в \(.applicationName)",
            ],
            shortTitle: "Спросить Hamyon",
            systemImageName: "sparkles"
        )
    }
}
