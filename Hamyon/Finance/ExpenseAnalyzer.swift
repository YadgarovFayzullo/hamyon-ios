import Foundation

/// Разбор месяца ИИ: где уходят деньги и что можно сократить.
struct ExpenseAnalysis: Codable, Equatable {
    struct Insight: Codable, Equatable, Identifiable {
        var id: String { title }
        let title: String
        let detail: String
        /// Сколько можно сэкономить в месяц, в сумах; 0 — если совет не про экономию.
        let saving: Double
        let category: String?
    }

    let summary: String
    let insights: [Insight]
    let generatedAt: Date
    /// Сколько операций было учтено — если с тех пор добавились новые, анализ устарел.
    let transactionCount: Int

    var totalSaving: Double { insights.reduce(0) { $0 + max(0, $1.saving) } }
}

@MainActor
enum ExpenseAnalyzer {
    private static let toolName = "spending_analysis"

    static func analyze(month: DateInterval, store: ExpenseStore, config: AIConfig) async throws -> ExpenseAnalysis {
        let items = store.expenses(in: month)
        let object = try await AIClient.object(
            system: systemPrompt, text: report(month: month, items: items, store: store),
            schema: schema(upper:), toolName: toolName,
            toolDescription: "Вернуть разбор расходов за месяц.",
            config: config, maxTokens: 2048, timeout: 60
        )
        let insights = (object["insights"] as? [[String: Any]] ?? []).compactMap { item -> ExpenseAnalysis.Insight? in
            guard let title = item["title"] as? String, let detail = item["detail"] as? String else { return nil }
            return .init(title: title, detail: detail,
                         saving: (item["monthly_saving_uzs"] as? NSNumber)?.doubleValue ?? 0,
                         category: item["category"] as? String)
        }
        guard let summary = object["summary"] as? String, !summary.isEmpty else { throw AIError.noResult }
        return ExpenseAnalysis(summary: summary, insights: insights, generatedAt: .now, transactionCount: items.count)
    }

    private static var language: String {
        Bundle.main.preferredLocalizations.first == "en" ? "English" : "Russian"
    }

    private static var systemPrompt: String {
        """
        You are a calm, practical personal finance coach for a person living in Uzbekistan (prices in UZS, sum). \
        You get one month of their transactions and the category totals of previous months.

        Write in \(language). Be specific and use the numbers from the data; never invent transactions. \
        \(AskAI.amountStyle) \
        No moralizing, no generic advice like "make a budget" unless the data shows why.

        - summary: 2–3 sentences — how much was spent, where most of it went, how it compares to previous months.
        - insights: 3–6 items, most valuable first. Look for: recurring payments and subscriptions; many small \
        purchases that add up (coffee, delivery, taxi); categories that grew versus previous months; unusually \
        large one-off purchases; cheaper alternatives common in Uzbekistan (metro/bus instead of taxi, \
        cooking instead of delivery, bazaar instead of supermarket for vegetables, cheaper mobile plans). \
        Analyze the transactions themselves, not just category totals: timing (time of day, weekdays, bursts of \
        payments within minutes), which card is used for what, repeated identical amounts, recurring payees.
        - Transfers (P2P) often dominate spending in Uzbekistan. Bank SMS rarely name the recipient, so look at \
        counterparty, channel (Payme, Tez, Zoomrad, SQB…), amounts and timing: how much went out and to whom/through \
        what, regular transfers (same amount or same day each month — rent, loan, family support?), many small \
        transfers, transfers to other banks, late-night transfers, and fees. Suggest labeling the biggest unknown \
        transfers (the user can rename a transfer to the recipient). Never treat "internal" transfers between the \
        user's own cards as spending — only their fees are.
        If income is known, comment on the savings rate. If the month is still in progress, say so and \
        do not present partial numbers as final — project to a full month only when there are at least 7 days of data.
        - monthly_saving_uzs: a realistic monthly saving in sum if the advice is followed, 0 if not applicable.
        - title: short (up to 6 words). detail: 1–3 sentences with the concrete numbers.
        """
    }

