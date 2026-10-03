import BackgroundTasks
import PhotosUI
import SwiftUI
import UserNotifications

/// Чтение выписки — отдельно от экрана: экран импорта можно закрыть или свернуть приложение,
/// ИИ дочитает файл, а по готовности придёт уведомление «проверьте и добавьте».
@MainActor
@Observable
final class ImportJob {
    static let shared = ImportJob()

    enum Phase: Equatable {
        case pick
        case preparing
        case reading(Int, Int)
        case review
        case failed(String)
    }

    struct Row: Identifiable {
        var id = UUID()
        var draft: ExpenseDraft
        var selected: Bool
        let duplicate: Bool
        /// Перевод себе: так написано в выписке, карта другой стороны — ваша, или отметили вручную.
        var own: Bool { draft.internalTransfer }
    }

    /// Часть для ИИ и из какого файла она: строки разных файлов сверяем мягче, чем строки одного файла.
    typealias Group = (source: Int, files: [AIClient.Attachment])

    /// Сколько повторов между файлами убрали (одна операция в выписке банка и в истории Payme).
    private(set) var crossDuplicates = 0

    struct FoundBalance: Identifiable {
        var id: String { card }
        let card: String
        let amount: Double
        let date: Date
        var apply = true
    }

    private(set) var phase: Phase = .pick
    var rows: [Row] = []
    var balances: [FoundBalance] = []
    var defaultCard: String?
    /// Когда начали читать текущую часть и сколько операций уже нашли — для прогресса.
    private(set) var partStarted = Date.now
    private(set) var foundSoFar = 0
    /// Сколько экранов импорта сейчас открыто — плашку прогресса над таббаром показываем, только когда их нет.
    var visibleScreens = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .preparing, .reading: true
        default: false
        }
    }

    /// Доля готовности для плашки и системного прогресса.
    var progress: Double {
        guard case .reading(let index, let total) = phase else { return 0 }
        return Double(index - 1) / Double(max(total, 1))
    }

    // MARK: - Запуск

    func readPhotos(_ items: [PhotosPickerItem]) {
        run {
            var files: [AIClient.Attachment] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let file = Self.prepareImage(data) {
                    files.append(file)
                }
            }
            // Скриншоты одного списка — по 4 за запрос: ИИ видит, где они перекрываются.
            return stride(from: 0, to: files.count, by: 4).map { (0, Array(files[$0..<min($0 + 4, files.count)])) }
        }
    }

    func readVideo(_ item: PhotosPickerItem) {
        run {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw VideoFrames.Failure.unreadable }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let frames = try await VideoFrames.extract(from: movie.url)
            // Кадры подряд — по 6 за запрос.
            return stride(from: 0, to: frames.count, by: 6).map { (0, Array(frames[$0..<min($0 + 6, frames.count)])) }
        }
    }

    func readFiles(_ urls: [URL]) {
        run {
            var files: [Group] = []
            for (source, url) in urls.enumerated() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    files.append((source, [.init(mimeType: "application/pdf", data: data)]))
                } else if ext == "xlsx" || ext == "xls" {
                    // Excel ИИ не читает — распаковываем таблицу сами и отдаём текстом, частями.
                    let table = try SpreadsheetReader.table(fromXLSX: data)
                    for part in SpreadsheetReader.chunks(table) {
                        files.append((source, [.init(mimeType: "text/csv", data: Data(part.utf8))]))
                    }
                } else if ext == "csv" {
                    for part in SpreadsheetReader.chunks(SpreadsheetReader.table(fromCSV: data)) {
                        files.append((source, [.init(mimeType: "text/csv", data: Data(part.utf8))]))
                    }
                } else if let file = Self.prepareImage(data) {
                    files.append((source, [file]))
                }
            }
            return files
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        BackgroundRun.finish(success: false)
        reset()
    }

    func reset() {
        phase = .pick
        rows = []
        balances = []
        foundSoFar = 0
        crossDuplicates = 0
    }

    func save() {
        let store = ExpenseStore.shared
        store.add(rows.filter(\.selected).map(\.draft), source: .statement)
        for found in balances where found.apply {
            store.setBalance(found.amount, date: found.date, for: found.card)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        reset()
    }

    // MARK: - Чтение

    /// Готовим части (без сети) и читаем их по очереди. Каждая группа — один запрос к ИИ.
    private func run(_ prepare: @escaping @MainActor () async throws -> [Group]) {
        task?.cancel()
        phase = .preparing
        task = Task {
            do {
                let groups = try await prepare()
                try await read(groups)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
                BackgroundRun.finish(success: false)
            }
        }
    }

    private func read(_ groups: [Group]) async throws {
        guard !groups.isEmpty else { throw ImportFailure.nothing }
        let settings = AppSettings.shared
        let store = ExpenseStore.shared
        guard !settings.aiConfig.apiKey.trimmed.isEmpty else { throw ImportFailure.noKey }

        // Свернули приложение — iOS даёт дочитать (на iOS 26+ — с системным прогрессом).
        BackgroundRun.start(total: groups.count)
        var drafts: [(draft: ExpenseDraft, source: Int)] = []
        foundSoFar = 0
        var found: [String: FoundBalance] = [:]
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            partStarted = .now
            phase = .reading(index + 1, groups.count)
            BackgroundRun.update(done: index, total: groups.count)
            let result = try await ExpenseParser.parseStatement(group.files, config: settings.aiConfig, cards: store.cardOptions)
            var items = result.drafts
            for i in items.indices where items[i].card == nil { items[i].card = defaultCard }
            drafts += items.map { ($0, group.source) }
            foundSoFar = drafts.count
            if let balance = result.balance, let card = result.card ?? defaultCard {
                let date = result.balanceDate ?? .now
                if found[card].map({ $0.date < date }) ?? true { found[card] = FoundBalance(card: card, amount: balance, date: date) }
            }
        }
        let (unique, cross) = Self.deduplicate(drafts)
        crossDuplicates = cross
        var used = Set<UUID>()
        rows = unique.sorted { $0.date > $1.date }.map { draft in
            var draft = draft
            // Карта другой стороны — ваша (или имя — ваше): это перевод себе.
            if !draft.internalTransfer, draft.kind == .transferIn || draft.kind == .transferOut,
               store.isOwnCounterpart(card: draft.counterpartCard, name: draft.counterparty) {
                draft.internalTransfer = true
            }
            let duplicate = store.matchExisting(draft, used: &used)
            return Row(draft: draft, selected: !duplicate, duplicate: duplicate)
        }
        balances = found.values.sorted { $0.card < $1.card }
        phase = .review
        BackgroundRun.finish(success: true)
        notifyIfAway()
    }

    /// Повторы: внутри одного файла — только полностью одинаковые строки (перекрытие кадров);
    /// между файлами — та же сумма и направление, совместимая карта и время в пределах 15 минут
    /// (или тот же день, если время не указано). Каждая строка «поглощает» не больше одной.
    static func deduplicate(_ items: [(draft: ExpenseDraft, source: Int)]) -> ([ExpenseDraft], Int) {
        let calendar = Calendar.current
        func hasTime(_ date: Date) -> Bool {
            calendar.component(.hour, from: date) != 12 || calendar.component(.minute, from: date) != 0
        }
        var kept: [(draft: ExpenseDraft, source: Int, matched: Bool)] = []
        var cross = 0
        for item in items {
            let d = item.draft
            func same(_ k: ExpenseDraft) -> Bool {
                abs(k.amount - d.amount) < 0.01 && k.isIncome == d.isIncome && k.currency == d.currency
                    && (k.card == nil || d.card == nil || k.card == d.card)
            }
            // Тот же файл: перекрытие соседних кадров — время совпадает до минуты.
            if kept.contains(where: { $0.source == item.source && same($0.draft) && abs($0.draft.date.timeIntervalSince(d.date)) < 60 }) {
                continue
            }
            // Другой файл: та же операция из другого приложения.
            if let index = kept.firstIndex(where: { k in
                k.source != item.source && !k.matched && same(k.draft)
                    && (hasTime(k.draft.date) && hasTime(d.date)
                        ? abs(k.draft.date.timeIntervalSince(d.date)) <= 900
                        : calendar.isDate(k.draft.date, inSameDayAs: d.date))
            }) {
                kept[index].matched = true
                // Из второго источника берём то, чего не было в первом: карту другой стороны, получателя.
                if kept[index].draft.counterpartCard == nil { kept[index].draft.counterpartCard = d.counterpartCard }
                if (kept[index].draft.counterparty ?? "").isEmpty { kept[index].draft.counterparty = d.counterparty }
                if d.internalTransfer { kept[index].draft.internalTransfer = true }
                cross += 1
                continue
            }
            kept.append((d, item.source, false))
        }
        return (kept.map(\.draft), cross)
    }

    /// Пометить строку как перевод себе (или снять) — и так же все строки с той же картой или именем другой стороны.
    func setOwn(_ own: Bool, for rowID: UUID) {
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        let card = row.draft.counterpartCard
        let name = row.draft.counterparty?.trimmed.lowercased()
        for index in rows.indices {
            let draft = rows[index].draft
            let sameCard = card != nil && draft.counterpartCard == card
            let sameName = !(name ?? "").isEmpty && draft.counterparty?.trimmed.lowercased() == name
            if rows[index].id == rowID || sameCard || sameName {
                rows[index].draft.internalTransfer = own
            }
        }
        if own { ExpenseStore.shared.learnOwn(card: card, name: row.draft.counterparty) }
    }

    /// Приложение свёрнуто или экран импорта закрыт — сообщаем, что можно проверять.
    private func notifyIfAway() {
        guard UIApplication.shared.applicationState != .active || visibleScreens == 0 else { return }
        let fresh = rows.filter { !$0.duplicate }.count
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Выписка прочитана")
        content.body = fresh > 0 ? String(localized: "Новых операций: \(fresh). Проверьте и добавьте.")
                                 : String(localized: "Новых операций нет — всё уже было в Hamyon.")
        content.sound = .default
        content.userInfo = ["route": "import"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "import-done", content: content, trigger: nil))
    }

    enum ImportFailure: LocalizedError {
        case nothing, noKey

        var errorDescription: String? {
            switch self {
            case .nothing: String(localized: "Не удалось открыть файл.")
            case .noKey: String(localized: "Добавьте ключ Gemini в настройках — без ИИ выписку не прочитать.")
            }
        }
    }

    /// Скриншот → JPEG не больше 2000 px по длинной стороне: так быстрее и дешевле, а текст читается.
    static func prepareImage(_ data: Data) -> AIClient.Attachment? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height) * image.scale
        let scale = min(1, 2000 / longest)
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return .init(mimeType: "image/jpeg", data: jpeg)
    }
}

