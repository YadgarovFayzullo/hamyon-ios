import Foundation
import SwiftData

/// Все операции в памяти (их немного — тысячи), SwiftData — для хранения.
@MainActor
@Observable
final class ExpenseStore {
    static let shared = ExpenseStore()

    private(set) var expenses: [Expense] = []
    private(set) var debts: [Debt] = []

    /// Псевдо-карта «Наличные»: кошелёк, куда уходят снятия в банкомате.
    static let cashCard = "cash"

    /// Учитывать наличные отдельным кошельком: снятие в банкомате — не трата, тратой будут покупки за наличные.
    var cashTracking: Bool = Account.defaults.bool(forKey: "cashTracking") {
        didSet { defaults.set(cashTracking, forKey: "cashTracking") }
    }
    /// Сколько было в кошельке на дату `cashBaseDate` (вписали вручную).
    var cashBase: Double = Account.defaults.double(forKey: "cashBase") {
        didSet { defaults.set(cashBase, forKey: "cashBase") }
    }
    var cashBaseDate: Date = Account.defaults.object(forKey: "cashBaseDate") as? Date ?? .distantPast {
        didSet { defaults.set(cashBaseDate, forKey: "cashBaseDate") }
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var context: ModelContext { container.mainContext }
    @ObservationIgnored private let defaults = Account.defaults

    private init() {
        do {
            if Account.current == .demo {
                // Демо — отдельный файл. Основной аккаунт — хранилище по умолчанию, как до появления аккаунтов.
                try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
                container = try ModelContainer(for: Expense.self, Debt.self, configurations: ModelConfiguration(url: Account.demoStoreURL))
            } else {
                container = try ModelContainer(for: Expense.self, Debt.self)
            }
        } catch {
            // Если база повреждена — работаем в памяти, чтобы приложение не падало.
            container = try! ModelContainer(for: Expense.self, Debt.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        reload()
        fillMissingBalances()
        resetWrongBrands()
        moveMunisToLoans()
        moveBillTitles()
        removeUndatedImportDuplicates()
        // Обе проверки — всегда (через «||» вторая не запускалась бы, если первая что-то нашла).
        let learned = learnOwnNameFromStatements()
        let applied = applyOwnRules()
        if learned || applied {
            try? context.save()
            reload()
        }
        fillTransferKinds()
        // Правила поиска пар меняются — уже записанные переводы перепроверяем при каждом запуске.
        linkInternalTransfers()
        #if DEBUG
        // `-cardBank 4503:aloqabank:uzcard` — задать банк карты при установке с компьютера.
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-cardBank"), index + 1 < args.count {
            for item in args[index + 1].split(separator: ",") {
                let parts = item.split(separator: ":").map(String.init)
                guard parts.count >= 2 else { continue }
                var meta = meta(parts[0])
                meta.bank = parts[1]
                if parts.count > 2 { meta.network = parts[2] }
                setMeta(meta, for: parts[0])
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-seedExpenses") && expenses.isEmpty { seedDemo() }
        #endif
        if DemoMode.isOn && expenses.isEmpty {
            seedDemo()
            DemoMode.firstLaunchSetup()
        }
    }

    #if DEBUG
    /// `-testExpenseParse`: прогоняет примеры через ИИ и печатает результат в консоль.
    static func testParse() async {
        let samples = [
            "HUMOCARD *4521: oplata 45000.00 UZS; KORZINKA SUPERMARKET SERGELI; 03.10.26 14:22; Dostupno: 1234567.00 UZS",
            "Karta *8812: Pokupka 128 500,00 UZS. YANDEX.GO. Balans: 2 345 000,00 UZS",
            "Kod podtverzhdeniya: 482913. Nikomu ne soobshayte",
            "UZCARD *1111 Popolnenie 8 500 000.00 UZS, otpravitel: OOO MEGA SOFT. Balans 9 100 000.00",
            "обед 45 тысяч, такси 18 и кофе 25",
        ]
        for sample in samples {
            do {
                let drafts = try await ExpenseParser.parse(sample, config: AppSettings.shared.aiConfig)
                print("EXPTEST \(sample.prefix(40)) → \(drafts.map { "\($0.title) \($0.amount) \($0.currency) \($0.category.rawValue) income=\($0.isIncome) \($0.date)" })")
            } catch {
                print("EXPTEST \(sample.prefix(40)) → error \(error)")
            }
        }
        do {
            let a = try await ExpenseAnalyzer.analyze(month: month(containing: .now), store: shared, config: AppSettings.shared.aiConfig)
            print("EXPTEST analysis: \(a.summary)")
            for i in a.insights { print("EXPTEST  • \(i.title) — \(i.detail) [\(i.saving)]") }
        } catch { print("EXPTEST analysis error \(error)") }
    }

    #endif

    /// Демо-данные: симулятор (`-seedExpenses`) и Hamyon Demo для съёмки рекламы.
    private func seedDemo() {
        let cal = Calendar.current
        func at(_ daysAgo: Int, _ hour: Int) -> Date {
            cal.date(bySettingHour: hour, minute: 15, second: 0, of: cal.date(byAdding: .day, value: -daysAgo, to: .now)!)!
        }
        let rows: [(String, Double, ExpenseCategory, Int, Int)] = [
            ("Korzinka", 186_000, .groceries, 0, 10), ("Yandex Go", 24_000, .transport, 0, 9),
            ("Кофе", 28_000, .cafe, 1, 11), ("Wolt", 96_000, .cafe, 1, 20), ("Yandex Go", 31_000, .transport, 1, 19),
            ("Beeline", 65_000, .connection, 2, 12), ("Uzum Market", 340_000, .shopping, 3, 15),
            ("Аптека", 54_000, .health, 4, 18), ("YouTube Premium", 39_000, .subscriptions, 5, 8),
            ("Yandex Go", 27_000, .transport, 5, 9), ("Кофе", 28_000, .cafe, 6, 11),
        ]
        add(rows.map { ExpenseDraft(title: $0.0, amount: $0.1, category: $0.2, date: at($0.3, $0.4)) }, source: .manual)
        add([ExpenseDraft(title: "Зарплата", amount: 9_000_000, category: .income, isIncome: true, date: at(2, 10))], source: .manual)
    }

    /// Hamyon Demo: начать съёмку заново — те же демо-данные, SMS снова с первого магазина.
    func resetDemo() {
        guard DemoMode.isOn else { return }
        for expense in expenses { context.delete(expense) }
        for debt in debts { context.delete(debt) }
        save()
        Account.defaults.removeObject(forKey: "demoSMSIndex")
        seedDemo()
    }

    func reload() {
        reloadLog()
        let descriptor = FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        expenses = (try? context.fetch(descriptor)) ?? []
        debts = (try? context.fetch(FetchDescriptor<Debt>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
    }

    // MARK: - Изменения

    /// Возвращает сохранённые операции. Повтор той же SMS пропускается.
    @discardableResult
    func add(_ drafts: [ExpenseDraft], source: ExpenseSource, rawText: String? = nil) -> [Expense] {
        if let rawText, expenses.contains(where: { $0.rawText == rawText }) { return [] }
        let added = drafts.filter { $0.amount > 0 }.map { draft in
            var draft = draft
            if let learned = learnedCategory(for: draft.title), !draft.isIncome { draft.category = learned }
            let expense = Expense(draft: draft, source: source, rawText: rawText)
            context.insert(expense)
            return expense
        }
        save()
        fillTransferKinds()
        learnOwnNameFromStatements()
        if applyOwnRules() { save() }
        linkInternalTransfers()
        return added
    }

    func update(_ expense: Expense, with draft: ExpenseDraft) {
        // Для переводов не запоминаем: «Payme» — это сервис, а не магазин, и правило
        // «Payme → Красота» испортило бы категорию всех будущих переводов.
        if draft.category != expense.category, !draft.title.trimmed.isEmpty, !expense.isTransfer {
            learn(draft.title, draft.category)
        }
        let renamed = draft.title.trimmed != expense.title
        expense.apply(draft)
        // Указали, кому перевод, прямо в карточке — вопрос «Кому?» больше не нужен.
        if expense.isTransfer, expense.person != nil { expense.reviewed = true }
        // Новое название — бренд определим заново.
        if renamed { expense.brand = nil }
        save()
    }

    func delete(_ expense: Expense) {
        context.delete(expense)
        save()
        linkInternalTransfers()
    }

    // MARK: - Переводы между своими картами

    /// Ушло с одной вашей карты и в ту же минуту пришло на другую — это не расход и не доход.
    /// Обе карты ваши: банк присылает SMS только о ваших картах. Разница сумм — комиссия.
    func linkInternalTransfers() {
        var changed = false
        // Строки выписки без типа («Перевод на карту», «SQB» с пометкой «доход») — тоже кандидаты: из-за них
        // переводы TBC → SQB в одну минуту не склеивались. Найденной паре ставим тип «перевод».
        let outs = expenses.filter { $0.kind == .transferOut || ($0.kind == nil && !$0.isIncome && !$0.isCash) }
        let ins = expenses.filter { $0.kind == .transferIn || ($0.kind == nil && $0.isIncome && !$0.isCash) }
        var paired = Set<UUID>()
        for out in outs.sorted(by: { $0.date < $1.date }) {
            let match = ins.first { incoming in
                !paired.contains(incoming.id) && !incoming.manualInternal
                    && incoming.card != nil && out.card != nil && incoming.card != out.card
                    && abs(incoming.date.timeIntervalSince(out.date)) <= 180
                    && out.amount >= incoming.amount
                    && out.amount <= incoming.amount * 1.03 + 1000
                    && incoming.currency == out.currency
            }
            if let match {
                paired.insert(match.id)
                paired.insert(out.id)
                let fee = out.amount - match.amount
                if !out.isInternal || out.fee != fee { out.isInternal = true; out.fee = fee; changed = true }
                if !match.isInternal { match.isInternal = true; changed = true }
                for expense in [out, match] where expense.kind == nil {
                    expense.kindRaw = (expense.isIncome ? ExpenseKind.transferIn : .transferOut).rawValue
                    expense.categoryRaw = ExpenseCategory.transfers.rawValue
                    changed = true
                }
            }
        }
        // Пара распалась (удалили одну из операций) — снова обычный перевод.
        for expense in expenses where expense.isInternal && !expense.manualInternal && !paired.contains(expense.id) {
            expense.isInternal = false
            expense.fee = 0
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Старые SMS без типа операции

    @ObservationIgnored private var classifying = false

    /// SMS, записанные до появления типов операций, — разбираем пачками и находим переводы между картами.
    func classifyOldSMS(config: AIConfig) async {
        guard !classifying, !config.apiKey.trimmed.isEmpty else { return }
        let pending = expenses.filter { $0.kindRaw == nil && $0.rawText != nil }
        guard !pending.isEmpty else { return }
        classifying = true
        defer { classifying = false }
        for start in stride(from: 0, to: pending.count, by: 25) {
            let chunk = Array(pending[start..<min(start + 25, pending.count)])
            guard let details = try? await ExpenseParser.details(for: chunk.compactMap(\.rawText), config: config) else { return }
            for (index, expense) in chunk.enumerated() {
                expense.card = expense.card ?? expense.rawText.flatMap(ExpenseParser.cardDigits(in:))
                guard let detail = details[index] else { expense.kindRaw = ""; continue }
                expense.kindRaw = detail.kind.rawValue
                expense.isIncome = detail.kind.isIncoming
                if !detail.counterparty.isEmpty { expense.counterparty = detail.counterparty }
                if !detail.channel.isEmpty { expense.channel = detail.channel }
                if expense.isTransfer {
                    expense.categoryRaw = ExpenseCategory.transfers.rawValue
                } else if expense.isIncome {
                    expense.categoryRaw = ExpenseCategory.income.rawValue
                } else if detail.category != .income {
                    expense.categoryRaw = detail.category.rawValue
                }
            }
            save()
        }
        linkInternalTransfers()
    }

    /// Переводы месяца: кому/через что, сколько ушло и пришло, сколько гоняли между своими картами.
    func transfers(in month: DateInterval, card: String? = nil) -> TransferSummary {
        var summary = TransferSummary()
        var groups: [String: TransferSummary.Group] = [:]
        for expense in expenses(in: month, card: card) where expense.isTransfer && expense.currency == "UZS" {
            if expense.isInternal {
                if expense.kind == .transferOut { summary.internalAmount += expense.amount }
                summary.fees += expense.fee
                continue
            }
            if expense.kind == .transferIn { summary.received += expense.amount } else { summary.sent += expense.amount }
            guard expense.kind == .transferOut else { continue }
            let name = expense.person ?? expense.title
            let key = name.lowercased()
            var group = groups[key] ?? .init(name: name, channel: expense.channel, brand: expense.brand)
            group.count += 1
            group.amount += expense.amount
            groups[key] = group
        }
        summary.groups = groups.values.sorted { $0.amount > $1.amount }
        return summary
    }

    func save() {
        try? context.save()
        reload()
        WidgetSnapshot.update(from: self)
    }

    var modelContext: ModelContext { context }

    // MARK: - Бренды для логотипов

    @ObservationIgnored private var fillingBrands = false

    /// Операции без бренда (добавленные вручную или до появления логотипов) — одним запросом к ИИ.
    func fillMissingBrands(config: AIConfig) async {
        guard !fillingBrands, !config.apiKey.trimmed.isEmpty else { return }
        let missing = expenses.filter { $0.brand == nil }
        let titles = Array(Set(missing.map(\.title))).filter { !$0.isEmpty }.prefix(150)
        guard !titles.isEmpty else { return }
        fillingBrands = true
        defer { fillingBrands = false }
        guard let brands = try? await ExpenseParser.brands(for: Array(titles), config: config) else { return }
        for expense in missing where titles.contains(expense.title) {
            expense.brand = brands[expense.title] ?? ""
        }
        save()
    }

    /// Разово: бренд — платёжное приложение вместо компании («Payme» у WB Taxi) или пусто —
    /// сбрасываем, ИИ определит заново по новому правилу.
    private func resetWrongBrands() {
        guard !defaults.bool(forKey: "brandsReset2") else { return }
        for expense in expenses {
            let brand = expense.brand?.lowercased() ?? ""
            let text = [expense.title, expense.counterparty ?? "", expense.channel ?? ""].joined(separator: " ").lowercased()
            // Бренд, которого нет в названии («Yandex Go» у «OOO WB TAXI OPLATA», «Payme» у такси), — ошибка ИИ.
            let word = brand.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? brand
            let foreign = !brand.isEmpty && word.count >= 2 && !text.contains(word)
            if (brand.isEmpty && expense.person == nil) || foreign { expense.brand = nil }
        }
        try? context.save()
        defaults.set(true, forKey: "brandsReset2")
    }

    /// Строки из выписок с категорией «Переводы», но без типа: тип — по направлению,
    /// получатель — из названия, если это имя («Rabbimov Bashirjon»). Тогда они видны в «Людях».
    func fillTransferKinds() {
        var changed = false
        for expense in expenses where expense.kindRaw == nil || expense.kindRaw == "" {
            guard expense.category == .transfers else { continue }
            expense.kindRaw = (expense.isIncome ? ExpenseKind.transferIn : .transferOut).rawValue
            changed = true
        }
        for expense in expenses where expense.isTransfer && expense.person == nil && expense.source == .statement
            && Expense.looksLikeName(expense.title) {
            expense.counterparty = expense.title
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Разово: в большом импорте строки без даты получали время самого импорта («сегодня 00:28»)
    /// и не узнавались как повтор. Удаляем такие, у которых есть двойник с той же суммой, направлением и картой.
    private func removeUndatedImportDuplicates() {
        guard !defaults.bool(forKey: "undatedCleanup1") else { return }
        let imported = expenses.filter { $0.source == .statement }
        let batches = Dictionary(grouping: imported) { Int($0.createdAt.timeIntervalSince1970) }
        var removed = 0
        for (_, batch) in batches where batch.count >= 20 {
            for expense in batch {
                let gap = expense.createdAt.timeIntervalSince(expense.date)
                guard gap >= 0, gap <= 1800 else { continue }
                let twin = expenses.contains { other in
                    other.id != expense.id && abs(other.amount - expense.amount) < 0.01 && other.isIncome == expense.isIncome
                        && (other.card == nil || expense.card == nil || other.card == expense.card)
                        && abs(other.date.timeIntervalSince(expense.date)) > 1800
                }
                if twin {
                    context.delete(expense)
                    removed += 1
                }
            }
        }
        if removed > 0 { try? context.save() }
        defaults.set(true, forKey: "undatedCleanup1")
    }

    /// Разово: у пользователя платежи «MUNIS» в SMS — погашение займа Payme, а не коммуналка.
    /// Переносим в «Кредиты и рассрочка» и запоминаем правило для новых SMS.
    private func moveMunisToLoans() {
        guard !defaults.bool(forKey: "munisLoans1") else { return }
        let titles: Set<String> = ["munis", "payme munis"]
        for expense in expenses where titles.contains(expense.title.trimmed.lowercased()) && !expense.isIncome {
            expense.categoryRaw = ExpenseCategory.loans.rawValue
        }
        for title in titles { rules[title] = ExpenseCategory.loans.rawValue }
        try? context.save()
        defaults.set(true, forKey: "munisLoans1")
    }

    // MARK: - Журнал запусков из «Команд»

    /// Последние вызовы действия «Добавить расход из SMS» — чтобы было видно, доходят ли SMS.
    private(set) var smsLog: [String] = Account.defaults.stringArray(forKey: "smsLog") ?? []

    func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm:ss"
        smsLog.insert("\(f.string(from: .now)) \(line)", at: 0)
        smsLog = Array(smsLog.prefix(30))
        defaults.set(smsLog, forKey: "smsLog")
    }

    func reloadLog() {
        smsLog = defaults.stringArray(forKey: "smsLog") ?? []
    }

    // MARK: - Уже обработанные SMS

    /// SMS, по которым уже есть операция или которые ИИ признал не покупкой (коды, отказы).
    /// Команда «Команд» каждый раз находит одни и те же сообщения — их не нужно снова отправлять в ИИ.
    func isProcessed(_ rawText: String) -> Bool {
        expenses.contains { $0.rawText == rawText } || skipped.contains(Self.fingerprint(rawText))
    }

    func markSkipped(_ rawText: String) {
        var set = skipped
        set.insert(Self.fingerprint(rawText))
        // Храним только последние ~500, чтобы UserDefaults не рос бесконечно.
        defaults.set(Array(set.suffix(500)), forKey: "skippedSMS")
    }

    private var skipped: Set<String> { Set(defaults.stringArray(forKey: "skippedSMS") ?? []) }

    private static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    // MARK: - Запоминание категорий

    /// Исправили категорию у «Korzinka» один раз — дальше она подставляется сама.
    private var rules: [String: String] {
        get { defaults.dictionary(forKey: "expenseCategoryRules") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "expenseCategoryRules") }
    }

    private func learn(_ title: String, _ category: ExpenseCategory) {
        rules[title.trimmed.lowercased()] = category.rawValue
    }

    private func learnedCategory(for title: String) -> ExpenseCategory? {
        rules[title.trimmed.lowercased()].flatMap(ExpenseCategory.init(rawValue:))
    }

    // MARK: - Выборки

    func expenses(in month: DateInterval, card: String? = nil) -> [Expense] {
        expenses(in: month, cards: card.map { [$0] } ?? [])
    }

    /// Операции выбранных карт; пустой набор — все карты.
    func expenses(in month: DateInterval, cards: Set<String>) -> [Expense] {
        expenses.filter { month.start <= $0.date && $0.date < month.end && (cards.isEmpty || $0.card.map(cards.contains) == true) }
    }

    // MARK: - Свои карты

    /// Ваши карты: из SMS (чаще используемые первыми) и добавленные вручную.
    var cards: [String] {
        let counts = Dictionary(grouping: expenses.compactMap(\.card).filter { $0 != Self.cashCard }, by: { $0 }).mapValues(\.count)
        let fromSMS = counts.keys.sorted { counts[$0]! > counts[$1]! }
        let manual = cardMeta.filter { $0.value.manual && counts[$0.key] == nil }.keys.sorted()
        return fromSMS + manual
    }

    /// Последний известный остаток на каждой карте — из самой свежей SMS с «Qoldiq/Balans».
    var cardBalances: [(card: String, balance: Double, date: Date)] {
        var latest: [String: (Double, Date)] = [:]
        for expense in expenses {
            guard let card = expense.card, let balance = expense.balance, expense.currency == "UZS" else { continue }
            if let known = latest[card], known.1 >= expense.date { continue }
            latest[card] = (balance, expense.date)
        }
        // Остаток со скриншота или вписанный вручную — если он новее последней SMS.
        for (card, meta) in cardMeta {
            guard let balance = meta.balance else { continue }
            let date = meta.balanceDate ?? .distantPast
            if let known = latest[card], known.1 >= date { continue }
            latest[card] = (balance, date)
        }
        return cards.compactMap { card in latest[card].map { (card, $0.0, $0.1) } }
    }

    /// Карты для подсказки ИИ: номер, банк, платёжная система, ваше название.
    var cardOptions: [ExpenseParser.CardOption] {
        cards.map { card in
            let meta = meta(card)
            let parts = [Bank.find(meta.bank)?.name, meta.network.flatMap(CardNetwork.init(rawValue:))?.title,
                         meta.name.isEmpty ? nil : "«\(meta.name)»"].compactMap { $0 }
            return .init(digits: card, label: parts.joined(separator: " "))
        } + (cashTracking ? [.init(digits: Self.cashCard, label: "cash wallet — use when the user paid in cash (наличными, naqd)")] : [])
    }

    func setBalance(_ balance: Double, date: Date, for card: String) {
        var meta = meta(card)
        meta.balance = balance
        meta.balanceDate = date
        setMeta(meta, for: card)
    }

    /// Такая операция уже есть — и она ещё не «занята» другой строкой импорта (сверка один к одному:
    /// два одинаковых платежа за автобус с разницей в 9 минут — это две операции).
    func matchExisting(_ draft: ExpenseDraft, used: inout Set<UUID>) -> Bool {
        let calendar = Calendar.current
        let hasTime = calendar.component(.hour, from: draft.date) != 12 || calendar.component(.minute, from: draft.date) != 0
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: .now)!
        let candidates = expenses.filter { expense in
            guard !used.contains(expense.id), abs(expense.amount - draft.amount) < 0.01, expense.isIncome == draft.isIncome,
                  expense.card == nil || draft.card == nil || expense.card == draft.card else { return false }
            // Дата в выписке не нашлась — крупную сумму ищем за последний год (мелкие вроде 1 700 повторяются часто).
            if draft.dateUnknown { return draft.amount >= 10_000 && expense.date >= yearAgo }
            return hasTime ? abs(expense.date.timeIntervalSince(draft.date)) <= 900
                           : calendar.isDate(expense.date, inSameDayAs: draft.date)
        }
        guard let match = candidates.min(by: { abs($0.date.timeIntervalSince(draft.date)) < abs($1.date.timeIntervalSince(draft.date)) })
        else { return false }
        used.insert(match.id)
        return true
    }

    /// Такая операция уже есть (пришла по SMS или из прошлого импорта): та же карта, сумма, направление и время.
    func isDuplicate(_ draft: ExpenseDraft) -> Bool {
        let calendar = Calendar.current
        let hasTime = calendar.component(.hour, from: draft.date) != 12 || calendar.component(.minute, from: draft.date) != 0
        return expenses.contains { expense in
            abs(expense.amount - draft.amount) < 0.01
                && expense.isIncome == draft.isIncome
                && (expense.card == nil || draft.card == nil || expense.card == draft.card)
                && (hasTime ? abs(expense.date.timeIntervalSince(draft.date)) <= 600
                            : calendar.isDate(expense.date, inSameDayAs: draft.date))
        }
    }

    /// Старые записи без остатка — достаём его из сохранённого текста SMS.
    func fillMissingBalances() {
        var changed = false
        for expense in expenses where expense.balance == nil {
            if let raw = expense.rawText, let balance = ExpenseParser.balance(in: raw) {
                expense.balance = balance
                changed = true
            }
        }
        if changed { save() }
    }

    /// Название, банк и платёжная система карт (UserDefaults, JSON).
    private(set) var cardMeta: [String: CardMeta] = ExpenseStore.loadCardMeta()

    private static func loadCardMeta() -> [String: CardMeta] {
        let defaults = Account.defaults
        var meta = (defaults.data(forKey: "cardMeta")).flatMap { try? JSONDecoder().decode([String: CardMeta].self, from: $0) } ?? [:]
        // Старые названия карт из первой версии.
        for (card, name) in defaults.dictionary(forKey: "cardNames") as? [String: String] ?? [:] where meta[card] == nil {
            meta[card] = CardMeta(name: name)
        }
        return meta
    }

    func meta(_ card: String) -> CardMeta { cardMeta[card] ?? CardMeta() }

    func setMeta(_ meta: CardMeta, for card: String) {
        cardMeta[card] = meta
        defaults.set(try? JSONEncoder().encode(cardMeta), forKey: "cardMeta")
    }

    func removeManualCard(_ card: String) {
        cardMeta[card] = nil
        defaults.set(try? JSONEncoder().encode(cardMeta), forKey: "cardMeta")
    }

    var cardNames: [String: String] { cardMeta.mapValues(\.name) }

    func cardTitle(_ card: String) -> String {
        if card == Self.cashCard { return String(localized: "Наличные") }
        let meta = meta(card)
        let name = meta.name.isEmpty ? (Bank.find(meta.bank)?.name ?? "") : meta.name
        return name.isEmpty ? "•\(card)" : "\(name) •\(card)"
    }

    func setCardName(_ name: String, for card: String) {
        var meta = meta(card)
        meta.name = name.trimmed
        setMeta(meta, for: card)
    }

    /// Суммы в сумах; операции в другой валюте считаются отдельно.
    func totals(in month: DateInterval, card: String? = nil) -> MonthTotals {
        totals(in: month, cards: card.map { [$0] } ?? [])
    }

    /// Суммы по выбранным картам; пустой набор — все карты.
    func totals(in month: DateInterval, cards: Set<String>) -> MonthTotals {
        var totals = MonthTotals()
        for expense in expenses(in: month, cards: cards) {
            if expense.isInternal {
                // Перевод между своими картами не трата — кроме комиссии.
                if expense.fee > 0 {
                    totals.spent += expense.fee
                    totals.byCategory[.fees, default: 0] += expense.fee
                }
                continue
            }
            // Снятие наличных при включённом кошельке — деньги просто переложили в карман;
            // тратой станут покупки за наличные.
            if expense.kind == .cash && cashTracking && !expense.isIncome { continue }
            var amount = expense.amount
            if expense.currency != "UZS" {
                if !expense.isIncome { totals.foreign[expense.currency, default: 0] += expense.amount }
                // Валюту считаем в сумах по курсу ЦБ; курса нет — показываем отдельно.
                guard let rate = Rates.shared.rate(expense.currency) else { continue }
                amount *= rate
            }
            if expense.isIncome {
                totals.income += amount
            } else {
                totals.spent += amount
                totals.byCategory[expense.category, default: 0] += amount
            }
        }
        return totals
    }

    nonisolated static func month(containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: .month, for: date)!
    }
}

struct TransferSummary {
    struct Group: Identifiable {
        var id: String { name.lowercased() }
        let name: String
        let channel: String?
        let brand: String?
        var count = 0
        var amount: Double = 0
    }

    var sent: Double = 0
    var received: Double = 0
    var internalAmount: Double = 0
    var fees: Double = 0
    var groups: [Group] = []

    var isEmpty: Bool { sent == 0 && received == 0 && internalAmount == 0 }
}

struct MonthTotals {
    var spent: Double = 0
    var income: Double = 0
    var byCategory: [ExpenseCategory: Double] = [:]
    var foreign: [String: Double] = [:]

    var sortedCategories: [(category: ExpenseCategory, amount: Double)] {
        byCategory.map { ($0.key, $0.value) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }
}
