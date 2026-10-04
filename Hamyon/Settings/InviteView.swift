import Contacts
import ContactsUI
import MessageUI
import SwiftUI

/// Пригласить друзей из контактов: отмечаете людей и отправляете каждому отдельное сообщение — по SMS или в Telegram.
struct InviteView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(\.openURL) private var openURL

    @AppStorage("inviteText", store: Account.defaults) private var inviteText = InviteView.defaultText
    @State private var access = CNContactStore.authorizationStatus(for: .contacts)
    @State private var contacts: [PhoneContact] = []
    @State private var loading = true
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var invites = InviteLog.all
    @State private var pickMore = false
    @State private var noSMS = false

    /// SMS уходят по одному: следующее окно открывается, когда закрылось предыдущее.
    @State private var smsQueue: [PhoneContact] = []
    @State private var composing: PhoneContact?
    /// Telegram открывается по одному чату; вернулись в Hamyon — внизу кнопка «Дальше».
    @State private var telegramQueue: [PhoneContact] = []
    @State private var telegramTotal = 0

    static var defaultText: String {
        String(localized: "Привет! Я веду расходы в Hamyon — он сам читает SMS от банка, показывает, куда уходят деньги, и делит общий счёт за пару секунд. Попробуй тоже!")
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Пригласить друзей")
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .task { await load() }
        .contactAccessPicker(isPresented: $pickMore) { _ in
            Task { await load() }
        }
        .sheet(item: $composing, onDismiss: { composing = smsQueue.first }) { contact in
            MessageComposer(recipient: contact.smsAddress, body: inviteText) { sent in
                if sent {
                    mark(contact, via: .sms)
                    smsQueue.removeAll { $0.id == contact.id }
                } else {
                    // Отменили — остальные остаются отмеченными, можно продолжить позже.
                    smsQueue = []
                }
                composing = nil
            }
            .ignoresSafeArea()
        }
        .alert("SMS не отправить", isPresented: $noSMS) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("На этом устройстве нет «Сообщений». Попробуйте через Telegram.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .denied, .restricted:
            ContentUnavailableView {
                Label("Нет доступа к контактам", systemImage: "person.crop.circle.badge.xmark")
            } description: {
                Text("Разрешите доступ в Настройках — Hamyon покажет, кого можно пригласить. Контакты не покидают телефон.")
            } actions: {
                Button("Открыть Настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        default:
            if loading && contacts.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if query.isEmpty {
                Section {
                    TextField("Сообщение", text: $inviteText, axis: .vertical)
                        .lineLimit(3...8)
                    if inviteText != Self.defaultText {
                        Button("Вернуть стандартный текст") { inviteText = Self.defaultText }
                            .font(.subheadline)
                    }
                } header: {
                    Text("Сообщение")
                } footer: {
                    Text("Каждый получит отдельное сообщение — номеров друг друга никто не увидит.")
                }
                if access == .limited {
                    Section {
                        Button {
                            pickMore = true
                        } label: {
                            Label("Показать другие контакты", systemImage: "person.crop.circle.badge.plus")
                        }
                    } footer: {
                        Text("Hamyon видит только контакты, которые вы выбрали.")
                    }
                }
                if !known.isEmpty {
                    Section("Вы делите с ними деньги") {
                        ForEach(known) { row($0) }
                    }
                }
            }
            Section {
                ForEach(filtered) { row($0) }
            } header: {
                if query.isEmpty && !contacts.isEmpty { Text("Все контакты") }
            }
            if contacts.isEmpty {
                Section { Text("В контактах нет номеров телефонов.").foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $query, prompt: "Имя или номер")
        .safeAreaInset(edge: .bottom) {
            if let next = telegramQueue.first {
                telegramBar(next)
            } else if !selection.isEmpty {
                actionBar
            }
        }
        .animation(.snappy, value: selection.isEmpty)
        .animation(.snappy, value: telegramQueue.isEmpty)
    }

    // MARK: - Строки

    private func row(_ contact: PhoneContact) -> some View {
        let selected = selection.contains(contact.id)
        let invite = invites[contact.key]
        return Button {
            if selected { selection.remove(contact.id) } else { selection.insert(contact.id) }
        } label: {
            HStack(spacing: 12) {
                AvatarCircle(image: contact.thumbnail.flatMap(UIImage.init(data:)), initials: contact.initials,
                             color: contact.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let invite {
                        Text(invite.via == .sms
                             ? String(localized: "Приглашён по SMS · \(DueFormat.string(invite.date, hasTime: false))")
                             : String(localized: "Приглашён в Telegram · \(DueFormat.string(invite.date, hasTime: false))"))
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text(contact.digits.count == 12 && contact.digits.hasPrefix("998") ? PhoneFormat.uz(contact.digits) : contact.phone)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.green : Color(.systemGray3))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Нижняя панель

    private var actionBar: some View {
        VStack(spacing: 10) {
            Text(String(localized: "Выбрано: \(selection.count)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            HStack(spacing: 10) {
                Button(action: startSMS) {
                    Label("SMS", systemImage: "message.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
                Button(action: startTelegram) {
                    Label("Telegram", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(Self.telegramBlue)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func telegramBar(_ next: PhoneContact) -> some View {
        VStack(spacing: 10) {
            Text(String(localized: "Дальше: \(next.name) · \(telegramTotal - telegramQueue.count + 1) из \(telegramTotal)"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 10) {
                Button {
                    openNextTelegram()
                } label: {
                    Label("Открыть Telegram", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.telegramBlue)
                Button {
                    telegramQueue = []
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Хватит")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private static let telegramBlue = Color(red: 0.16, green: 0.63, blue: 0.89)

    // MARK: - Данные

    private var filtered: [PhoneContact] {
        let text = query.trimmed
        guard !text.isEmpty else { return contacts }
        let digits = text.filter(\.isNumber)
        return contacts.filter {
            $0.name.localizedCaseInsensitiveContains(text) || (!digits.isEmpty && $0.digits.contains(digits))
        }
    }

    /// Люди из переводов и долгов, которые есть в контактах.
    private var known: [PhoneContact] {
        let keys = Set(store.people.flatMap { [Expense.personKey($0), Expense.reversedPersonKey($0)].compactMap { $0 } })
        guard !keys.isEmpty else { return [] }
        return contacts.filter { keys.contains(Expense.personKey($0.name)) || keys.contains(Expense.personKey($0.givenName)) }
    }

    /// Отмеченные — в порядке списка.
    private var selected: [PhoneContact] { contacts.filter { selection.contains($0.id) } }

    private func load() async {
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        access = CNContactStore.authorizationStatus(for: .contacts)
        guard access == .authorized || access == .limited else {
            loading = false
            return
        }
        contacts = await Task.detached(priority: .userInitiated) { (try? PhoneContact.fetchAll()) ?? [] }.value
        loading = false
    }

    private func mark(_ contact: PhoneContact, via channel: InviteLog.Channel) {
        InviteLog.mark(contact.key, via: channel)
        invites = InviteLog.all
        selection.remove(contact.id)
    }

    // MARK: - Отправка

    private func startSMS() {
        guard MFMessageComposeViewController.canSendText() else {
            noSMS = true
            return
        }
        smsQueue = selected
        composing = smsQueue.first
    }

    private func startTelegram() {
        telegramQueue = selected
        telegramTotal = telegramQueue.count
        openNextTelegram()
    }

    /// Чат с человеком по номеру, текст уже вписан — остаётся нажать «Отправить».
    private func openNextTelegram() {
        guard let contact = telegramQueue.first else { return }
        telegramQueue.removeFirst()
        mark(contact, via: .telegram)
        var app = URLComponents(string: "tg://resolve")!
        app.queryItems = [URLQueryItem(name: "phone", value: contact.digits), URLQueryItem(name: "text", value: inviteText)]
        var web = URLComponents(string: "https://t.me/+\(contact.digits)")!
        web.queryItems = [URLQueryItem(name: "text", value: inviteText)]
        guard let appURL = app.url, let webURL = web.url else { return }
        // Telegram не установлен — та же ссылка через t.me.
        UIApplication.shared.open(appURL) { opened in
            if !opened { UIApplication.shared.open(webURL) }
        }
    }
}

/// Контакт с номером телефона.
struct PhoneContact: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let givenName: String
    /// Как записан в контактах.
    let phone: String
    /// Международный номер без «+»: 998901234567.
    let digits: String
    let thumbnail: Data?

    /// Ключ для отметки «приглашён» — номер, а не карточка контакта: карточки бывают дублями.
    var key: String { digits }
    /// Узбекский номер — в международном виде, остальные — как записаны в контактах.
    var smsAddress: String { digits.count == 12 && digits.hasPrefix("998") ? "+" + digits : phone }

    var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    var color: Color {
        let colors: [Color] = [.orange, .pink, .purple, .blue, .teal, .green, .indigo, .red]
        return colors[name.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 997 } % colors.count]
    }

    /// Все контакты с номером; у каждого — один номер, лучше мобильный.
    nonisolated static func fetchAll() throws -> [PhoneContact] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var result: [PhoneContact] = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            let mobileLabels: Set<String> = [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone]
            let numbers = contact.phoneNumbers.sorted { a, _ in mobileLabels.contains(a.label ?? "") }
            guard let number = numbers.first(where: { international($0.value.stringValue) != nil }),
                  let digits = international(number.value.stringValue) else { return }
            let full = CNContactFormatter.string(from: contact, style: .fullName)?.trimmed ?? ""
            let name = full.isEmpty ? contact.organizationName.trimmed : full
            result.append(PhoneContact(id: contact.identifier, name: name.isEmpty ? number.value.stringValue : name,
                                       givenName: contact.givenName, phone: number.value.stringValue,
                                       digits: digits, thumbnail: contact.thumbnailImageData))
        }
        return result
    }

    /// «90 123-45-67», «8 90 123 45 67», «+998 90 123 45 67», «00998…» → «998901234567».
    nonisolated static func international(_ raw: String) -> String? {
        var digits = String(raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII })
        let plus = raw.trimmed.hasPrefix("+")
        if !plus && digits.hasPrefix("00") { digits.removeFirst(2) }
        if !plus && digits.count == 9 { return "998" + digits }
        if !plus && digits.count == 10 && digits.hasPrefix("8") { return "998" + digits.dropFirst() }
        return digits.count >= 9 ? digits : nil
    }
}

/// Кого и когда уже приглашали (по номеру) — чтобы не написать человеку дважды.
enum InviteLog {
    enum Channel: String, Codable { case sms, telegram }

    struct Record: Codable {
        let date: Date
        let via: Channel
    }

    static var all: [String: Record] {
        Account.defaults.data(forKey: "invites").flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    static func mark(_ key: String, via channel: Channel) {
        var records = all
        records[key] = Record(date: .now, via: channel)
        Account.defaults.set(try? JSONEncoder().encode(records), forKey: "invites")
    }
}

/// Окно «Сообщений» с готовым текстом для одного человека.
private struct MessageComposer: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    let onFinish: (_ sent: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = [recipient]
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(result == .sent)
        }
    }
}
