import SwiftUI

/// «Разделить счёт»: собрались вчетвером, счёт 600 000 — кто кому сколько должен.
/// Долги с вашим участием сохраняются в «Долги», итог можно отправить друзьям в чат.
struct SplitBillView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private struct Person: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var amountText = ""
        var isMe: Bool { name == SplitBillView.me }
    }

    static let me = String(localized: "Я")

    @State private var title = ""
    @State private var totalText = ""
    @State private var tip = 0
    @State private var people: [Person] = [Person(name: SplitBillView.me)]
    @State private var payer = SplitBillView.me
    @State private var equal = true
    @State private var newName = ""
    /// Общее на всех (салат на стол, сервис) — делится поровну поверх личных заказов.
    @State private var sharedText = ""
    @State private var saved = false
    @State private var confirmDiscard = false

    /// Что-то уже вписали — при выходе спросим.
    private var hasChanges: Bool {
        !title.trimmed.isEmpty || !totalText.isEmpty || people.count > 1 || !sharedText.isEmpty
    }
    @FocusState private var nameFocused: Bool

    /// Сумма счёта; если её не вписали, а делят по заказам — сумма всех позиций.
    private var total: Double {
        var bill = Double(totalText.filter(\.isNumber)) ?? 0
        if bill == 0 && !equal { bill = people.reduce(Self.sum(sharedText)) { $0 + Self.sum($1.amountText) } }
        return bill * (1 + Double(tip) / 100)
    }

    /// Доля каждого: поровну или как вписали (вписанное — без чаевых, чаевые делятся пропорционально).
    private var shares: [UUID: Double] {
        guard !people.isEmpty, total > 0 else { return [:] }
        if equal {
            let share = (total / Double(people.count)).rounded()
            return Dictionary(uniqueKeysWithValues: people.map { ($0.id, share) })
        }
        // Личное: «35 000 + 12 000» — сумма позиций. Общее делится поровну.
        let shared = Self.sum(sharedText) / Double(people.count)
        let entered = people.map { Self.sum($0.amountText) + shared }
        let sum = entered.reduce(0, +)
        guard sum > 0 else { return [:] }
        // Разница со счётом (обслуживание, чаевые, округление) — пропорционально заказу.
        let factor = total / sum
        return Dictionary(uniqueKeysWithValues: zip(people.map(\.id), entered.map { ($0 * factor).rounded() }))
    }

    /// Кто кому должен: все, кроме плательщика, отдают ему свою долю.
    private var transfers: [(from: String, to: String, amount: Double)] {
        people.filter { $0.name != payer }.compactMap { person in
            guard let share = shares[person.id], share > 0 else { return nil }
            return (person.name, payer, share)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Где: «Ужин в Plov Center»", text: $title)
                    HStack(alignment: .firstTextBaseline) {
                        TextField(equal ? String(localized: "Сумма счёта") : String(localized: "Сумма счёта (необязательно)"), text: $totalText)
                            .keyboardType(.numberPad)
                            .amountFormatting($totalText)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("сум").foregroundStyle(.secondary)
                    }
                    Picker("Чаевые", selection: $tip) {
                        ForEach([0, 5, 10, 15], id: \.self) { Text($0 == 0 ? String(localized: "Без чаевых") : "\($0)%").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach($people) { $person in
                        HStack {
                            Text(person.name)
                            if person.name == payer {
                                Text("платил").font(.caption.weight(.semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2).background(Color.green, in: Capsule())
                            }
                            Spacer()
                            if equal {
                                Text(shares[person.id].map { Money.string($0) } ?? "—").foregroundStyle(.secondary).monospacedDigit()
                            } else {
                                TextField("25 000 + 18 000", text: $person.amountText)
                                    .keyboardType(.numbersAndPunctuation)
                                    .amountFormatting($person.amountText)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 130)
                            }
                        }
                        .swipeActions {
                            if !person.isMe {
                                Button(role: .destructive) { remove(person) } label: { Label("Убрать", systemImage: "trash") }
                            }
                        }
                    }
                    HStack {
                        TextField("Добавить друга", text: $newName)
                            .focused($nameFocused)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)
                            .onSubmit(addTyped)
                        if !newName.trimmed.isEmpty {
                            Button("Добавить", action: addTyped).fontWeight(.semibold)
                        }
                    }
                    let known = store.people.filter { name in !people.contains { $0.name == name } }.prefix(10)
                    if !known.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(known), id: \.self) { name in
                                    Button { add(name) } label: {
                                        Label(name, systemImage: "plus").font(.subheadline)
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(Color(.tertiarySystemFill), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "Участники — \(people.count)"))
                }

                Section {
                    Picker("Кто платил", selection: $payer) {
                        ForEach(people) { Text($0.name).tag($0.name) }
                    }
                    Picker("Как делить", selection: $equal) {
                        Text("Поровну").tag(true)
                        Text("Кто что заказал").tag(false)
                    }
                    if !equal {
                        HStack {
                            Text("Общее на всех")
                            Spacer()
                            TextField("салат, хлеб", text: $sharedText)
                                .keyboardType(.numbersAndPunctuation)
                                .amountFormatting($sharedText)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 140)
                        }
                    }
                } footer: {
                    if !equal {
                        Text("У каждого впишите цены его позиций через «+»: «35 000 + 12 000». Общее делится поровну. Если по счёту выходит больше (обслуживание, чаевые), разница делится пропорционально заказу.")
                    }
                }

                if !transfers.isEmpty {
                    Section {
                        ForEach(Array(transfers.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item.from == Self.me ? String(localized: "Вы") : item.from).fontWeight(.medium)
                                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                                Text(item.to == Self.me ? String(localized: "вам") : item.to)
                                Spacer()
                                Text(Money.string(item.amount)).monospacedDigit().fontWeight(.semibold)
                                    .foregroundStyle(item.to == Self.me ? .green : (item.from == Self.me ? .orange : .primary))
                            }
                        }
                        ShareLink(item: shareText) {
                            Label("Отправить друзьям", systemImage: "square.and.arrow.up")
                        }
                    } header: {
                        Text("Итог")
                    } footer: {
                        Text("Нажмите «Сохранить» — долги с вашим участием появятся в «Долгах», а когда друг переведёт деньги, отметьте это на экране «Кому были переводы?».")
                    }
                }
            }
            .navigationTitle("Разделить счёт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { if hasChanges { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить", action: save)
                        .fontWeight(.semibold)
                        .disabled(transfers.isEmpty)
                }
            }
        }
        .unsavedChanges(hasChanges, confirm: $confirmDiscard) { dismiss() }
    }

    /// «35 000 + 12000» → 47000.
    static func sum(_ text: String) -> Double {
        text.split(whereSeparator: { $0 == "+" || $0 == "," || $0 == ";" })
            .compactMap { Double($0.filter(\.isNumber)) }
            .reduce(0, +)
    }

    private func addTyped() {
        add(newName)
        newName = ""
        nameFocused = true
    }

    private func add(_ name: String) {
        let name = name.trimmed.capitalizedFirst
        guard !name.isEmpty, !people.contains(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        withAnimation { people.append(Person(name: name)) }
    }

    private func remove(_ person: Person) {
        people.removeAll { $0.id == person.id }
        if payer == person.name { payer = Self.me }
    }

    private var shareText: String {
        var lines = [title.trimmed.isEmpty ? String(localized: "Делим счёт") : title.trimmed,
                     String(localized: "Итого: \(Money.string(total))") + (tip > 0 ? " (" + String(localized: "с чаевыми \(tip)%") + ")" : "")]
        for item in transfers {
            let from = item.from == Self.me ? store.myName : item.from
            let to = item.to == Self.me ? store.myName : item.to
            lines.append("• \(from) → \(to): \(Money.string(item.amount))")
        }
        // Кто-то переводит вам — сразу номер карты из профиля.
        if transfers.contains(where: { $0.to == Self.me }), let payout = Profile.shared.payoutText {
            lines.append("")
            lines.append(String(localized: "Куда переводить мне:"))
            lines.append(payout)
        }
        lines.append("")
        lines.append(String(localized: "Посчитано в Hamyon"))
        return lines.joined(separator: "\n")
    }

    private func save() {
        let bill = title.trimmed.isEmpty ? String(localized: "Общий счёт") : title.trimmed
        for item in transfers where item.from == Self.me || item.to == Self.me {
            let lent = item.to == Self.me
            store.addDebt(DebtDraft(person: lent ? item.from : item.to, amount: item.amount, lent: lent,
                                    dueDate: Calendar.current.date(byAdding: .day, value: 3, to: .now), billTitle: bill))
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
