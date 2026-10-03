import SwiftUI

// MARK: - Люди

/// Кому и от кого переводили: суммы по людям за период.
struct PeopleView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    private enum Range: String, Hashable { case month, quarter, all }
    /// По умолчанию — всё время: так сразу видно, сколько всего ушло человеку. Выбор запоминается.
    @AppStorage("peopleRange") private var range: Range = .all

    private var interval: DateInterval {
        let calendar = Calendar.current
        switch range {
        case .month: return ExpenseStore.month(containing: .now)
        case .quarter:
            return DateInterval(start: calendar.date(byAdding: .month, value: -2, to: ExpenseStore.month(containing: .now).start)!, end: .now.addingTimeInterval(1))
        case .all: return DateInterval(start: .distantPast, end: .now.addingTimeInterval(1))
        }
    }

    var body: some View {
        let rows = store.peopleSummary(in: interval)
        let max = rows.map { $0.sent + $0.received }.max() ?? 1
        List {
            Section {
                Picker("Период", selection: $range) {
                    Text("Месяц").tag(Range.month)
                    Text("3 месяца").tag(Range.quarter)
                    Text("Всё время").tag(Range.all)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if !store.reviewQueue.isEmpty {
                Section {
                    Button { navigation.sheet = .review } label: {
                        Label(String(localized: "Без имени: \(store.reviewQueue.count) — указать, кому"), systemImage: "person.fill.questionmark")
                    }
                }
            }
            Section {
                if rows.isEmpty {
                    Text("Переводов за этот период нет.").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        // «Без имени» — все такие переводы, включая пропущенные раньше.
                        guard row.known else { navigation.sheet = .reviewAll; return }
                        var filter = OperationsFilter(kind: .transfers)
                        filter.person = row.name
                        if range == .month { filter.period = .month(interval) }
                        dismiss()
                        navigation.openOperations(filter)
                    } label: {
                        HStack(spacing: 12) {
                            Text(row.known ? String(row.name.prefix(1)).uppercased() : "?")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background((row.known ? Color.indigo : Color.gray).gradient, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.name).lineLimit(1)
                                    Text("×\(row.count)").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 0) {
                                        if row.sent > 0 { Text(Money.string(-row.sent)).monospacedDigit() }
                                        if row.received > 0 { Text(Money.string(row.received, sign: true)).monospacedDigit().foregroundStyle(.green) }
                                    }
                                    .font(.subheadline)
                                }
                                GeometryReader { proxy in
                                    HStack(spacing: 2) {
                                        Capsule().fill(Color.indigo.opacity(0.8))
                                            .frame(width: proxy.size.width * row.sent / max)
                                        Capsule().fill(Color.green.opacity(0.8))
                                            .frame(width: proxy.size.width * row.received / max)
                                    }
                                }
                                .frame(height: 4)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if row.known {
                            Button("Это я — переводы себе", systemImage: "arrow.triangle.2.circlepath") {
                                withAnimation { store.markPersonAsMe(row.name) }
                            }
                        }
                    }
                }
            } footer: {
                Text("Имена — из выписок и ваших ответов «Кому?». Нажмите на человека — покажу все переводы. Если это вы сами (переводы на свои карты в других банках), удерживайте и выберите «Это я».")
            }
        }
        .navigationTitle("Люди")
    }
}

// MARK: - Итоги недели

