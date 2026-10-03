import SwiftUI

/// Вся история: поиск, закреплённые фильтры (тип, категория, карта, месяц), операции по дням.
struct OperationsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    @State private var search = ""
    @State private var editing: Expense?
    @State private var pickingDates = ProcessInfo.processInfo.arguments.contains("-dates")

    private var filter: OperationsFilter { navigation.filter }

    private var items: [Expense] {
        let query = search.trimmed.lowercased()
        return store.expenses.filter { expense in
            guard filter.matches(expense) else { return false }
            guard !query.isEmpty else { return true }
            return expense.title.lowercased().contains(query)
                || (expense.counterparty?.lowercased().contains(query) ?? false)
                || expense.note.lowercased().contains(query)
                || String(Int(expense.amount)).contains(query.filter(\.isNumber).isEmpty ? "#" : query.filter(\.isNumber))
        }
    }

    var body: some View {
        let items = items
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
        List {
            if items.isEmpty {
                // Ничего не нашлось: по поиску — системная подсказка, по фильтрам — кнопка «Сбросить».
                Group {
                    if !search.trimmed.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ContentUnavailableView {
                            Label("Ничего не найдено", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Нет операций с такими фильтрами.")
                        } actions: {
                            Button("Сбросить фильтры") {
                                withAnimation { navigation.filter = OperationsFilter() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            } else if filter.kind == .transfers {
                transfersSummary(items)
            } else if !search.trimmed.isEmpty || filter != OperationsFilter() {
                resultsSummary(items)
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                let dayItems = days[day]!.sorted { $0.date > $1.date }
                Section {
                    ForEach(dayItems) { expense in
                        Button { editing = expense } label: { ExpenseRow(expense: expense) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { store.delete(expense) } label: {
                                    Label("Удалить", systemImage: "trash.fill").labelStyle(.iconOnly)
                                }
                                .tint(.red)
                            }
                    }
                } header: {
                    dayHeader(day, dayItems)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 12, for: .scrollContent)
        // Отступ между фильтрами и первой карточкой — чтобы не прилипала к панели.
        .contentMargins(.top, 12, for: .scrollContent)
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Название или сумма")
        .navigationTitle("Операции")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { ExpenseDetailView(expense: $0) }
    }

    private func dayHeader(_ day: Date, _ items: [Expense]) -> some View {
        let spent = items.filter { !$0.isIncome && !$0.isInternal && $0.currency == "UZS" }.reduce(0) { $0 + $1.amount }
        let calendar = Calendar.current
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return HStack {
            Text(DueFormat.day(day) + (sameYear ? "" : " \(calendar.component(.year, from: day))"))
            Spacer()
            if spent > 0 { Text(Money.string(-spent)) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    // MARK: - Фильтры

    private var filterBar: some View {
        @Bindable var navigation = navigation
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let person = filter.person {
                    Button {
                        withAnimation { navigation.filter.person = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.fill").font(.caption)
                            Text(person).lineLimit(1)
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .modifier(ChipStyle(selected: true))
                    }
                    .buttonStyle(.plain)
                }
                // Применённые фильтры — в начале ряда, остальные — за ними.
                ForEach(chipOrder, id: \.self) { item in
                    switch item {
                    case .kind(let kind):
                        chip(kind.title, selected: filter.kind == kind) {
                            navigation.filter.kind = kind
                            // У переводов своя категория — «Переводы + Транспорт» никогда ничего не найдёт.
                            if kind == .transfers { navigation.filter.category = nil }
                        }
                    case .category where filter.kind == .transfers:
                        EmptyView()
                    case .category:
                        Menu {
                            Button("Все категории") { navigation.filter.category = nil }
                            ForEach(ExpenseCategory.allCases) { category in
                                Button(category.title, systemImage: category.symbol) { navigation.filter.category = category }
                            }
                        } label: {
                            chipLabel(filter.category?.title ?? String(localized: "Категория"), selected: filter.category != nil, menu: true)
                        }
                    case .card:
                        if !store.cards.isEmpty {
                            Menu {
                                Button("Все карты") { navigation.filter.card = nil }
                                ForEach(store.cards, id: \.self) { card in
                                    Button(store.cardTitle(card)) { navigation.filter.card = card }
                                }
                            } label: {
                                chipLabel(filter.card.map { store.cardTitle($0) } ?? String(localized: "Карта"), selected: filter.card != nil, menu: true)
                            }
                        }
                    case .period:
                        periodChip
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.smooth(duration: 0.3), value: filter)
        }
        .background(.bar)
    }

    private enum FilterChip: Hashable { case kind(OperationsFilter.Kind), category, card, period }

    /// Применённые фильтры первыми — сразу видно, что включено.
    private var chipOrder: [FilterChip] {
        let all: [FilterChip] = OperationsFilter.Kind.allCases.map { .kind($0) } + [.category, .card, .period]
        func active(_ chip: FilterChip) -> Bool {
            switch chip {
            case .kind(let kind): kind != .all && filter.kind == kind
            case .category: filter.category != nil
            case .card: filter.card != nil
            case .period: filter.period != nil
            }
        }
        return all.filter(active) + all.filter { !active($0) }
    }

    /// «Период ▾»: последние дни, месяцы с операциями, свои даты.
    private var periodChip: some View {
        @Bindable var navigation = navigation
        return HStack(spacing: 6) {
            Menu {
                Button("Сегодня") { navigation.filter.period = .days(1) }
                ForEach([7, 14, 30], id: \.self) { days in
                    Button(String(localized: "\(days) дней")) { navigation.filter.period = .days(days) }
                }
                Section("Месяц") {
                    ForEach(monthsWithData, id: \.start) { month in
                        Button(OperationsFilter.Period.month(month).title) { navigation.filter.period = .month(month) }
                    }
                }
                Button("Выбрать даты…", systemImage: "calendar") { pickingDates = true }
            } label: {
                chipLabel(filter.period?.title ?? String(localized: "Период"), selected: filter.period != nil, menu: true)
            }
            if filter.period != nil {
                Button {
                    withAnimation { navigation.filter.period = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Сбросить период")
            }
        }
        .sheet(isPresented: $pickingDates) {
            DateRangeSheet { from, to in navigation.filter.period = .range(from, to) }
                .presentationDetents([.large])
        }
    }

    private var monthsWithData: [DateInterval] {
        var seen = Set<Date>()
        return store.expenses.compactMap { expense in
            let month = ExpenseStore.month(containing: expense.date)
            return seen.insert(month.start).inserted ? month : nil
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation { action() }
        } label: {
            chipLabel(title, selected: selected, menu: false)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, selected: Bool, menu: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
        }
        .modifier(ChipStyle(selected: selected))
    }

    private func monthName(_ month: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = DueFormat.locale
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month.start).capitalizedFirst
    }

    /// Итог найденного: «Korzinka» или «Rabbimov» — сколько операций, сколько ушло и пришло.
    private func resultsSummary(_ items: [Expense]) -> some View {
        let counted = items.filter { !$0.isInternal && $0.currency == "UZS" }
        let spent = counted.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
        let received = counted.filter(\.isIncome).reduce(0) { $0 + $1.amount }
        return Section {
            HStack(spacing: 0) {
                stat(String(localized: "Потрачено"), Money.string(spent), color: .primary)
                if received > 0 {
                    Divider().frame(height: 36)
                    stat(String(localized: "Получено"), Money.string(received), color: .green)
                }
            }
        } footer: {
            Text(String(localized: "Найдено операций: \(items.count)"))
        }
    }

    // MARK: - Сводка по переводам

    private func transfersSummary(_ items: [Expense]) -> some View {
        let uzs = items.filter { $0.currency == "UZS" }
        let sent = uzs.filter { $0.kind == .transferOut && !$0.isInternal }.reduce(0) { $0 + $1.amount }
        let received = uzs.filter { $0.kind == .transferIn && !$0.isInternal }.reduce(0) { $0 + $1.amount }
        let own = uzs.filter { $0.kind == .transferOut && $0.isInternal }.reduce(0) { $0 + $1.amount }
        let fees = uzs.reduce(0) { $0 + $1.fee }
        return Section {
            HStack(spacing: 0) {
                stat(String(localized: "Отправлено"), Money.string(sent), color: .primary)
                Divider().frame(height: 36)
                stat(String(localized: "Получено"), Money.string(received), color: .green)
            }
            if own > 0 {
                HStack {
                    Label("Между своими картами", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(Money.string(own)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                if fees > 0 {
                    HStack {
                        Label("Комиссии", systemImage: "percent")
                        Spacer()
                        Text(Money.string(fees)).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        } footer: {
            Text("В SMS банка обычно нет имени получателя. Нажмите на перевод и впишите в название, кому он, — так анализ станет точнее.")
        }
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ChipStyle: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.green : Color(.tertiarySystemFill), in: Capsule())
    }
}

/// Свои даты: двойное нажатие на первый день, затем на последний — между ними серая полоса.
private struct DateRangeSheet: View {
    let onPick: (Date, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var month = ExpenseStore.month(containing: .now).start
    @State private var start: Date?
    @State private var end: Date?

    private let calendar = Calendar.current
    private let cellHeight: CGFloat = 44

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                header
                weekdays
                grid
                    .id(month)
                    .transition(.opacity)
                summary
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .navigationTitle("Период")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Показать") {
                        guard let start else { return }
                        onPick(start, end ?? start)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(start == nil)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: start)
        .sensoryFeedback(.selection, trigger: end)
    }

    // MARK: - Месяц

    private var header: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 36) }
            Spacer()
            Text(monthTitle)
                .font(.headline)
                .contentTransition(.numericText())
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 36) }
                .disabled(calendar.isDate(month, equalTo: .now, toGranularity: .month))
        }
        .tint(.green)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = DueFormat.locale
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month).capitalizedFirst
    }

    private func shift(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(.smooth(duration: 0.25)) { month = next }
    }

    private var weekdays: some View {
        let f = DateFormatter()
        f.locale = DueFormat.locale
        let symbols = f.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        // Неделя с понедельника.
        let ordered = Array(symbols[1...]) + [symbols[0]]
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Дни

    private var grid: some View {
        let days = calendar.range(of: .day, in: .month, for: month)!.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: month)
        }
        let offset = (calendar.component(.weekday, from: month) + 5) % 7
        let cells: [Date?] = Array(repeating: nil, count: offset) + days.map { Optional($0) }
        let rows = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        return VStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { column in
                        if column < row.count, let day = row[column] {
                            dayCell(day)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: cellHeight)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isStart = start.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isEnd = end.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let low = start.map { calendar.startOfDay(for: $0) }
        let high = (end ?? start).map { calendar.startOfDay(for: $0) }
        let inRange = low.map { day >= $0 } ?? false && high.map { day <= $0 } ?? false
        let hasRange = end != nil && !(start.map { calendar.isDate($0, inSameDayAs: end!) } ?? true)
        let future = day > .now
        let band = Color(.systemGray5)
        return ZStack {
            // Серая полоса между выбранными днями; у краёв — только внутренняя половина.
            if inRange && hasRange {
                HStack(spacing: 0) {
                    Rectangle().fill(isStart ? Color.clear : band)
                    Rectangle().fill(isEnd ? Color.clear : band)
                }
                .frame(height: 38)
            }
            if isStart || isEnd {
                Circle().fill(Color.primary).frame(width: 38, height: 38)
            }
            Text("\(calendar.component(.day, from: day))")
                .font(.body.weight(isStart || isEnd ? .semibold : .regular))
                .foregroundStyle(isStart || isEnd ? Color(.systemBackground) : future ? Color(.tertiaryLabel) : Color.primary)
            if calendar.isDateInToday(day) && !(isStart || isEnd) {
                Circle().fill(Color.green).frame(width: 4, height: 4).offset(y: 14)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cellHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pick(day) }
        .disabled(future)
    }

    /// Первое двойное нажатие — начало, второе — конец; дальше выбор начинается заново.
    private func pick(_ day: Date) {
        withAnimation(.smooth(duration: 0.25)) {
            if start == nil || end != nil {
                start = day
                end = nil
            } else if let first = start, day < calendar.startOfDay(for: first) {
                end = first
                start = day
            } else {
                end = day
            }
        }
    }

    // MARK: - Итог

    private var summary: some View {
        let f = DateFormatter()
        f.locale = DueFormat.locale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return VStack(spacing: 4) {
            if let start {
                let last = end ?? start
                let count = (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: last)).day ?? 0) + 1
                Text(end == nil ? f.string(from: start) : "\(f.string(from: start)) – \(f.string(from: last))")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text(end == nil ? String(localized: "Теперь дважды нажмите на последний день") : String(localized: "Дней: \(count)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Дважды нажмите на первый день, затем на последний")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}
