import SwiftUI

/// Регулярные платежи: интернет, связь, аренда, кредит, переводы родным — с напоминанием накануне.
struct RecurringView: View {
    @Environment(ExpenseStore.self) private var store
    @State private var recurring = RecurringStore.shared
    @State private var editing: RecurringPayment?
    @State private var creating = false

    var body: some View {
        let month = ExpenseStore.month(containing: .now)
        List {
            Section {
                VStack(spacing: 2) {
                    Text(Money.string(recurring.monthlyTotal))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("в месяц на регулярные платежи").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)

            if !recurring.suggested.isEmpty {
                Section {
                    ForEach(recurring.suggested) { item in
                        HStack(spacing: 12) {
                            IconCircle(symbol: item.category.symbol, color: item.category.color, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                Text(String(localized: "≈ \(Money.string(item.amount)) · около \(item.day)-го"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { withAnimation { recurring.hide(item) } } label: {
                                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 34, height: 34)
                                    .background(Color(.tertiarySystemFill), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Не регулярный")
                            Button { withAnimation { recurring.confirm(item) } } label: {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                                    .frame(width: 34, height: 34).background(Color.green, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Да, регулярный")
                        }
                    }
                } header: {
                    Text("Похоже на регулярные")
                } footer: {
                    Text("Нашёл по операциям: та же сумма примерно в один день каждого месяца. Подтвердите — и накануне придёт напоминание.")
                }
            }

            Section {
                if recurring.active.isEmpty {
                    Text("Пока пусто. Добавьте платёж — интернет, аренду, кредит — и получайте напоминание накануне.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recurring.active) { item in
                    let paid = recurring.payment(for: item, in: month, store: store)
                    Button { editing = item } label: { row(item, paid: paid) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { recurring.delete(item) } label: { Label("Удалить", systemImage: "trash") }
                        }
                }
            } header: {
                Text("Мои платежи")
            }
        }
        .navigationTitle("Регулярные платежи")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Новый платёж")
            }
        }
        .sheet(item: $editing) { RecurringEditView(item: $0) }
        .sheet(isPresented: $creating) { RecurringEditView(item: nil) }
        .onAppear { recurring.detect(from: store) }
    }

    private func row(_ item: RecurringPayment, paid: Expense?) -> some View {
        let next = item.nextDate(paidThisMonth: paid != nil)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: next).day ?? 0
        return HStack(spacing: 12) {
            IconCircle(symbol: item.category.symbol, color: item.category.color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.title).lineLimit(1)
                    if item.remind { Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Group {
                    if let paid {
                        Text(String(localized: "Оплачено \(DueFormat.string(paid.date, hasTime: false))")).foregroundStyle(.green)
                    } else if days == 0 {
                        Text("Сегодня").foregroundStyle(.orange)
                    } else if days == 1 {
                        Text("Завтра").foregroundStyle(.orange)
                    } else {
                        Text(String(localized: "Через \(days) дн. · \(DueFormat.string(next, hasTime: false))")).foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
            Spacer()
            Text(Money.string(item.amount)).monospacedDigit().fontWeight(.medium)
        }
        .contentShape(Rectangle())
    }
}

struct RecurringEditView: View {
    let item: RecurringPayment?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amountText = ""
    @State private var day = Calendar.current.component(.day, from: .now)
    @State private var category: ExpenseCategory = .connection
    @State private var remind = true
    @State private var loaded = false
    @State private var original = ""
    @State private var confirmDiscard = false

    private var signature: String {
        "\(title.trimmed)|\(amountText.filter(\.isNumber))|\(day)|\(category.rawValue)|\(remind)"
    }

    private var hasChanges: Bool { loaded && signature != original }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название: интернет, аренда, кредит", text: $title)
                    HStack {
                        TextField("Сумма", text: $amountText).keyboardType(.numberPad).amountFormatting($amountText)
                        Text("сум").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("День месяца", selection: $day) {
                        ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Категория", selection: $category) {
                        ForEach(ExpenseCategory.expenseCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Toggle("Напомнить накануне", isOn: $remind).tint(.green)
                } footer: {
                    Text("Напоминание придёт в 10:00 за день до платежа.")
                }
                if let item {
                    Section {
                        Button("Удалить", role: .destructive) {
                            RecurringStore.shared.delete(item)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? String(localized: "Новый платёж") : String(localized: "Платёж"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { if hasChanges { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово", action: save)
                        .fontWeight(.semibold)
                        .disabled(title.trimmed.isEmpty || amount <= 0)
                }
            }
        }
        .unsavedChanges(hasChanges, confirm: $confirmDiscard) { dismiss() }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let item {
                title = item.title
                amountText = String(Int(item.amount))
                day = item.day
                category = item.category
                remind = item.remind
            }
            original = signature
        }
        .task { await Notifier.requestPermission() }
    }

    private var amount: Double { Double(amountText.filter(\.isNumber)) ?? 0 }

    private func save() {
        let id = item?.id ?? "m:" + UUID().uuidString
        RecurringStore.shared.upsert(RecurringPayment(id: id, title: title.trimmed, amount: amount, day: day,
                                                      categoryRaw: category.rawValue, remind: remind))
        dismiss()
    }
}

/// Лимиты на месяц: общий и по категориям.
struct BudgetsView: View {
    @Environment(ExpenseStore.self) private var store
    @State private var budgets = BudgetStore.shared
    @State private var editing: String?
    @State private var valueText = ""

    var body: some View {
        let totals = store.totals(in: ExpenseStore.month(containing: .now))
        List {
            Section {
                budgetRow(key: "total", title: String(localized: "Весь месяц"), symbol: "calendar", color: .green,
                          spent: totals.spent)
            } footer: {
                if let daily = budgets.dailyAllowance(spent: totals.spent) {
                    Text(String(localized: "Чтобы уложиться, тратьте не больше ≈ \(Money.string(daily)) в день."))
                }
            }
            Section {
                ForEach(ExpenseCategory.expenseCases.sorted { (totals.byCategory[$0] ?? 0) > (totals.byCategory[$1] ?? 0) }) { category in
                    budgetRow(key: category.rawValue, title: category.title, symbol: category.symbol, color: category.color,
                              spent: totals.byCategory[category] ?? 0)
                }
            } header: {
                Text("По категориям")
            } footer: {
                Text("При 80% и 100% лимита придёт уведомление. Переводы между своими картами не считаются.")
            }
        }
        .navigationTitle("Бюджеты")
        // Основная кнопка «Сохранить» в окне лимита — синяя, как принято в iOS.
        .tint(.blue)
        .alert("Лимит на месяц", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Сумма, сум", text: $valueText).keyboardType(.numberPad).amountFormatting($valueText)
            Button("Сохранить") {
                if let editing { budgets.set(Double(valueText.filter(\.isNumber)), for: editing) }
                editing = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Убрать лимит", role: .destructive) {
                if let editing { budgets.set(nil, for: editing) }
                editing = nil
            }
            Button("Отменить", role: .cancel) { editing = nil }
        }
        .task { await Notifier.requestPermission() }
    }

    private func budgetRow(key: String, title: String, symbol: String, color: Color, spent: Double) -> some View {
        let limit = budgets.limits[key]
        return Button {
            valueText = limit.map { String(Int($0)) } ?? ""
            editing = key
        } label: {
            HStack(spacing: 12) {
                IconCircle(symbol: symbol, color: color, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(title)
                        Spacer()
                        if let limit {
                            Text("\(Money.short(spent)) / \(Money.short(limit))")
                                .monospacedDigit()
                                .foregroundStyle(spent > limit ? .red : .secondary)
                        } else {
                            Text(spent > 0 ? Money.short(spent) : "").foregroundStyle(.secondary)
                            Text("Задать").foregroundStyle(.green)
                        }
                    }
                    .font(.subheadline)
                    if let limit {
                        BudgetBar(share: spent / max(limit, 1), color: color)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Полоска бюджета: цвет категории, после 80% — оранжевая, после 100% — красная.
struct BudgetBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(share >= 1 ? Color.red : share >= 0.8 ? Color.orange : color)
                    .frame(width: max(4, proxy.size.width * min(share, 1)))
            }
        }
        .frame(height: 5)
    }
}