struct WeekView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var summary: WeekAI.Result?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        let week = WeekStats(store: store)
        List {
            Section {
                VStack(spacing: 4) {
                    Text(Money.string(week.spent))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("за 7 дней").foregroundStyle(.secondary)
                    if week.previous > 0 {
                        let change = (week.spent - week.previous) / week.previous * 100
                        Label(String(localized: "\(Int(abs(change).rounded()))% к прошлой неделе"),
                              systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(change > 0 ? .orange : .green)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)

            Section {
                if loading {
                    Text("Смотрю, на что ушла неделя…").geminiShimmer()
                } else if let summary {
                    Text(AmountFormat.prettify(summary.summary))
                    ForEach(summary.tips, id: \.self) { tip in
                        Label(AmountFormat.prettify(tip), systemImage: "lightbulb.fill").font(.subheadline)
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                    Button("Повторить") { Task { await load(week, force: true) } }
                }
            } header: {
                Label("ИИ о неделе", systemImage: "sparkles")
            }

            Section("Категории") {
                ForEach(week.byCategory, id: \.category) { row in
                    HStack {
                        IconCircle(symbol: row.category.symbol, color: row.category.color, size: 28)
                        Text(row.category.title)
                        Spacer()
                        Text(Money.string(row.amount)).monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Итоги недели")
        .task { await load(week, force: false) }
        .refreshable { await load(week, force: true) }
    }

    private func load(_ week: WeekStats, force: Bool) async {
        if !force, let cached = WeekAI.cached(week.interval) { summary = cached; return }
        guard week.spent > 0 else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            summary = try await WeekAI.analyze(week: week, store: store, config: settings.aiConfig)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
enum WeekAI {
    struct Result: Codable {
        let summary: String
        let tips: [String]
    }

    static func analyze(week: WeekStats, store: ExpenseStore, config: AIConfig) async throws -> Result {
        let previous = DateInterval(start: Calendar.current.date(byAdding: .day, value: -7, to: week.interval.start)!, end: week.interval.start)
        let text = """
        This week: \(AskAI.lines(in: week.interval, store: store))
        Previous week total spent: \(Int(week.previous)) UZS.
        Budgets: \(AskAI.budgetLine(store: store))
        """
        _ = previous
        let object = try await AIClient.object(
            system: """
            You are a calm personal finance coach in Uzbekistan. Summarize the user's last 7 days of spending in \
            \(AskAI.language): 2–3 sentences with concrete numbers (total, biggest items and people, change vs the previous \
            week), then 1–3 short practical tips for next week. Internal own-card transfers are not spending. No moralizing. \
            \(AskAI.amountStyle)
            """,
            text: text,
            schema: { upper in
                func t(_ type: String) -> String { upper ? type.uppercased() : type }
                return ["type": t("object"),
                        "properties": ["summary": ["type": t("string")],
                                       "tips": ["type": t("array"), "items": ["type": t("string")]]],
                        "required": ["summary", "tips"]]
            },
            toolName: "week_summary", toolDescription: "Итоги недели.", config: config, maxTokens: 1024, timeout: 45
        )
        guard let summary = object["summary"] as? String, !summary.isEmpty else { throw AIError.noResult }
        let result = Result(summary: summary, tips: object["tips"] as? [String] ?? [])
        UserDefaults.standard.set(try? JSONEncoder().encode(result), forKey: key(week.interval))
        return result
    }

    static func cached(_ interval: DateInterval) -> Result? {
        UserDefaults.standard.data(forKey: key(interval)).flatMap { try? JSONDecoder().decode(Result.self, from: $0) }
    }

    private static func key(_ interval: DateInterval) -> String {
        "weekAI-\(Int(interval.start.timeIntervalSince1970))"
    }
}

// MARK: - Вопросы ИИ

/// «Сколько я потратил на такси в сентябре?» — ответ по вашим операциям.
@MainActor
enum AskAI {
    static var language: String {
        Bundle.main.preferredLocalizations.first == "en" ? "English" : "Russian"
    }

    /// Суммы — как в приложении: «190 000 сум», а не «190000 UZS».
    static var amountStyle: String {
        language == "English"
            ? "Write amounts with spaces between thousands and the currency after the number: 190 000 UZS."
            : "Write amounts with spaces between thousands and the word «сум» after the number: 190 000 сум."
    }

    static func answer(_ question: String, store: ExpenseStore, config: AIConfig, now: Date = .now) async throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        let since = Calendar.current.date(byAdding: .month, value: -12, to: now)!
        var context = [
            "Now: \(formatter.string(from: now))",
            "Cards: " + store.cardBalances.map { "\(store.cardTitle($0.card)) balance \(Int($0.balance))" }.joined(separator: "; "),
            "Budgets: " + budgetLine(store: store),
            "Open debts: " + debtLines(store),
            "Recurring payments: " + RecurringStore.shared.active.map { "\($0.title) \(Int($0.amount)) on day \($0.day)" }.joined(separator: "; "),
        ]
        if store.cashTracking { context.append("Cash wallet: \(Int(store.cashBalance))") }
        context.append("Transactions:\n" + lines(in: DateInterval(start: since, end: now.addingTimeInterval(60)), store: store))
        let object = try await AIClient.object(
            system: """
            You answer questions about the user's own money in a personal finance app in Uzbekistan (UZS). \
            Use only the data below; compute sums carefully; if the data does not contain the answer, say so. \
            Rows marked INTERNAL are transfers between the user's own cards and accounts: never count them as spending, \
            income or as money sent to another person. Answer in \(language) (or the language of the question), \
            short and direct: the number first, then 1–2 sentences of context. No markdown tables. \
            \(AskAI.amountStyle)
            """,
            text: context.joined(separator: "\n") + "\n\nQuestion: " + question,
            schema: { upper in
                func t(_ type: String) -> String { upper ? type.uppercased() : type }
                return ["type": t("object"), "properties": ["answer": ["type": t("string")]], "required": ["answer"]]
            },
            toolName: "answer", toolDescription: "Ответ на вопрос о финансах.", config: config, maxTokens: 1024, timeout: 60
        )
        guard let answer = (object["answer"] as? String)?.trimmed, !answer.isEmpty else { throw AIError.noResult }
        return answer
    }

    private static func debtLines(_ store: ExpenseStore) -> String {
        store.openDebts.map { (debt: Debt) -> String in
            let who = debt.lent ? "owes the user" : "user owes"
            let due = debt.dueDate == nil ? "" : " due " + day(debt)
            return "\(debt.person) \(who) \(Int(debt.left))\(due)"
        }
        .joined(separator: "; ")
    }

    private static func day(_ debt: Debt) -> String {
        guard let due = debt.dueDate else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: due)
    }

    static func budgetLine(store: ExpenseStore) -> String {
        let budgets = BudgetStore.shared
        guard !budgets.isEmpty else { return "none" }
        return budgets.limits.map { "\($0.key) \(Int($0.value))/month" }.joined(separator: ", ")
    }

    /// Компактные строки операций: дата; сумма; тип; категория; название; карта; сервис.
    static func lines(in interval: DateInterval, store: ExpenseStore) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return store.expenses
            .filter { interval.contains($0.date) }
            .prefix(2000)
            .map { e in
                var line = "\(f.string(from: e.date)); \(e.isIncome ? "+" : "-")\(Int(e.amount)) \(e.currency); "
                    + "\(e.kind?.rawValue ?? "-"); \(e.category.rawValue); \(e.title); \(e.card.map { "*\($0)" } ?? "-"); \(e.channel ?? "-")"
                if let person = e.person, person != e.title { line += "; to/from \(person)" }
                if e.isInternal { line += "; INTERNAL (between the user's own cards)" }
                if !e.note.isEmpty { line += "; \(e.note)" }
                return line
            }
            .joined(separator: "\n")
    }
}

struct AskView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings

    private struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    @State private var messages: [Message] = []
    @State private var question = ""
    @State private var thinking = false
    @FocusState private var focused: Bool

    private let examples = [
        String(localized: "Сколько ушло на такси в этом месяце?"),
        String(localized: "Кому уходит больше всего переводов?"),
        String(localized: "Хватит ли денег до конца месяца?"),
        String(localized: "Сравни этот месяц с прошлым"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "sparkles").font(.largeTitle).geminiShimmer()
                            Text("Спросите о своих деньгах").font(.title2.weight(.bold))
                            Text("ИИ посмотрит ваши операции за год, долги, бюджеты и регулярные платежи.")
                                .foregroundStyle(.secondary)
                            ForEach(examples, id: \.self) { example in
                                Button { ask(example) } label: {
                                    Text(example)
                                        .font(.subheadline)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 20)
                    }
                    ForEach(messages) { message in
                        Text(message.fromUser ? message.text : AmountFormat.prettify(message.text))
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(message.fromUser ? .white : .primary)
                            .background(message.fromUser ? Color.green : Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
                            .id(message.id)
                    }
                    if thinking {
                        Text("Считаю…").geminiShimmer().padding(.horizontal, 14).id("thinking")
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) {
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                TextField("Вопрос", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button { ask(question) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .tint(.green)
                .disabled(question.trimmed.isEmpty || thinking)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("Спросить ИИ")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func ask(_ text: String) {
        let text = text.trimmed
        guard !text.isEmpty, !thinking else { return }
        question = ""
        messages.append(Message(fromUser: true, text: text))
        thinking = true
        Task {
            defer { thinking = false }
            do {
                let answer = try await AskAI.answer(text, store: store, config: settings.aiConfig)
                messages.append(Message(fromUser: false, text: answer))
            } catch {
                messages.append(Message(fromUser: false, text: error.localizedDescription))
            }
        }
    }
}

// MARK: - Наличные

struct CashView: View {
    @Environment(ExpenseStore.self) private var store
    @State private var amountText = ""
    @State private var editing = false

    var body: some View {
        @Bindable var store = store
        let items = store.expenses.filter { $0.isCash || $0.kind == .cash }.prefix(50)
        List {
            Section {
                VStack(spacing: 4) {
                    Image(systemName: "banknote.fill").font(.title).foregroundStyle(.green)
                    Text(store.cashTracking ? Money.string(store.cashBalance) : "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("в кошельке").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)

            Section {
                Toggle("Вести наличные", isOn: $store.cashTracking).tint(.green)
                Button(store.cashTracking ? "Пересчитать: сколько сейчас в кошельке" : "Указать, сколько сейчас в кошельке") {
                    amountText = store.cashTracking ? String(Int(max(0, store.cashBalance))) : ""
                    editing = true
                }
            } footer: {
                Text("Снятие в банкомате пополняет кошелёк и больше не считается тратой. Тратой станут покупки за наличные — скажите «обед 45 тысяч наличными».")
            }

            if !items.isEmpty {
                Section("Операции") {
                    ForEach(Array(items)) { ExpenseRow(expense: $0) }
                }
            }
        }
        .navigationTitle("Наличные")
        .alert("Сколько сейчас наличных?", isPresented: $editing) {
            TextField("Сумма, сум", text: $amountText).keyboardType(.numberPad).amountFormatting($amountText)
            Button("Сохранить") { store.setCash(Double(amountText.filter(\.isNumber)) ?? 0) }
            Button("Отменить", role: .cancel) {}
        }
    }
}
