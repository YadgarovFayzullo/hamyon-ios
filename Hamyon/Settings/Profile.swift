import SwiftUI
import UIKit

/// Ваш профиль: как подписывать вас друзьям и куда вам переводить. Хранится только на этом телефоне.
@MainActor
@Observable
final class Profile {
    static let shared = Profile()

    @ObservationIgnored private let defaults = Account.defaults

    var name: String { didSet { defaults.set(name, forKey: "profileName") } }
    var phone: String { didSet { defaults.set(phone, forKey: "profilePhone") } }
    private(set) var photo: UIImage?
    /// Карты для переводов вам. Полный номер — в связке ключей, а не в UserDefaults.
    var payoutCards: [PayoutCard] {
        didSet { Keychain.set((try? JSONEncoder().encode(payoutCards)).flatMap { String(data: $0, encoding: .utf8) } ?? "",
                              for: Account.scoped("payout_cards")) }
    }

    private init() {
        name = defaults.string(forKey: "profileName") ?? ""
        phone = defaults.string(forKey: "profilePhone") ?? ""
        payoutCards = Keychain.get(Account.scoped("payout_cards")).flatMap { try? JSONDecoder().decode([PayoutCard].self, from: Data($0.utf8)) } ?? []
        photo = (try? Data(contentsOf: Self.photoURL)).flatMap(UIImage.init(data:))
    }

    private static var photoURL: URL { URL.applicationSupportDirectory.appending(path: Account.scoped("profile-photo.jpg")) }

    /// Фото уменьшаем до 600 pt — для круга в профиле больше не нужно.
    func setPhoto(_ image: UIImage?) {
        guard let image else {
            photo = nil
            try? FileManager.default.removeItem(at: Self.photoURL)
            return
        }
        let side: CGFloat = 600
        let scale = min(1, side / min(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        photo = resized
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? resized.jpegData(compressionQuality: 0.85)?.write(to: Self.photoURL, options: .completeFileProtection)
    }

    /// Имя для приветствия и сообщений друзьям: из профиля, иначе — как банк пишет вас в выписках.
    var displayName: String {
        if !name.trimmed.isEmpty { return name.trimmed }
        return suggestedName ?? ""
    }

    /// «YADGAROV FAYZULLO» из выписок → «Fayzullo Yadgarov»: банк пишет фамилию первой.
    var suggestedName: String? {
        let names = ExpenseStore.shared.ownCounterpartNames
        guard let words = names.map({ $0.split(separator: " ") }).max(by: { $0.count < $1.count }), !words.isEmpty else { return nil }
        return words.map { $0.capitalized }.joined(separator: " ")
    }

    var initials: String {
        let letters = displayName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "" : String(letters).uppercased()
    }

    /// Строка для друзей: «Uzcard 8600 1234 5678 9012 · Kapitalbank · FAYZULLO YADGAROV».
    var payoutText: String? {
        guard !payoutCards.isEmpty else { return nil }
        return payoutCards.map(\.shareLine).joined(separator: "\n")
    }
}

/// Карта, на которую вам переводят: полный номер, держатель, банк.
struct PayoutCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var number = ""
    var holder = ""
    var bank: String?

    var network: CardNetwork? { CardNetwork(cardNumber: number) }
    var last4: String { String(number.suffix(4)) }

    /// «8600 1234 5678 9012».
    var formatted: String { Self.group(number) }

    var shareLine: String {
        [network.map { "\($0.title) \(formatted)" } ?? formatted,
         Bank.find(bank)?.name,
         holder.trimmed.isEmpty ? nil : holder.trimmed.uppercased()]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func group(_ digits: String) -> String {
        stride(from: 0, to: digits.count, by: 4).map { start in
            let from = digits.index(digits.startIndex, offsetBy: start)
            return String(digits[from..<(digits.index(from, offsetBy: 4, limitedBy: digits.endIndex) ?? digits.endIndex)])
        }.joined(separator: " ")
    }

    /// Контрольная цифра (алгоритм Луна) — ловит опечатку в одной цифре.
    static func luhnValid(_ digits: String) -> Bool {
        let values = digits.reversed().compactMap(\.wholeNumberValue)
        guard values.count == digits.count, values.count >= 12 else { return false }
        let sum = values.enumerated().reduce(0) { sum, item in
            guard item.offset % 2 == 1 else { return sum + item.element }
            let doubled = item.element * 2
            return sum + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }
}

extension ExpenseStore {
    /// Как подписать вас в сообщении друзьям.
    var myName: String {
        Profile.shared.displayName.split(separator: " ").first.map(String.init) ?? String(localized: "Я")
    }
}

/// «Написать в поддержку»: чат в Telegram, в тексте — версия приложения и модель iPhone.
enum Support {
    /// Ник в Telegram без «@». Пусто — кнопки в профиле нет.
    static let telegram = ""

    static var isAvailable: Bool { !telegram.isEmpty }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        return "Hamyon \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    @MainActor
    static func open() {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let text = "\n\n— \(versionLine), iOS \(UIDevice.current.systemVersion), \(model)"
        var app = URLComponents(string: "tg://resolve")!
        app.queryItems = [URLQueryItem(name: "domain", value: telegram), URLQueryItem(name: "text", value: text)]
        var web = URLComponents(string: "https://t.me/\(telegram)")!
        web.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let appURL = app.url, let webURL = web.url else { return }
        UIApplication.shared.open(appURL) { opened in
            if !opened { UIApplication.shared.open(webURL) }
        }
    }
}
