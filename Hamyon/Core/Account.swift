import Foundation

/// Аккаунты в одном приложении: основной (ваши данные) и демо (для съёмки рекламы).
/// У каждого — своё хранилище операций, свои настройки и свои карты в связке ключей.
/// Основной пользуется теми же файлами, что и до появления аккаунтов, — его данные никуда не переезжают.
/// Переключение — с перезапуском: приложение читает настройки и открывает хранилище один раз, при запуске.
enum Account: String, CaseIterable, Identifiable {
    case main, demo

    var id: String { rawValue }

    /// Выбор аккаунта хранится в общих настройках приложения, а не в настройках аккаунта.
    static let current = Account(rawValue: UserDefaults.standard.string(forKey: "activeAccount") ?? "") ?? .main

    static func switchTo(_ account: Account) {
        UserDefaults.standard.set(account.rawValue, forKey: "activeAccount")
    }

    /// Настройки текущего аккаунта. У основного — `.standard`, как было всегда.
    static let defaults: UserDefaults = current == .main ? .standard : UserDefaults(suiteName: "uz.fayzullo.hamyon.account.demo")!

    /// Ключ в связке ключей или имя файла: у основного — как было, у демо — с приставкой.
    static func scoped(_ name: String) -> String { current == .main ? name : "demo.\(name)" }

    /// Хранилище операций демо — отдельный файл. У основного — хранилище SwiftData по умолчанию, как было.
    static var demoStoreURL: URL { URL.applicationSupportDirectory.appending(path: "demo.store") }

    /// Имя основного аккаунта — для переключателя, даже когда открыт демо.
    static var mainName: String {
        UserDefaults.standard.string(forKey: "profileName")?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Настоящие SMS, пришедшие, пока открыт демо: в демо-данные они не попадают, а ждут основного аккаунта.
    static var pendingSMS: [String] {
        get { UserDefaults.standard.stringArray(forKey: "pendingSMS") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "pendingSMS") }
    }
}
