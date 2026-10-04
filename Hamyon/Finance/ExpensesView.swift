import Charts
import SwiftUI

/// «Расходы»: месяцы листаются свайпом; в каждом — итог, категории, ИИ-анализ и операции по дням.
struct ExpensesView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var month = ExpenseStore.month(containing: .now)
    @State private var editing: Expense?
    @State private var creating = false
    @State private var profile = Profile.shared
    @State private var profileShift: CGFloat = 0
    /// Отступ карточек «Обзора» от края экрана.
    private static let cardInset: CGFloat = 16
    private static var avatarSize: CGFloat {
        if #available(iOS 26.0, *) { 44 } else { 34 }
    }
    /// `-openProfile`: сразу профиль (проверка в симуляторе).
    @State private var showProfile = ProcessInfo.processInfo.arguments.contains("-openProfile")
    @State private var showSMSSetup = false
    @State private var showCards = false
    @State private var showImport = false
    @State private var showShare = ProcessInfo.processInfo.arguments.contains("-previewShare")
    /// Карты, которые учитываются на «Обзоре»; пустой набор — все. Выбор запоминается.
    @State private var cards = Set(Account.defaults.stringArray(forKey: "overviewCards") ?? [])

    /// От месяца первой операции до текущего.
    private var months: [DateInterval] {
        let current = ExpenseStore.month(containing: .now)
        guard let oldest = store.expenses.last?.date else { return [current] }
        var result: [DateInterval] = []
        var cursor = ExpenseStore.month(containing: oldest)
        while cursor.start <= current.start {
            result.append(cursor)
            guard let next = Calendar.current.date(byAdding: .month, value: 1, to: cursor.start) else { break }
            cursor = ExpenseStore.month(containing: next)
        }
        return result
    }

    var body: some View {
        let months = months
        // Экран один; свайпом листается только блок с суммой месяца, остальное обновляется на месте.
        MonthPage(
            month: $month,
            months: months,
            cards: $cards,
            open: open,
            onEdit: { editing = $0 },
            onConnectSMS: { showSMSSetup = true }
        )
        .background(Color(.systemGroupedBackground))
        .onChange(of: cards) { _, cards in Account.defaults.set(Array(cards), forKey: "overviewCards") }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showProfile = true } label: {
                    HStack(spacing: 8) {
                        // Высотой со стеклянную кнопку «+ …» справа (44 pt на iOS 26).
                        AvatarCircle(image: profile.photo, initials: profile.initials, size: Self.avatarSize)
                        // Имя со стрелкой — у верхнего края фото, подпись — у нижнего.
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(profile.displayName.split(separator: " ").first.map(String.init) ?? String(localized: "Профиль"))
                                    .font(.headline)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text("Профиль и настройки")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        // Иначе панель сжимает текст до нуля и остаётся только фото.
                        .fixedSize()
                    }
                    .offset(x: profileShift)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Панель ставит кнопку по-своему (на iOS 26 — 20 pt от края), а карточки начинаются в 16 pt:
                // меряем, где кнопка на самом деле, и сдвигаем фото ровно на край карточек.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX in
                    guard (0...60).contains(minX) else { return }
                    profileShift = Self.cardInset - minX
                }
                .accessibilityLabel("Профиль")
            }
            .profileButtonBackground()
            ToolbarItem(placement: .topBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Новая операция")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Поделиться итогами месяца", systemImage: "square.and.arrow.up") { showShare = true }
                    Button("Импорт: скриншоты и PDF", systemImage: "doc.viewfinder") { showImport = true }
                    Button("Подключить SMS банка", systemImage: "message") { showSMSSetup = true }
                    Button("Мои карты", systemImage: "creditcard") { showCards = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .navigationDestination(isPresented: $showProfile) { ProfileView() }
        .sheet(item: $editing) { ExpenseDetailView(expense: $0) }
        .sheet(isPresented: $creating) { ExpenseDetailView(expense: nil) }
        .sheet(isPresented: $showSMSSetup) { SMSSetupView() }
        .sheet(isPresented: $showImport) { ImportView() }
        .sheet(isPresented: $showShare) { ShareSummaryView(month: month) }
        .sheet(isPresented: $showCards) {
            NavigationStack {
                CardsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Готово") { showCards = false } }
                }
            }
        }
        .task {
            await store.classifyOldSMS(config: settings.aiConfig)
            await store.fillMissingBrands(config: settings.aiConfig)
        }
    }

    private func open(_ target: DateInterval) {
        guard months.contains(target) else { return }
        month = target
    }

}

