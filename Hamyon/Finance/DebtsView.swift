import SwiftUI

/// Долги: кому дали и у кого взяли, с напоминанием в день возврата.
struct DebtsView: View {
    @Environment(ExpenseStore.self) private var store

    @State private var editing: Debt?
    @State private var creating = false
    @State private var splitting = false
    /// Фильтр по плиткам сверху: все, мне должны, я в долгу.
    @State private var scope: Scope = .all

    private enum Scope: Hashable { case all, owedToMe, iOwe }

    private func matches(_ debt: Debt) -> Bool {
        switch scope {
        case .all: true
        case .owedToMe: debt.lent
        case .iOwe: !debt.lent
        }
    }

    var body: some View {
        let totals = store.debtTotals
        let open = store.openDebts.filter(matches)
        let closed = store.debts.filter { !$0.isOpen && matches($0) }
            .sorted { ($0.closedAt ?? $0.date) > ($1.closedAt ?? $1.date) }
        List {
            Section {
                // Итоги — одной карточкой, фильтр — обычным переключателем под ней.
                HStack(spacing: 0) {
                    stat(String(localized: "Мне должны"), Money.short(totals.owedToMe), color: totals.owedToMe > 0 ? .green : .secondary)
                    Divider().frame(height: 36)
                    stat(String(localized: "Я в долгу"), Money.short(totals.iOwe), color: totals.iOwe > 0 ? .orange : .secondary)
                    Divider().frame(height: 36)
                    let net = totals.owedToMe - totals.iOwe
                    stat(String(localized: "Разница"), net == 0 ? Money.short(0) : (net > 0 ? "+" : "−") + Money.short(net),
                         color: net == 0 ? .secondary : (net > 0 ? .green : .orange))
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Показать", selection: $scope) {
                    Text("Все").tag(Scope.all)
                    Text("Мне должны").tag(Scope.owedToMe)
                    Text("Я в долгу").tag(Scope.iOwe)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Отметить перевод как долг можно на экране «Кому были переводы?».")
            }

            if open.isEmpty && closed.isEmpty {
                Section {
                    ContentUnavailableView("Долгов нет", systemImage: "hand.thumbsup",
                                           description: Text("Нажмите «+», чтобы записать, кому дали или у кого взяли."))
                }
                .listRowBackground(Color.clear)
            } else {
                let lent = open.filter(\.lent)
                let borrowed = open.filter { !$0.lent }
                if !lent.isEmpty { debtSection(String(localized: "Мне должны"), lent) }
                if !borrowed.isEmpty { debtSection(String(localized: "Я в долгу"), borrowed) }
            }

            // Погашенные — не прячем, а показываем отдельно, спокойнее, с галочкой.
            if !closed.isEmpty {
                Section {
                    ForEach(closed) { debt in
                        Button { editing = debt } label: { DebtRow(debt: debt) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { store.deleteDebt(debt) } label: { Label("Удалить", systemImage: "trash") }
                            }
                    }
                } header: {
                    Label(String(localized: "Погашены — \(closed.count)"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: scope)
        .navigationTitle("Долги")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Новый долг", systemImage: "plus") { creating = true }
                    Button("Разделить счёт с друзьями", systemImage: "person.3.fill") { splitting = true }
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить")
            }
        }
        .sheet(isPresented: $splitting) { SplitBillView() }
        .sheet(item: $editing) { DebtEditView(debt: $0) }
        .sheet(isPresented: $creating) { DebtEditView(debt: nil) }
        .sensoryFeedback(.selection, trigger: scope)
    }

    private func debtSection(_ title: String, _ debts: [Debt]) -> some View {
        Section(title) {
            ForEach(debts) { debt in
                Button { editing = debt } label: { DebtRow(debt: debt) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button { withAnimation { store.repay(debt) } } label: {
                            Label("Вернули", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.deleteDebt(debt) } label: { Label("Удалить", systemImage: "trash") }
                    }
            }
        }
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DebtRow: View {
    let debt: Debt

    var body: some View {
        HStack(spacing: 12) {
            Text(String(debt.person.prefix(1)).uppercased())
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background((debt.isOpen ? (debt.lent ? Color.green : Color.orange) : Color(.systemGray3)).gradient, in: Circle())
                // Погашен — зелёная галочка на аватаре.
                .overlay(alignment: .bottomTrailing) {
                    if !debt.isOpen {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, .green)
                            .background(Circle().fill(Color(.secondarySystemGroupedBackground)).padding(-1))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(debt.person).lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(debt.isOverdue ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.string(debt.isOpen ? debt.left : debt.amount))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(debt.isOpen ? (debt.lent ? Color.green : Color.primary) : Color.secondary)
                if !debt.isOpen {
                    Text("погашен").font(.caption.weight(.medium)).foregroundStyle(.green)
                }
                if debt.repaid > 0 && debt.isOpen {
                    Text(String(localized: "из \(Money.string(debt.amount))")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if let closed = debt.closedAt {
            return [String(localized: "Погашен \(DueFormat.string(closed, hasTime: false))"), debt.billTitle].compactMap { $0 }.joined(separator: " · ")
        }
        var parts = [DueFormat.string(debt.date, hasTime: false)]
        if let due = debt.dueDate {
            parts.append(debt.isOverdue ? String(localized: "просрочен с \(DueFormat.string(due, hasTime: false))")
                                        : String(localized: "вернуть до \(DueFormat.string(due, hasTime: false))"))
        }
        if let bill = debt.billTitle { parts.append(bill) }
        if !debt.note.isEmpty { parts.append(debt.note) }
        return parts.joined(separator: " · ")
    }
}

/// Новый долг или правка. Можно сказать фразой: «дал Азизу 500 тысяч до пятницы».
struct DebtEditView: View {
    let debt: Debt?
    var initial: DebtDraft?

    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var draft = DebtDraft()
    @State private var amountText = ""
    @State private var phrase = ""
    @State private var parsing = false
    @State private var parseError: String?
    @State private var repayText = ""
    @State private var loaded = false
    @State private var original = DebtDraft()
    @State private var confirmDiscard = false
    @State private var confirmDelete = false

    /// Что-то поменяли и не сохранили — при выходе спросим.
    private var hasChanges: Bool {
        var current = draft
        current.amount = amount
        return loaded && (current != original || !phrase.trimmed.isEmpty || !repayText.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if debt == nil {
                    Section {
                        HStack {
                            TextField("«Дал Азизу 500 тысяч до пятницы»", text: $phrase, axis: .vertical)
                                .lineLimit(1...3)
                            if parsing {
                                ProgressView()
                            } else if !phrase.trimmed.isEmpty {
                                Button("Разобрать") { Task { await parse() } }
                                    .fontWeight(.semibold)
                            }
                        }
                        if let parseError {
                            Text(parseError).font(.footnote).foregroundStyle(.red)
                        }
                    } header: {
                        Text("Одной фразой")
                    } footer: {
                        Text("Можно надиктовать с клавиатуры — кнопка микрофона внизу.")
                    }
                }

                // Долг из общего счёта: название счёта — заголовком сверху, его не меняют.
                if let bill = debt?.billTitle {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.indigo.gradient, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bill).font(.title3.weight(.semibold)).lineLimit(2)
                                Text("Общий счёт").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    }
                }

                if readOnly, let debt {
                    closedFacts(debt)
                } else {
                Section {
                    Picker("Кто кому", selection: $draft.lent) {
                        Text("Мне должны").tag(true)
                        Text("Я в долгу").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    TextField("Имя", text: $draft.person)
                        .textInputAutocapitalization(.words)
                    let people = store.people.filter { $0 != draft.person }.prefix(8)
                    if !people.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(people), id: \.self) { person in
                                    Button(person) { draft.person = person }
                                        .font(.subheadline)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        TextField("0", text: $amountText)
                            .keyboardType(.numberPad)
                            .amountFormatting($amountText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("сум").foregroundStyle(.secondary)
                    }
                }

                Section {
                    DatePicker("Когда", selection: $draft.date, displayedComponents: .date)
                    Toggle("Срок возврата", isOn: Binding(get: { draft.dueDate != nil }, set: { on in
                        draft.dueDate = on ? Calendar.current.date(byAdding: .day, value: 7, to: .now) : nil
                    }))
                    if let due = draft.dueDate {
                        DatePicker("Вернуть до", selection: Binding(get: { due }, set: { draft.dueDate = $0 }),
                                   in: Calendar.current.startOfDay(for: draft.date)..., displayedComponents: .date)
                    }
                } footer: {
                    if draft.dueDate != nil { Text("В этот день в 10:00 придёт напоминание.") }
                }

                Section {
                    TextField("Заметка", text: $draft.note, axis: .vertical).lineLimit(1...4)
                }

                }

                if let debt {
                    DebtTimeline(debt: debt)
                    if debt.isOpen {
                        Section {
                            HStack {
                                TextField(String(localized: "Вернули часть, сум"), text: $repayText)
                                    .keyboardType(.numberPad)
                                    .amountFormatting($repayText)
                                Button("Записать") {
                                    if let value = Double(repayText.filter(\.isNumber)), value > 0 {
                                        withAnimation { store.repay(debt, amount: value) }
                                        repayText = ""
                                    }
                                }
                                .fontWeight(.semibold)
                                .disabled(Double(repayText.filter(\.isNumber)) == nil)
                            }
                        } header: {
                            Text("Частичный возврат")
                        }
                        Section {
                            // Полный возврат — слайдером, чтобы не закрыть долг случайно.
                            SlideToConfirm(title: String(localized: "Сдвиньте — долг погашен")) {
                                store.repay(debt)
                                dismiss()
                            }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        }
                    }
                }
            }
            .navigationTitle(debt == nil ? String(localized: "Новый долг") : String(localized: "Долг"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !readOnly {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отменить") { if hasChanges { confirmDiscard = true } else { dismiss() } }
                    }
                }
                if let debt {
                    // «Удалить» (и «Открыть снова» у погашенного) — в меню, а не рядом с полезными кнопками.
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if readOnly {
                                Button("Открыть снова", systemImage: "arrow.uturn.backward") {
                                    store.reopen(debt)
                                    dismiss()
                                }
                            }
                            Button("Удалить долг", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(debt == nil ? String(localized: "Добавить") : String(localized: "Готово"), action: save)
                            .fontWeight(.semibold)
                            .disabled(draft.person.trimmed.isEmpty || amount <= 0)
                    }
                }
            }
            .confirmationDialog("Удалить долг?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    if let debt { store.deleteDebt(debt) }
                    dismiss()
                }
            }
        }
        .unsavedChanges(hasChanges, confirm: $confirmDiscard) { dismiss() }
        .presentationDragIndicator(readOnly ? .visible : .automatic)
        .onAppear(perform: load)
    }

    /// Погашенный долг — только для просмотра: данные не меняются.
    private var readOnly: Bool { debt.map { !$0.isOpen } ?? false }

    @ViewBuilder
    private func closedFacts(_ debt: Debt) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Долг погашен").font(.headline)
                    if let closed = debt.closedAt {
                        Text(DueFormat.string(closed, hasTime: false)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        Section {
            fact(debt.lent ? String(localized: "Кому дали") : String(localized: "У кого взяли"), debt.person)
            fact(String(localized: "Сумма"), Money.string(debt.amount))
            fact(String(localized: "Когда"), DueFormat.string(debt.date, hasTime: false))
            if let due = debt.dueDate {
                fact(String(localized: "Вернуть до"), DueFormat.string(due, hasTime: false))
            }
            if !debt.note.isEmpty {
                fact(String(localized: "Заметка"), debt.note)
            }
        } footer: {
            Text("Погашенный долг нельзя изменить. Если отметили по ошибке — «⋯» → «Открыть снова».")
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private var amount: Double { Double(amountText.filter(\.isNumber)) ?? 0 }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let debt {
            draft = DebtDraft(person: debt.person, amount: debt.amount, lent: debt.lent, date: debt.date,
                              dueDate: debt.dueDate, note: debt.note)
        } else if let initial {
            draft = initial
        }
        if draft.amount > 0 { amountText = String(Int(draft.amount)) }
        original = draft
        original.amount = amount
    }

    private func parse() async {
        parsing = true
        parseError = nil
        defer { parsing = false }
        do {
            let parsed = try await DebtParser.parse(phrase, config: settings.aiConfig, people: store.people)
            draft = parsed
            amountText = parsed.amount > 0 ? String(Int(parsed.amount)) : ""
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func save() {
        draft.amount = amount
        if let debt { store.updateDebt(debt, with: draft) } else { store.addDebt(draft) }
        dismiss()
    }
}

/// «Дал Азизу 500 тысяч до пятницы», «взял у брата 2 млн, верну в конце месяца» → долг.
enum DebtParser {
    static func parse(_ text: String, config: AIConfig, people: [String], now: Date = .now) async throws -> DebtDraft {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        let object = try await AIClient.object(
            system: """
            Extract a personal debt from a phrase in Russian, Uzbek or English (speech-to-text, may have errors). \
            Today is \(formatter.string(from: now)).
            - lent: true if the user gave money to someone (дал в долг, одолжил, qarz berdim), false if the user \
            borrowed (взял в долг, занял, qarz oldim).
            - person: the other person's name in nominative case ("Азизу" → "Азиз", "у брата" → "Брат"). \
            Known people: \(people.prefix(30).joined(separator: ", ")).
            - amount in UZS: "500 тысяч" = 500000, "2 млн" = 2000000, a bare small number means thousands.
            - due_date: YYYY-MM-DD if a return date is said ("до пятницы", "в конце месяца", "через неделю"), else empty.
            - date: YYYY-MM-DD of the loan if said ("вчера"), else today.
            - note: anything else worth keeping, short.
            """,
            text: text,
            schema: { upper in
                func t(_ type: String) -> String { upper ? type.uppercased() : type }
                return [
                    "type": t("object"),
                    "properties": [
                        "lent": ["type": t("boolean")],
                        "person": ["type": t("string")],
                        "amount": ["type": t("number")],
                        "date": ["type": t("string")],
                        "due_date": ["type": t("string")],
                        "note": ["type": t("string")],
                    ],
                    "required": ["lent", "person", "amount"],
                ]
            },
            toolName: "record_debt", toolDescription: "Записать долг.", config: config
        )
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        var draft = DebtDraft()
        draft.lent = object["lent"] as? Bool ?? true
        draft.person = (object["person"] as? String)?.trimmed.capitalizedFirst ?? ""
        draft.amount = (object["amount"] as? NSNumber)?.doubleValue ?? 0
        draft.date = (object["date"] as? String).flatMap(day.date(from:)) ?? now
        draft.dueDate = (object["due_date"] as? String).flatMap(day.date(from:))
        draft.note = (object["note"] as? String)?.trimmed ?? ""
        return draft
    }
}

/// Лента возвратов: дали в долг → вернули часть → … → осталось.
private struct DebtTimeline: View {
    let debt: Debt

    private struct Event: Identifiable {
        let id: String
        let date: Date?
        let title: String
        let detail: String
        let color: Color
    }

    private var events: [Event] {
        var items = [Event(id: "start", date: debt.date,
                           title: debt.lent ? String(localized: "Дали в долг \(Money.string(debt.amount))")
                                            : String(localized: "Взяли в долг \(Money.string(debt.amount))"),
                           detail: [debt.billTitle, debt.note.isEmpty ? nil : debt.note].compactMap { $0 }.joined(separator: " · "),
                           color: debt.lent ? .green : .orange)]
        var left = debt.amount
        let known = debt.payments.reduce(0) { $0 + $1.amount }
        // Возвраты, записанные до появления истории, — одной строкой без даты.
        if debt.repaid - known > 0.5 {
            left -= debt.repaid - known
            items.append(Event(id: "earlier", date: nil, title: String(localized: "Вернули \(Money.string(debt.repaid - known))"),
                               detail: String(localized: "раньше · осталось \(Money.string(left))"), color: .teal))
        }
        for payment in debt.payments.sorted(by: { $0.date < $1.date }) {
            left -= payment.amount
            items.append(Event(id: payment.id.uuidString, date: payment.date,
                               title: String(localized: "Вернули \(Money.string(payment.amount))"),
                               detail: left > 0.5 ? String(localized: "осталось \(Money.string(left))") : String(localized: "долг погашен"),
                               color: .teal))
        }
        if let due = debt.dueDate, debt.isOpen {
            items.append(Event(id: "due", date: due, title: String(localized: "Срок возврата"),
                               detail: debt.isOverdue ? String(localized: "просрочен") : "", color: debt.isOverdue ? .red : .secondary))
        }
        return items
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Money.string(debt.repaid)).fontWeight(.semibold)
                    Text(String(localized: "из \(Money.string(debt.amount))")).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((debt.repaid / max(debt.amount, 1) * 100).rounded()))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.teal)
                }
                .font(.subheadline)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(Color.teal.gradient)
                            .frame(width: max(6, proxy.size.width * min(debt.repaid / max(debt.amount, 1), 1)))
                    }
                }
                .frame(height: 6)
            }
            .padding(.vertical, 4)

            // Вся лента — одним блоком: линия идёт без разрывов, события — точки на ней.
            let items = events
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(index == 0 ? Color.clear : Color(.separator))
                                .frame(width: 2, height: 5)
                            Circle().fill(event.color).frame(width: 10, height: 10)
                            Rectangle()
                                .fill(index == items.count - 1 ? Color.clear : Color(.separator))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                        .frame(width: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.subheadline.weight(.medium))
                            let detail = [event.date.map { DueFormat.string($0, hasTime: false) }, event.detail.isEmpty ? nil : event.detail]
                                .compactMap { $0 }.joined(separator: " · ")
                            if !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom, index == items.count - 1 ? 0 : 16)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("История")
        }
    }
}
