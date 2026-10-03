import SwiftUI

/// «Карты»: как в банковских приложениях — мини-карта в цветах банка, банк, остаток и номер.
struct CardsView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var editing: EditTarget?
    @State private var adding = false
    @Environment(AppNavigation.self) private var navigation

    private struct EditTarget: Identifiable { let id: String }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if store.cards.isEmpty {
                    ContentUnavailableView {
                        Label("Карт пока нет", systemImage: "creditcard")
                    } description: {
                        Text("Карты появятся сами, когда придут SMS банка с номером карты. Или добавьте карту вручную.")
                    } actions: {
                        Button("Добавить карту") { adding = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 60)
                } else {
                    if store.cards.count > 1 { totalRow }
                    ForEach(store.cards, id: \.self) { card in
                        Button { editing = EditTarget(id: card) } label: { CardRow(card: card) }
                            .buttonStyle(PressStyle())
                    }
                    cashRow
                    Text("Нажмите на карту, чтобы выбрать банк, платёжную систему и название. Номер и остаток берутся из SMS банка.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Карты")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { settings.hideBalances.toggle() }
                } label: {
                    Image(systemName: settings.hideBalances ? "eye.slash" : "eye")
                }
                .accessibilityLabel(settings.hideBalances ? "Показать остатки" : "Скрыть остатки")
            }
        }
        .overlay(alignment: .bottom) {
            Button { adding = true } label: {
                Label("Карта", systemImage: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .foregroundStyle(Color(.systemBackground))
                    .background(Color(.label), in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            }
            .buttonStyle(PressStyle())
            // Над нижней панелью вкладок.
            .padding(.bottom, 16)
            .accessibilityLabel("Добавить карту")
        }
        .sheet(item: $editing) { CardEditView(card: $0.id) }
        .sheet(isPresented: $adding) { CardEditView(card: nil) }
    }

    /// Сколько всего на картах.
    /// Кошелёк наличных — рядом с картами.
    private var cashRow: some View {
        Button { navigation.sheet = .cash } label: {
            HStack(spacing: 14) {
                Image(systemName: "banknote.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 40)
                    .background(Color.mint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Наличные").font(.subheadline).foregroundStyle(.secondary)
                    Text(store.cashTracking ? (settings.hideBalances ? "••••" : Money.string(store.cashBalance)) : String(localized: "Вести кошелёк"))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    private var totalRow: some View {
        let total = store.cardBalances.reduce(0) { $0 + $1.balance }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Всего на картах")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Group {
                if settings.hideBalances { Text("•••••• \(String(localized: "сум"))") } else { CountUpMoney(value: total) }
            }
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// Строка карты: мини-карта слева; справа банк, крупно остаток и номер.
private struct CardRow: View {
    let card: String

    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let meta = store.meta(card)
        let bank = Bank.find(meta.bank)
        let info = store.cardBalances.first { $0.card == card }
        HStack(alignment: .top, spacing: 18) {
            CardThumbnail(bank: bank, network: meta.network.flatMap(CardNetwork.init(rawValue:)), width: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(meta: meta, bank: bank))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let info {
                    Group {
                        if settings.hideBalances { Text("•••••• \(String(localized: "сум"))") } else { CountUpMoney(value: info.balance) }
                    }
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                        .padding(.top, 4)
                }
                Text("**\(card)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// «Aloqabank · Зарплатная»: сначала банк, потом ваше название.
    private func title(meta: CardMeta, bank: Bank?) -> String {
        [bank?.name, meta.name.isEmpty ? nil : meta.name].compactMap { $0 }.joined(separator: " · ")
            .nonEmpty ?? String(localized: "Банк не выбран")
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Настройка карты: банк, платёжная система, название. Без номера (`card == nil`) — новая карта вручную.
struct CardEditView: View {
    let card: String?

    @Environment(ExpenseStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var digits = ""
    @State private var meta = CardMeta()
    @State private var loaded = false
    @State private var balanceText = ""
    @State private var original = ""
    @State private var confirmDiscard = false

    /// Снимок полей — чтобы понять, есть ли несохранённые изменения.
    private var signature: String {
        [digits.filter(\.isNumber), meta.name, String(describing: meta.bank), String(describing: meta.network),
         balanceText.filter(\.isNumber)].joined(separator: "|")
    }

    private var hasChanges: Bool { loaded && signature != original }

    private var hasSMS: Bool { card.map { c in store.expenses.contains { $0.card == c && $0.source == .sms } } ?? false }

    private var isNew: Bool { card == nil }
    private var number: String { card ?? digits }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CardThumbnail(bank: Bank.find(meta.bank), network: meta.network.flatMap(CardNetwork.init(rawValue:)),
                                      width: 180)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 6)
                }
                Section {
                    if isNew {
                        TextField("Номер карты или последние 4 цифры", text: $digits)
                            .keyboardType(.numberPad)
                            .textContentType(.creditCardNumber)
                            .onChange(of: digits) { _, value in
                                let only = value.filter(\.isNumber)
                                // Полный номер не храним: по первым цифрам определяем систему, оставляем последние 4.
                                if only.count > 4 {
                                    if let network = CardNetwork(cardNumber: only) { meta.network = network.rawValue }
                                    digits = String(only.suffix(4))
                                } else if only != value {
                                    digits = only
                                }
                            }
                    } else {
                        LabeledContent("Номер", value: "•••• \(number)")
                    }
                    TextField("Название, например «Зарплатная»", text: $meta.name)
                }
                if !hasSMS {
                    Section {
                        TextField("Остаток, сум", text: $balanceText)
                            .keyboardType(.decimalPad)
                            .amountFormatting($balanceText)
                    } footer: {
                        Text("По этой карте не приходят SMS — остаток можно вписать сам или взять со скриншота через «Импорт».")
                    }
                }
                Section("Банк") {
                    Picker("Банк", selection: $meta.bank) {
                        Text("Не выбран").tag(String?.none)
                        ForEach(Bank.all) { bank in
                            Text(bank.name).tag(Optional(bank.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Платёжная система", selection: $meta.network) {
                        Text("Не выбрана").tag(String?.none)
                        ForEach(CardNetwork.allCases) { network in
                            Text(network.title).tag(Optional(network.rawValue))
                        }
                    }
                }
                if let card, meta.manual, store.expenses.allSatisfy({ $0.card != card }) {
                    Section {
                        Button("Удалить карту", role: .destructive) {
                            store.removeManualCard(card)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? String(localized: "Новая карта") : String(localized: "Карта"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { if hasChanges { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? String(localized: "Добавить") : String(localized: "Готово"), action: save)
                        .fontWeight(.semibold)
                        .disabled(number.count != 4)
                }
            }
        }
        .unsavedChanges(hasChanges, confirm: $confirmDiscard) { dismiss() }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let card { meta = store.meta(card) } else { meta.manual = true }
            if let balance = meta.balance { balanceText = String(Int(balance)) }
            original = signature
        }
    }

    private func save() {
        meta.name = meta.name.trimmed
        let typed = Double(balanceText.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: "."))
        if let typed, typed != meta.balance {
            meta.balance = typed
            meta.balanceDate = .now
        }
        store.setMeta(meta, for: number)
        dismiss()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