/// «Обзор» выбранного месяца.
private struct MonthPage: View {
    @Binding var month: DateInterval
    let months: [DateInterval]
    @Binding var cards: Set<String>
    let open: (DateInterval) -> Void
    let onEdit: (Expense) -> Void
    let onConnectSMS: () -> Void

    @Environment(ExpenseStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(AppSettings.self) private var settings

    private enum ChartMode: Hashable { case categories, months, calendar }
    @State private var chartMode: ChartMode = .categories
    @State private var allCategories = false
    @State private var showAnalysis = false
    @State private var showAccounts = ProcessInfo.processInfo.arguments.contains("-accounts")

    /// Отступ карточек от края экрана — как у секций списка (статистика, последние операции).
    static var cardInset: CGFloat {
        if #available(iOS 26.0, *) { 16 } else { 0 }
    }

    /// Для «Операций» — фильтр по карте, только если выбрана ровно одна.
    private var card: String? { cards.count == 1 ? cards.first : nil }

    var body: some View {
        let totals = store.totals(in: month, cards: cards)
        let monthItems = store.expenses(in: month, cards: cards)
        List {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-chartsTop") { chartsSection(totals) }
            #endif
            Section { MonthSwitcher(month: $month, months: months, cards: cards) { showAccounts = true } }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)

            // Плашка про недавние переводы — во всех месяцах, чтобы страница не прыгала при свайпе.
            if !store.reviewQueue.isEmpty {
                // Секция на всю ширину, карточка — с тем же отступом, что у статистики: края совпадают и не обрезаются.
                Section { reviewBanner }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: Self.cardInset, bottom: 0, trailing: Self.cardInset))
                    .fullWidthSection()
            }

            Section { PlanningTiles(month: month, inset: Self.cardInset) }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .fullWidthSection()


