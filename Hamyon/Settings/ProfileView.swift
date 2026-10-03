import PhotosUI
import SwiftUI

/// Профиль — с аватарки на «Обзоре»: личные данные, карты для переводов, друзья, настройки, поддержка.
struct ProfileView: View {
    @Environment(ExpenseStore.self) private var store
    @State private var profile = Profile.shared
    @State private var showPersonal = false
    /// `-openInvite`: сразу «Пригласить друзей» (проверка в симуляторе).
    @State private var showInvite = ProcessInfo.processInfo.arguments.contains("-openInvite")
    @State private var invited = InviteLog.all.count
    /// `-openSettings` вместе с `-openProfile`: сразу «Настройки» (проверка в симуляторе).
    @State private var showSettings = ProcessInfo.processInfo.arguments.contains("-openSettings")

    var body: some View {
        List {
            Section {
                Button { showPersonal = true } label: { header }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            }

            if !store.expenses.isEmpty {
                Section { stats }
            }

            Section {
                NavigationLink { PersonalDataView() } label: {
                    HubRow(title: "Личные данные", symbol: "person.text.rectangle.fill", color: .blue)
                }
                NavigationLink { PayoutCardsView() } label: {
                    HubRow(title: "Куда переводить мне", symbol: "creditcard.fill", color: .green, value: payoutValue)
                }
                Button { showInvite = true } label: {
                    HubRow(title: "Пригласить друзей", symbol: "person.2.fill", color: .orange,
                           value: invited > 0 ? String(localized: "Приглашено: \(invited)") : nil, accessory: "chevron.right")
                }
                .tint(.primary)
            }

            Section {
                NavigationLink { SettingsView() } label: {
                    HubRow(title: "Настройки", symbol: "gearshape.fill", color: .gray)
                }
                if Support.isAvailable {
                    Button(action: Support.open) {
                        HubRow(title: "Написать в поддержку", symbol: "bubble.left.fill", color: .teal, accessory: "arrow.up.right")
                    }
                    .tint(.primary)
                }
            } footer: {
                Text(Support.versionLine)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
        }
        .contentMargins(.bottom, 12, for: .scrollContent)
        // Фото сразу под заголовком, без пустой полосы над первой секцией.
        .contentMargins(.top, 0, for: .scrollContent)
        .listSectionSpacing(.compact)
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPersonal) { PersonalDataView() }
        .navigationDestination(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showInvite, onDismiss: { invited = InviteLog.all.count }) { InviteView() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            AvatarCircle(image: profile.photo, initials: profile.initials, size: 104)
                .padding(.bottom, 6)
            Text(profile.displayName.isEmpty ? String(localized: "Ваше имя") : profile.displayName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(profile.displayName.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
            if !profile.phone.trimmed.isEmpty {
                Text(PhoneFormat.uz(profile.phone))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// Три колонки: сколько операций, карт и с какого месяца — вместо одной длинной строки.
    private var stats: some View {
        HStack(spacing: 0) {
            stat(store.expenses.count.formatted(), "Всего операций")
            Divider().frame(height: 32)
            stat(store.cards.count.formatted(), "Карты")
            if let first = store.expenses.map(\.date).min() {
                Divider().frame(height: 32)
                stat(first.formatted(.dateTime.month(.abbreviated).year().locale(DueFormat.locale)), "В Hamyon с")
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ title: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }

    private var payoutValue: String {
        let cards = profile.payoutCards
        if cards.isEmpty { return String(localized: "Не указаны") }
        return cards.count <= 2 ? cards.map { "•\($0.last4)" }.joined(separator: ", ") : String(localized: "Карт: \(cards.count)")
    }
}

/// Строка профиля: цветной значок, название, значение справа.
private struct HubRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    var value: String?
    /// Для кнопок — своя стрелка: у NavigationLink она рисуется сама.
    var accessory: String?

    var body: some View {
        HStack {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                SquareIcon(symbol: symbol, color: color)
            }
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let accessory {
                Image(systemName: accessory)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Имя, телефон, фото и как банк пишет ваше имя. Сохраняется сразу, без кнопки «Готово».
struct PersonalDataView: View {
    @Environment(ExpenseStore.self) private var store
    @State private var profile = Profile.shared
    @State private var pickerItem: PhotosPickerItem?
    @State private var ownNames: [String] = []

    var body: some View {
        @Bindable var profile = profile
        Form {
            Section {
                VStack(spacing: 12) {
                    AvatarCircle(image: profile.photo, initials: profile.initials, size: 104)
                    HStack(spacing: 16) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Text(profile.photo == nil ? String(localized: "Выбрать фото") : String(localized: "Сменить фото"))
                        }
                        if profile.photo != nil {
                            Button("Удалить", role: .destructive) { profile.setPhoto(nil) }
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Имя и фамилия", text: $profile.name)
                    .textContentType(.name)
                TextField("+998 90 123 45 67", text: $profile.phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .onChange(of: profile.phone) { old, new in
                        let formatted = PhoneFormat.uz(new, deleting: new.count < old.count)
                        if formatted != new { profile.phone = formatted }
                    }
            } footer: {
                if profile.name.trimmed.isEmpty, let suggested = profile.suggestedName {
                    Button(String(localized: "Как в выписках: \(suggested)")) { profile.name = suggested }
                        .font(.footnote)
                } else {
                    Text("Имя видно друзьям в сообщениях из «Разделить счёт».")
                }
            }
            if !ownNames.isEmpty {
                Section {
                    ForEach(ownNames, id: \.self) { name in
                        Text(name.split(separator: " ").map { $0.capitalized }.joined(separator: " "))
                    }
                    .onDelete { offsets in
                        var names = store.ownCounterpartNames
                        for index in offsets { names.remove(ownNames[index]) }
                        store.ownCounterpartNames = names
                        ownNames.remove(atOffsets: offsets)
                    }
                } header: {
                    Text("Вы в выписках")
                } footer: {
                    Text("Так банк пишет ваше имя. Переводы на эти имена считаются переводами себе.")
                }
            }
        }
        .navigationTitle("Личные данные")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ownNames = store.ownCounterpartNames.sorted() }
        .onDisappear {
            profile.name = profile.name.trimmed
            profile.phone = PhoneFormat.hasNumber(profile.phone) ? PhoneFormat.uz(profile.phone.trimmed) : ""
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    profile.setPhoto(image)
                }
                pickerItem = nil
            }
        }
    }
}

/// Карты, на которые вам переводят: нажатие копирует номер.
struct PayoutCardsView: View {
    @State private var profile = Profile.shared
    @State private var editingCard: CardTarget?
    @State private var copied: UUID?

    private struct CardTarget: Identifiable {
        let id: UUID
        let card: PayoutCard?
    }

    var body: some View {
        List {
            Section {
                ForEach(profile.payoutCards) { card in
                    payoutRow(card)
                }
                .onDelete { profile.payoutCards.remove(atOffsets: $0) }
                Button {
                    editingCard = CardTarget(id: UUID(), card: nil)
                } label: {
                    Label("Добавить карту", systemImage: "plus")
                }
                if let payout = profile.payoutText {
                    ShareLink(item: payout) {
                        Label("Отправить реквизиты", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("Нажмите на карту, чтобы скопировать номер. В «Разделить счёт» он сам добавится в сообщение друзьям. Номер хранится только на этом телефоне.")
            }
        }
        .navigationTitle("Куда переводить мне")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingCard) { PayoutCardEditView(card: $0.card) }
    }

    private func payoutRow(_ card: PayoutCard) -> some View {
        Button {
            UIPasteboard.general.string = card.number
            withAnimation(.snappy) { copied = card.id }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.snappy) { if copied == card.id { copied = nil } }
            }
        } label: {
            HStack(spacing: 12) {
                CardThumbnail(bank: Bank.find(card.bank), network: card.network, width: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.formatted)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text([card.network?.title, Bank.find(card.bank)?.name, card.holder.trimmed.isEmpty ? nil : card.holder.uppercased()]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if copied == card.id {
                    Label("Скопировано", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: copied) { _, new in new == card.id }
        .swipeActions(edge: .trailing) {
            Button("Удалить", systemImage: "trash", role: .destructive) {
                profile.payoutCards.removeAll { $0.id == card.id }
            }
            Button("Изменить", systemImage: "pencil") {
                editingCard = CardTarget(id: card.id, card: card)
            }
            .tint(.orange)
        }
        .contextMenu {
            Button("Изменить", systemImage: "pencil") { editingCard = CardTarget(id: card.id, card: card) }
            ShareLink(item: card.shareLine) { Label("Поделиться", systemImage: "square.and.arrow.up") }
            Button("Удалить", systemImage: "trash", role: .destructive) {
                profile.payoutCards.removeAll { $0.id == card.id }
            }
        }
    }
}

/// Круглое фото или инициалы на цветном фоне.
struct AvatarCircle: View {
    let image: UIImage?
    let initials: String
    var color: Color = .green
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if !initials.isEmpty {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(color.gradient)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGray3).gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Карта для переводов вам: полный номер, имя на карте, банк.
struct PayoutCardEditView: View {
    let card: PayoutCard?

    @Environment(ExpenseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PayoutCard()
    @State private var numberText = ""
    @State private var original = PayoutCard()
    @State private var loaded = false
    @State private var confirmDiscard = false

    private var digits: String { numberText.filter(\.isASCII).filter(\.isNumber) }
    private var complete: Bool { (16...19).contains(digits.count) }
    private var hasChanges: Bool { loaded && (digits != original.number || draft.holder != original.holder || draft.bank != original.bank) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CardThumbnail(bank: Bank.find(draft.bank), network: CardNetwork(cardNumber: digits), width: 180)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 6)
                }
                Section {
                    TextField("Номер карты", text: $numberText)
                        .keyboardType(.numberPad)
                        .textContentType(.creditCardNumber)
                        .monospacedDigit()
                        .onChange(of: numberText) { _, value in
                            let only = String(value.filter(\.isASCII).filter(\.isNumber).prefix(19))
                            let grouped = PayoutCard.group(only)
                            if grouped != value { numberText = grouped }
                            // Своя карта, по которой приходят SMS, — банк уже известен.
                            if only.count >= 16, draft.bank == nil, let bank = store.meta(String(only.suffix(4))).bank {
                                draft.bank = bank
                            }
                        }
                    TextField("Имя на карте", text: $draft.holder)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    if complete && !PayoutCard.luhnValid(digits) {
                        Label("Проверьте номер — похоже, в нём опечатка.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Имя — латиницей, как на карте: так друг убедится, что переводит вам.")
                    }
                }
                Section {
                    Picker("Банк", selection: $draft.bank) {
                        Text("Не выбран").tag(String?.none)
                        ForEach(Bank.all) { bank in
                            Text(bank.name).tag(Optional(bank.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            .navigationTitle(card == nil ? String(localized: "Новая карта") : String(localized: "Карта"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") { if hasChanges { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(card == nil ? String(localized: "Добавить") : String(localized: "Готово"), action: save)
                        .fontWeight(.semibold)
                        .disabled(!complete)
                }
            }
        }
        .unsavedChanges(hasChanges, confirm: $confirmDiscard) { dismiss() }
        .onAppear {
            guard !loaded else { return }
            if let card {
                draft = card
                numberText = card.formatted
            } else if let suggested = Profile.shared.suggestedName {
                draft.holder = suggested.uppercased()
            }
            original = draft
            loaded = true
        }
    }

    private func save() {
        draft.number = digits
        draft.holder = draft.holder.trimmed
        let profile = Profile.shared
        if let index = profile.payoutCards.firstIndex(where: { $0.id == draft.id }) {
            profile.payoutCards[index] = draft
        } else {
            profile.payoutCards.append(draft)
        }
        dismiss()
    }
}

extension ToolbarContent {
    /// Фото в панели — без стеклянного круга вокруг (iOS 26), как аватар в App Store.
    @ToolbarContentBuilder
    func profileButtonBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