    private static func report(month: DateInterval, items: [Expense], store: ExpenseStore) -> String {
        let monthFormat = DateFormatter()
        monthFormat.locale = Locale(identifier: "en_US_POSIX")
        monthFormat.dateFormat = "LLLL yyyy"
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd EEE HH:mm"

        let totals = store.totals(in: month)
        let elapsed = min(month.duration, max(Date.now.timeIntervalSince(month.start), 86400))
        var lines = [
            "Month: \(monthFormat.string(from: month.start))" + (month.contains(.now)
                ? " (in progress, \(Int(elapsed / 86400)) of \(Int(month.duration / 86400)) days passed)" : ""),
            "Spent: \(Int(totals.spent)) UZS, income: \(Int(totals.income)) UZS",
            "By category: " + totals.sortedCategories.map { "\($0.category.rawValue) \(Int($0.amount))" }.joined(separator: ", "),
        ]
        if !totals.foreign.isEmpty {
            lines.append("Of which in other currencies (already converted to UZS at the Central Bank rate where known): " + totals.foreign.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
        }

        // Три предыдущих месяца — для сравнения.
        var start = month.start
        for _ in 0..<3 {
            guard let previous = Calendar.current.date(byAdding: .month, value: -1, to: start) else { break }
            start = previous
            let interval = ExpenseStore.month(containing: previous)
            let old = store.totals(in: interval)
            guard old.spent > 0 || old.income > 0 else { continue }
            lines.append("\(monthFormat.string(from: previous)): spent \(Int(old.spent)), income \(Int(old.income)); "
                + old.sortedCategories.map { "\($0.category.rawValue) \(Int($0.amount))" }.joined(separator: ", "))
        }

        let transfers = store.transfers(in: month)
        if !transfers.isEmpty {
            lines.append("Transfers: sent to others \(Int(transfers.sent)), received \(Int(transfers.received)), "
                + "moved between own cards \(Int(transfers.internalAmount)) (fees \(Int(transfers.fees))); by recipient/channel: "
                + transfers.groups.map { "\($0.name) ×\($0.count) \(Int($0.amount))" }.joined(separator: ", "))
        }
        let cardNames = store.cards.map { store.cardTitle($0) }.joined(separator: ", ")
        if !cardNames.isEmpty { lines.append("User's cards: \(cardNames)") }

        lines.append("\nTransactions (date; amount; currency; kind; category; title; card; channel; counterparty; note):")
        for expense in items.prefix(500) {
            let sign = expense.isIncome ? "+" : "-"
            var line = "\(dayFormat.string(from: expense.date)); \(sign)\(Int(expense.amount)); \(expense.currency); "
                + "\(expense.kind?.rawValue ?? "-"); \(expense.category.rawValue); \(expense.title); "
                + "\(expense.card.map { "*\($0)" } ?? "-"); \(expense.channel ?? "-"); \(expense.counterparty ?? "-"); "
                + (expense.note.isEmpty ? "-" : expense.note)
            if expense.isInternal { line += "; INTERNAL own-card transfer" + (expense.fee > 0 ? ", fee \(Int(expense.fee))" : "") }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func schema(upper: Bool) -> [String: Any] {
        func t(_ type: String) -> String { upper ? type.uppercased() : type }
        return [
            "type": t("object"),
            "properties": [
                "summary": ["type": t("string")],
                "insights": [
                    "type": t("array"),
                    "items": [
                        "type": t("object"),
                        "properties": [
                            "title": ["type": t("string")],
                            "detail": ["type": t("string")],
                            "monthly_saving_uzs": ["type": t("number")],
                            "category": ["type": t("string"), "enum": ExpenseCategory.allCases.map(\.rawValue)],
                        ],
                        "required": ["title", "detail", "monthly_saving_uzs"],
                    ],
                ],
            ],
            "required": ["summary", "insights"],
        ]
    }

    // MARK: - Кэш: не тратим запросы при каждом открытии экрана

    static func cached(for month: DateInterval) -> ExpenseAnalysis? {
        guard let data = Account.defaults.data(forKey: key(month)) else { return nil }
        return try? JSONDecoder().decode(ExpenseAnalysis.self, from: data)
    }

    static func cache(_ analysis: ExpenseAnalysis, for month: DateInterval) {
        Account.defaults.set(try? JSONEncoder().encode(analysis), forKey: key(month))
    }

    private static func key(_ month: DateInterval) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: month.start)
        return "expenseAnalysis-\(c.year ?? 0)-\(c.month ?? 0)"
    }
}