            if monthItems.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Нет операций", systemImage: "wallet.bifold")
                    } description: {
                        Text("Скажите «обед 45 тысяч, такси 18» или подключите SMS банка — расходы будут добавляться сами.")
                    } actions: {
                        Button("Подключить SMS", action: onConnectSMS)
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    Button { showAnalysis = true } label: { AnalysisCard(month: month) }
                        .buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Self.cardInset, bottom: 0, trailing: Self.cardInset))
                .fullWidthSection()

                chartsSection(totals)
                recentSection(monthItems)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        // Свайп вниз — обновить: монеты падают в кошелёк.
        .walletRefreshable { await refresh() }
        .navigationDestination(isPresented: $showAnalysis) { AnalysisView(month: month) }
        .sheet(isPresented: $showAccounts) { AccountsDrawer(cards: $cards) }
        // Последние строки не прячутся под таббаром.
        .contentMargins(.bottom, 12, for: .scrollContent)
    }

    // MARK: - Графики: один блок с переключателем

    private func chartsSection(_ totals: MonthTotals) -> some View {
        Section {
            Picker("График", selection: $chartMode.animation()) {
                Text("Категории").tag(ChartMode.categories)
                Text("По месяцам").tag(ChartMode.months)
                Text("Календарь").tag(ChartMode.calendar)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            switch chartMode {
            case .categories:
                if totals.spent > 0 {
                    CategoryChart(totals: totals, filter: Binding(get: { nil }, set: { category in
                        if let category { openOperations(category: category) }
                    }))
                    .frame(height: 230)
                    .padding(.vertical, 6)
                    let rows = totals.sortedCategories
                    // Все полоски — в одном блоке: при смене месяца длина плавно меняется,
                    // а строки плавно меняются местами (отдельные строки списка перерисовывались рывком).
                    VStack(spacing: 14) {
                        ForEach(allCategories ? rows : Array(rows.prefix(4)), id: \.category) { row in
                            Button { openOperations(category: row.category) } label: {
                                CategoryRow(category: row.category, amount: row.amount, share: row.amount / totals.spent, selected: false,
                                            limit: month.contains(.now) && cards.isEmpty ? BudgetStore.shared.limit(for: row.category) : nil)
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                        if rows.count > 4 {
                            Button(allCategories ? String(localized: "Свернуть") : String(localized: "Ещё \(rows.count - 4)")) {
                                allCategories.toggle()
                            }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.borderless)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.smooth(duration: 0.55), value: month)
                    .animation(.smooth(duration: 0.35), value: allCategories)
                } else {
                    Text("В этом месяце расходов нет.").foregroundStyle(.secondary)
                }
            case .months:
                MonthlyBars(selected: month, cards: cards, open: open)
                    .frame(height: 210)
                    .padding(.vertical, 6)
            case .calendar:
                SpendingCalendar(month: month, cards: cards) { day in
                    var filter = OperationsFilter(card: card)
                    filter.period = .range(day, day)
                    navigation.openOperations(filter)
                }
                .padding(.vertical, 6)
                .animation(.smooth(duration: 0.45), value: month)
            }
        }
    }

    /// Перечитать SMS из «Команд», курсы ЦБ, регулярные платежи, логотипы и виджет.
    private func refresh() async {
        store.reload()
        RecurringStore.shared.detect(from: store)
        await Rates.shared.refresh()
        await store.classifyOldSMS(config: settings.aiConfig)
        await store.fillMissingBrands(config: settings.aiConfig)
        WidgetSnapshot.update(from: store)
    }

    private func openOperations(category: ExpenseCategory) {
        navigation.openOperations(OperationsFilter(category: category, card: card, month: month))
    }

    // MARK: - Последние операции

    private func recentSection(_ items: [Expense]) -> some View {
        Section {
            ForEach(items.prefix(5)) { expense in
                Button { onEdit(expense) } label: { ExpenseRow(expense: expense) }
                    .buttonStyle(.plain)
            }
            Button {
                navigation.openOperations(OperationsFilter(card: card, month: month))
            } label: {
                HStack {
                    Text(String(localized: "Все операции месяца — \(items.count)"))
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
            }
        } header: {
            sectionHeader("Последние операции")
        }
    }

    // MARK: - Переводы без имени

    private var reviewBanner: some View {
        let count = store.reviewQueue.count
        return Button { navigation.sheet = .review } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.fill.questionmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.indigo.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Кому были переводы?").fontWeight(.semibold)
                    Text(String(localized: "\(count) без имени — ответ в одно касание"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Переводы

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Color(.label))
            .textCase(nil)
    }
}

/// Столбики по месяцам: сами хранят, что показывают, и плавно доезжают до новых сумм и подсветки.
private struct MonthlyBars: View {
    let selected: DateInterval
    let cards: Set<String>
    let open: (DateInterval) -> Void

    @Environment(ExpenseStore.self) private var store
    @State private var shown = AnimatableAmounts(Array(repeating: 0, count: 13))

    /// Доход и расход шести месяцев + положение подсветки (номер месяца в окне).
    private var target: AnimatableAmounts {
        let months = MonthlyBarsChart.window(selected: selected)
        var values = months.flatMap { date -> [Double] in
            let totals = store.totals(in: ExpenseStore.month(containing: date), cards: cards)
            return [totals.income, totals.spent]
        }
        values.append(Double(months.firstIndex { Calendar.current.isDate($0, equalTo: selected.start, toGranularity: .month) } ?? 5))
        return AnimatableAmounts(values)
    }

    var body: some View {
        MonthlyBarsChart(selected: selected, cards: cards, open: open, values: shown)
            .animation(.smooth(duration: 0.6), value: shown)
            .onAppear {
                // Столбики вырастают снизу, подсветка сразу на своём месте.
                var start = AnimatableAmounts(Array(repeating: 0, count: 12))
                start.values.append(target.values.last ?? 5)
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { shown = start }
                shown = target
            }
            .onChange(of: target) { _, new in shown = new }
    }
}

private struct MonthlyBarsChart: View, Animatable {
    let selected: DateInterval
    let cards: Set<String>
    let open: (DateInterval) -> Void
    var values: AnimatableAmounts

    var animatableData: AnimatableAmounts {
        get { values }
        set { values = newValue }
    }

    @Environment(ExpenseStore.self) private var store
    @State private var pressed: Date?
    @State private var held = false

    private struct Bar: Identifiable {
        let month: Date
        let kind: String
        let amount: Double
        var id: String { "\(month.timeIntervalSince1970)-\(kind)" }
    }

    /// Шесть месяцев до текущего; окно сдвигается, только если выбран месяц старше —
    /// иначе при свайпе меняется лишь подсветка, а столбики стоят на месте.
    private var months: [Date] { Self.window(selected: selected) }

    static func window(selected: DateInterval) -> [Date] {
        let calendar = Calendar.current
        let current = ExpenseStore.month(containing: .now).start
        let back = calendar.dateComponents([.month], from: selected.start, to: current).month ?? 0
        let end = back <= 5 ? current : selected.start
        return (0..<6).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: end) }
    }

    private func value(_ index: Int) -> Double {
        index < values.values.count ? max(0, values.values[index]) : 0
    }

    /// Плавающая подсветка: 1 — у выбранного месяца, 0.4 — у остальных, между ними — плавно.
    private func highlight(_ index: Int) -> Double {
        if let pressed { return isSame(months[index], pressed) ? 1 : 0.4 }
        let focus = values.values.last ?? 5
        return 1 - min(abs(Double(index) - focus), 1) * 0.6
    }

    private var bars: [(index: Int, bar: Bar)] {
        months.enumerated().flatMap { index, date -> [(index: Int, bar: Bar)] in
            [(index, Bar(month: date, kind: String(localized: "Доход"), amount: value(index * 2))),
             (index, Bar(month: date, kind: String(localized: "Расход"), amount: value(index * 2 + 1)))]
        }
    }

    private func month(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        guard let plot = proxy.plotFrame, let date: Date = proxy.value(atX: location.x - geo[plot].origin.x) else { return nil }
        return months.first { isSame($0, date) }
    }

    private func isSame(_ a: Date, _ b: Date?) -> Bool {
        guard let b else { return false }
        return Calendar.current.isDate(a, equalTo: b, toGranularity: .month)
    }

    var body: some View {
        let focus = pressed ?? selected.start
        VStack(alignment: .leading, spacing: 10) {
            header(for: focus)
            chart(focus: focus)
        }
    }

    /// Суммы месяца под пальцем (или открытого месяца) — над столбцами, внутри карточки.
    private func header(for month: Date) -> some View {
        // Суммы берём из уже посчитанных значений, а не пересчитываем все операции на каждом кадре анимации.
        let index = months.firstIndex { isSame($0, month) } ?? 0
        let totals = (income: value(index * 2), spent: value(index * 2 + 1))
        let f = DateFormatter()
        f.locale = DueFormat.locale
        f.dateFormat = "LLLL"
        return HStack(spacing: 12) {
            Text(f.string(from: month).capitalizedFirst)
                .fontWeight(.semibold)
            Spacer(minLength: 4)
            Text("+\(Money.string(totals.income))").foregroundStyle(.green)
            Text("−\(Money.string(totals.spent))").foregroundStyle(.orange)
        }
        .font(.subheadline.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .contentTransition(.numericText())
    }

    private func chart(focus: Date) -> some View {
        Chart {
            ForEach(bars, id: \.bar.id) { item in
                BarMark(x: .value("Месяц", item.bar.month, unit: .month), y: .value("Сумма", item.bar.amount))
                    .foregroundStyle(by: .value("Тип", item.bar.kind))
                    .position(by: .value("Тип", item.bar.kind))
                    .cornerRadius(4)
                    .opacity(highlight(item.index))
            }
            if let pressed {
                RuleMark(x: .value("Месяц", pressed, unit: .month))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .lineStyle(StrokeStyle(lineWidth: 34))
            }
        }
        .chartForegroundStyleScale([String(localized: "Доход"): Color.green, String(localized: "Расход"): Color.orange])
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).locale(DueFormat.locale), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(Money.short(amount)) }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .center)
        .chartOverlay { proxy in
            GeometryReader { geo in
                // Нажатие — открыть месяц; удержание — суммы под пальцем. Прокрутку не перехватываем.
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        if let date = month(at: location, proxy: proxy, geo: geo) { open(ExpenseStore.month(containing: date)) }
                    }
                    .gesture(PressGesture(onChange: { location in
                        held = true
                        pressed = month(at: location, proxy: proxy, geo: geo)
                    }, onEnd: {
                        pressed = nil
                        held = false
                    }))
            }
        }
        // Суммы и подсветку анимируем сами (значения выше), встроенная анимация графика не нужна.
        .transaction { $0.animation = nil }
        .sensoryFeedback(.selection, trigger: pressed)
        .sensoryFeedback(.impact(weight: .light), trigger: held) { _, new in new }
    }

}