/// Работа в фоне. iOS 26+: системная «продолжающаяся задача» с прогрессом на экране блокировки —
/// можно свернуть Hamyon, чтение не прервётся. Раньше — обычные ~30 секунд в фоне.
@MainActor
enum BackgroundRun {
    static let identifier = "uz.fayzullo.hamyon.import.statement"

    private static var legacy: UIBackgroundTaskIdentifier = .invalid
    private static var registered = false
    private static var total = 1
    private static var system: AnyObject?

    static func start(total: Int) {
        self.total = total
        if legacy == .invalid {
            legacy = UIApplication.shared.beginBackgroundTask(withName: "statement-import") { finishLegacy() }
        }
        if #available(iOS 26.0, *) { startContinued() }
    }

    static func update(done: Int, total: Int) {
        if #available(iOS 26.0, *), let task = system as? BGContinuedProcessingTask {
            task.progress.totalUnitCount = Int64(total)
            task.progress.completedUnitCount = Int64(done)
            task.updateTitle(String(localized: "Hamyon читает выписку"),
                             subtitle: String(localized: "Часть \(min(done + 1, total)) из \(total)"))
        }
    }

    static func finish(success: Bool) {
        if #available(iOS 26.0, *), let task = system as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        system = nil
        finishLegacy()
    }

    private static func finishLegacy() {
        guard legacy != .invalid else { return }
        UIApplication.shared.endBackgroundTask(legacy)
        legacy = .invalid
    }

    @available(iOS 26.0, *)
    private static func startContinued() {
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                MainActor.assumeIsolated {
                    system = task
                    task.progress.totalUnitCount = Int64(total)
                    task.expirationHandler = {
                        // Система забрала время — чтение остановится, когда приложение уснёт.
                        MainActor.assumeIsolated { system = nil }
                    }
                }
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: String(localized: "Hamyon читает выписку"),
                                                       subtitle: String(localized: "Часть 1 из \(total)"))
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Плашка над таббаром, пока ИИ читает выписку в фоне (экран импорта закрыт), и когда всё готово к проверке.
struct ImportPill: View {
    @State private var job = ImportJob.shared
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        let show = job.visibleScreens == 0 && (job.isBusy || job.phase == .review)
        Group {
            if show {
                Button { navigation.sheet = .importStatement } label: {
                    HStack(spacing: 10) {
                        if job.phase == .review {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(String(localized: "Выписка прочитана — проверить"))
                        } else {
                            Image(systemName: "sparkles").geminiShimmer()
                            Text(caption)
                            Spacer(minLength: 4)
                            ProgressView(value: job.progress)
                                .tint(.green)
                                .frame(width: 60)
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glass(in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: show)
    }

    private var caption: String {
        if case .reading(let index, let total) = job.phase {
            return String(localized: "Читаю выписку · \(index) из \(total)")
        }
        return String(localized: "Готовлю файл…")
    }
}
