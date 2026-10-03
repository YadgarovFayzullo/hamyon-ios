import SwiftUI

/// Новая операция / правка существующей. Если задан `onSave` — возвращает черновик (экран проверки голоса).
struct ExpenseDetailView: View {
    let expense: Expense?
    var initial: ExpenseDraft?
    var onSave: ((ExpenseDraft) -> Void)?

    @Environment(ExpenseStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ExpenseDraft()
    @State private var amountText = ""
    @State private var loaded = false
    @FocusState private var amountFocused: Bool

    private var isNew: Bool { expense == nil && onSave == nil }

    /// Операция из SMS банка или выписки: сумма, дата, карта и поставщик — факт, их не меняем.
    private var locked: Bool {
        guard let expense, onSave == nil else { return false }
        return expense.source == .sms || expense.source == .statement
    }

    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var originalDraft = ExpenseDraft()
    @State private var originalAmount = ""
    @State private var originalOwn = ""

    private var ownSignature: String { "\(ownSide)|\(ownDigits)" }

    /// Поменяли и не сохранили — при выходе спросим.
    private var hasChanges: Bool {
        loaded && (draft != originalDraft || amountText.filter(\.isNumber) != originalAmount || ownSignature != originalOwn)
    }

    /// Перевод на свою карту / со своей карты.
    private enum OwnSide: Hashable { case none, card(String), other }
    @State private var ownSide: OwnSide = .none
    @State private var ownDigits = ""

    var body: some View {
        NavigationStack {
            Form {
                if locked {
                    lockedFacts
                } else {
                Section {
                    IncomeSwitch(isIncome: incomeBinding)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .focused($amountFocused)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .amountFormatting($amountText)
                        Picker("", selection: $draft.currency) {
                            ForEach(["UZS", "USD", "EUR", "RUB"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    TextField("Название или магазин", text: $draft.title)
                }
                }
                Section {
                    if draft.kind == .transferOut || draft.kind == .transferIn {
                        // Кому перевели — банк этого не пишет, поэтому можно указать самому.
                        HStack(spacing: 12) {
                            SquareIcon(symbol: "person.fill", color: .indigo)
                            TextField(draft.kind == .transferIn ? "От кого" : "Кому", text: Binding(
                                get: { draft.counterparty ?? "" },
                                set: { draft.counterparty = $0 }))
                                .textInputAutocapitalization(.words)
                        }
                        ownCardRow
                    }
                    if !draft.isIncome {
                        Picker(selection: $draft.category) {
                            ForEach(ExpenseCategory.expenseCases) { category in
                                Label(category.title, systemImage: category.symbol).tag(category)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                SquareIcon(symbol: draft.category.symbol, color: draft.category.color)
                                Text("Категория")
                            }
                        }
                    }
                    if !locked && (!store.cards.isEmpty || store.cashTracking) {
                        Picker(selection: $draft.card) {
                            Text("Не указана").tag(String?.none)
                            if store.cashTracking { Text("Наличные").tag(Optional(ExpenseStore.cashCard)) }
                            ForEach(store.cards, id: \.self) { Text(store.cardTitle($0)).tag(Optional($0)) }
                        } label: {
                            HStack(spacing: 12) {
                                SquareIcon(symbol: "creditcard.fill", color: .indigo)
                                Text("Карта")
                            }
                        }
                    }
                    if !locked {
                        DatePicker(selection: $draft.date, in: ...Date.now.addingTimeInterval(3600)) {
                            HStack(spacing: 12) {
                                SquareIcon(symbol: "calendar", color: .red)
                                Text("Дата")
                            }
                        }
                    }
                }
                Section {
                    TextField("Заметки", text: $draft.note, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    if draft.category == .transfers && !draft.isIncome && !draft.note.trimmed.isEmpty {
                        Text("В статистике это пока «Переводы». Если перевод — оплата услуги, выберите категорию выше (например, «Красота и уход»), и сумма попадёт туда.")
                    }
                }
                if let expense, onSave == nil {
                    if let raw = expense.rawText {
                        Section("SMS") {
                            Text(raw).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Section {
                        Button("Удалить операцию", role: .destructive) { confirmDelete = true }
                    }
                    .confirmationDialog(locked ? String(localized: "Удалить операцию из SMS?") : String(localized: "Удалить операцию?"),
                                        isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Удалить", role: .destructive) {
                            store.delete(expense)
                            dismiss()
                        }
                    } message: {
                        if locked {
                            Text("Она пропадёт из статистики. Если SMS придёт снова, операция не восстановится.")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? String(localized: "Новая операция") : String(localized: "Операция"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { if hasChanges { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? String(localized: "Добавить") : String(localized: "Готово"), action: save)
                        .fontWeight(.semibold)
                        .disabled(amount <= 0)
                }
            }
        }
        .unsavedChanges(hasChanges, confirm: $confirmDiscard) { dismiss() }
        .onAppear(perform: load)
    }

    /// «На свою карту» / «Со своей карты»: один раз отметили — такие же переводы станут «себе» сами.
    @ViewBuilder
    private var ownCardRow: some View {
        if let expense, expense.isInternal && !expense.manualInternal {
            HStack(spacing: 12) {
                SquareIcon(symbol: "arrow.triangle.2.circlepath", color: .teal)
                Text("Между своими картами — найдена пара")
                    .foregroundStyle(.secondary)
            }
        } else if expense != nil && onSave == nil {
            Picker(selection: $ownSide) {
                Text("Не моя карта").tag(OwnSide.none)
                ForEach(store.cards.filter { $0 != draft.card }, id: \.self) { card in
                    Text(store.cardTitle(card)).tag(OwnSide.card(card))
                }
                Text("Другая моя карта…").tag(OwnSide.other)
            } label: {
                HStack(spacing: 12) {
                    SquareIcon(symbol: "arrow.triangle.2.circlepath", color: .teal)
                    Text(draft.kind == .transferIn ? "Со своей карты" : "На свою карту")
                }
            }
            if ownSide == .other {
                TextField("Последние 4 цифры карты (необязательно)", text: $ownDigits)
                    .keyboardType(.numberPad)
                    .onChange(of: ownDigits) { _, text in ownDigits = String(text.filter(\.isNumber).prefix(4)) }
            }
        }
    }

    /// Факты из SMS — только для чтения, с замком.
    @ViewBuilder
    private var lockedFacts: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(Money.string(draft.isIncome ? draft.amount : -draft.amount, currency: draft.currency, sign: draft.isIncome))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(draft.isIncome ? .green : .primary)
                Text([draft.kind?.title ?? (draft.isIncome ? String(localized: "Доход") : String(localized: "Расход")), draft.title]
                    .joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            factRow(String(localized: "Карта"), symbol: "creditcard.fill", color: .indigo,
                    value: draft.card.map { store.cardTitle($0) } ?? "—")
            factRow(String(localized: "Дата"), symbol: "calendar", color: .red,
                    value: DueFormat.string(draft.date, hasTime: true))
            if let channel = expense?.channel, !channel.isEmpty {
                factRow(String(localized: "Через"), symbol: "arrow.left.arrow.right", color: .teal, value: channel)
            }
        } header: {
            Label(expense?.source == .statement ? "Из выписки банка" : "Из SMS банка", systemImage: "lock.fill")
        } footer: {
            Text("Сумму, дату, карту и поставщика из SMS изменить нельзя — это данные банка. Можно поменять категорию, указать, кому перевод, и добавить заметку.")
        }
    }

    private func factRow(_ title: String, symbol: String, color: Color, value: String) -> some View {
        HStack(spacing: 12) {
            SquareIcon(symbol: symbol, color: color)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var incomeBinding: Binding<Bool> {
        Binding { draft.isIncome } set: { income in
            draft.isIncome = income
            draft.category = income ? .income : (draft.category == .income ? .other : draft.category)
        }
    }

    private var amount: Double {
        Double(amountText.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// «1234567» → «1 234 567» прямо при вводе.
    private static func grouped(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: " ", with: "")
        let parts = clean.split(separator: clean.contains(",") ? "," : ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, whole.allSatisfy(\.isNumber) else { return text }
        var result = ""
        for (index, char) in whole.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { result.insert(" ", at: result.startIndex) }
            result.insert(char, at: result.startIndex)
        }
        if parts.count > 1 { result += (clean.contains(",") ? "," : ".") + parts[1] }
        return result
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        draft = expense?.draft ?? initial ?? ExpenseDraft()
        if let expense, expense.manualInternal {
            if let card = expense.counterpartCard, store.cards.contains(card) {
                ownSide = .card(card)
            } else {
                ownSide = .other
                ownDigits = expense.counterpartCard ?? ""
            }
        }
        if draft.amount > 0 {
            amountText = Self.grouped(draft.amount.rounded() == draft.amount ? String(Int(draft.amount)) : String(draft.amount))
        } else {
            amountFocused = true
        }
        originalDraft = draft
        originalAmount = amountText.filter(\.isNumber)
        originalOwn = ownSignature
    }

    private func save() {
        draft.amount = amount
        if draft.title.trimmed.isEmpty { draft.title = draft.category.title }
        if let onSave {
            onSave(draft)
        } else if let expense {
            store.update(expense, with: draft)
            if expense.isTransfer && !(expense.isInternal && !expense.manualInternal) {
                switch ownSide {
                case .none:
                    if expense.manualInternal { store.undoOwn(expense) }
                case .card(let card):
                    store.markOwn(expense, counterpartCard: card)
                case .other:
                    store.markOwn(expense, counterpartCard: ownDigits.count == 4 ? ownDigits : nil)
                }
            }
        } else {
            store.add([draft], source: .manual)
        }
        dismiss()
    }
}