/// Кольцо категорий. Нажатие — подсветка и сумма в центре, удержание — фильтр списка по категории.
/// Кольцо категорий: само хранит, что показывает, и плавно доезжает до новых сумм.
/// При появлении (переключили вид статистики) — вырастает из нуля.
private struct CategoryChart: View {
    let totals: MonthTotals
    @Binding var filter: ExpenseCategory?

    @State private var shown = AnimatableAmounts(Array(repeating: 0, count: ExpenseCategory.expenseCases.count))

    private var target: AnimatableAmounts {
        AnimatableAmounts(ExpenseCategory.expenseCases.map { totals.byCategory[$0] ?? 0 })
    }

    var body: some View {
        CategoryDonut(totals: totals, amounts: shown, filter: $filter)
            .animation(.smooth(duration: 0.7), value: shown)
            .onAppear { shown = target }
            .onChange(of: target) { _, new in shown = new }
    }
}

private struct CategoryDonut: View, Animatable {
    let totals: MonthTotals
    @Binding var filter: ExpenseCategory?
    /// Суммы по категориям в постоянном порядке. SwiftUI сам считает промежуточные значения на каждом кадре,
    /// поэтому кольцо плавно перестраивается при смене месяца на любой версии iOS —
    /// не полагаясь на встроенную анимацию графиков.
    var amounts: AnimatableAmounts

    @State private var highlighted: ExpenseCategory?
    @State private var held = false

    init(totals: MonthTotals, amounts: AnimatableAmounts, filter: Binding<ExpenseCategory?>) {
        self.totals = totals
        self.amounts = amounts
        _filter = filter
    }

    var animatableData: AnimatableAmounts {
        get { amounts }
        set { amounts = newValue }
    }

    var body: some View {
        // Порядок категорий постоянный: при смене месяца каждый сектор растёт или сжимается,
        // а не перекрашивается в соседнюю категорию.
        let rows = zip(ExpenseCategory.expenseCases, amounts.values).map { (category: $0, amount: max(0, $1)) }
        let active = highlighted ?? filter
        VStack(spacing: 8) {
            Chart(rows, id: \.category) { row in
                SectorMark(
                    angle: .value("Сумма", row.amount),
                    innerRadius: .ratio(0.6),
                    outerRadius: .ratio(active == row.category ? 1 : 0.9),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(row.category.color)
                .opacity(active == nil || active == row.category ? 1 : 0.3)
            }
            .chartBackground { _ in center(active) }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            let frame = proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local)
                            if let category = hit(location, rows: rows, frame: frame) {
                                highlighted = category == highlighted ? nil : category
                            } else {
                                reset()
                            }
                        }
                        .gesture(PressGesture(minimumDuration: 0.45, onChange: { location in
                            guard !held else { return }
                            let frame = proxy.plotFrame.map { geo[$0] } ?? geo.frame(in: .local)
                            guard let category = hit(location, rows: rows, frame: frame) else { return }
                            held = true
                            filter = filter == category ? nil : category
                            highlighted = nil
                        }, onEnd: { held = false }))
                }
            }
            // Подсветка по нажатию — своей пружиной; смену месяца рисуем сами (кадры выше), без анимации графика.
            .animation(.spring(duration: 0.25), value: active)
            .transaction { $0.animation = nil }
            .sensoryFeedback(.selection, trigger: highlighted) { _, new in new != nil }
            .sensoryFeedback(.impact(weight: .medium), trigger: filter)

            Text(filter == nil ? "Нажмите на цвет — покажу сумму, удерживайте — отфильтрую операции"
                               : "Удерживайте ещё раз, чтобы снять фильтр")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { reset() }
        }
    }

    /// Нажали мимо кольца — снимаем и подсветку, и фильтр.
    private func reset() {
        highlighted = nil
        filter = nil
    }

    @ViewBuilder
    private func center(_ active: ExpenseCategory?) -> some View {
        VStack(spacing: 2) {
            if let active, let amount = totals.byCategory[active] {
                Image(systemName: active.symbol).font(.caption).foregroundStyle(active.color)
                Text(Money.short(amount)).font(.system(size: 20, weight: .bold, design: .rounded))
                Text("\(active.title) · \(Int((amount / max(totals.spent, 1) * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 110)
            } else {
                Text(Money.short(totals.spent)).font(.system(size: 22, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(String(localized: "\(totals.sortedCategories.count) категорий"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Какую категорию задел палец: угол от 12 часов по часовой стрелке, только внутри кольца.
    private func hit(_ point: CGPoint, rows: [(category: ExpenseCategory, amount: Double)], frame: CGRect) -> ExpenseCategory? {
        let dx = point.x - frame.midX, dy = point.y - frame.midY
        let radius = min(frame.width, frame.height) / 2
        let distance = hypot(dx, dy)
        guard distance <= radius, distance >= radius * 0.5 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let total = rows.reduce(0) { $0 + $1.amount }
        var cumulative = 0.0
        for row in rows {
            cumulative += row.amount / total * 2 * .pi
            if angle <= cumulative { return row.category }
        }
        return rows.last { $0.amount > 0 }?.category
    }

}

private struct CategoryRow: View {
    let category: ExpenseCategory
    let amount: Double
    let share: Double
    let selected: Bool
    var limit: Double?

    var body: some View {
        HStack(spacing: 12) {
            IconCircle(symbol: category.symbol, color: category.color, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(category.title)
                    Spacer()
                    Text(Money.string(amount)).monospacedDigit().contentTransition(.numericText())
                    if let limit {
                        Text("/ \(Money.short(limit))")
                            .font(.footnote)
                            .foregroundStyle(amount > limit ? .red : .secondary)
                    }
                }
                if let limit {
                    BudgetBar(share: amount / max(limit, 1), color: category.color)
                } else {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(category.color.opacity(0.85))
                            .frame(width: max(4, proxy.size.width * share))
                    }
                    .frame(height: 4)
                }
            }
            if selected {
                Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(category.color)
            }
        }
        .contentShape(Rectangle())
    }
}

struct InsightRow: View {
    let insight: ExpenseAnalysis.Insight

    var body: some View {
        let category = insight.category.flatMap(ExpenseCategory.init(rawValue:))
        HStack(alignment: .top, spacing: 12) {
            IconCircle(symbol: category?.symbol ?? "lightbulb.fill", color: category?.color ?? .yellow, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(AmountFormat.prettify(insight.title)).fontWeight(.semibold)
                Text(AmountFormat.prettify(insight.detail))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if insight.saving > 0 {
                    Text(String(localized: "Экономия ≈ \(Money.string(insight.saving)) / мес"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ExpenseRow: View {
    let expense: Expense

    var body: some View {
        HStack(spacing: 12) {
            MerchantLogo(brand: expense.brand, category: expense.category)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(expense.isTransfer ? (expense.person ?? expense.title) : expense.title).lineLimit(1)
                    // Перевод — стрелкой после названия: ↗ ушло, ↙ пришло.
                    if expense.isTransfer && !expense.isInternal {
                        Image(systemName: expense.kind == .transferIn ? "arrow.down.left" : "arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(expense.kind == .transferIn ? Color.green : Color.secondary)
                            .accessibilityLabel(expense.kind?.title ?? "")
                    }
                }
                HStack(spacing: 4) {
                    if expense.isInternal { Image(systemName: "arrow.triangle.2.circlepath") }
                    Text(subtitle)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(Money.string(expense.isIncome ? expense.amount : -expense.amount, currency: expense.currency, sign: expense.isIncome))
                .monospacedDigit()
                .fontWeight(.medium)
                .fixedSize()
                .foregroundStyle(expense.isInternal ? Color.secondary : (expense.isIncome ? Color.green : Color.primary))
        }
        .contentShape(Rectangle())
    }

    /// «Barbershop · 14:39 · •4503» — одной строкой: заметка (на что ушли деньги), иначе категория.
    private var subtitle: String {
        let note = expense.note.trimmed.isEmpty ? nil : expense.note.trimmed
        let kind: String? = expense.isInternal ? String(localized: "Между своими картами")
            : note ?? (expense.isTransfer ? nil : expense.category.title)
        return [kind, DueFormat.timeString(expense.date), expense.card.map { $0 == ExpenseStore.cashCard ? String(localized: "Наличные") : "•\($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Набор сумм, который SwiftUI умеет плавно интерполировать (для кольца категорий).
struct AnimatableAmounts: VectorArithmetic {
    var values: [Double]

    init(_ values: [Double]) { self.values = values }

    static var zero: AnimatableAmounts { AnimatableAmounts([]) }

    private static func combine(_ a: AnimatableAmounts, _ b: AnimatableAmounts, _ op: (Double, Double) -> Double) -> AnimatableAmounts {
        let count = max(a.values.count, b.values.count)
        return AnimatableAmounts((0..<count).map { i in
            op(i < a.values.count ? a.values[i] : 0, i < b.values.count ? b.values[i] : 0)
        })
    }

    static func + (a: AnimatableAmounts, b: AnimatableAmounts) -> AnimatableAmounts { combine(a, b, +) }
    static func - (a: AnimatableAmounts, b: AnimatableAmounts) -> AnimatableAmounts { combine(a, b, -) }

    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}
