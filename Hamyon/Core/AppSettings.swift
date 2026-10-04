import Foundation
import Security
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    static let defaultModel = "claude-haiku-4-5"
    static let defaultGeminiModel = "gemini-3.5-flash-lite"

    @ObservationIgnored private let defaults = Account.defaults

    var apiKey: String { didSet { Keychain.set(apiKey, for: "anthropic_api_key") } }
    var model: String { didSet { defaults.set(model, forKey: "model") } }
    /// Кто разбирает SMS и делает анализ. По умолчанию Gemini — у него есть бесплатный тариф.
    var provider: AIProvider { didSet { defaults.set(provider.rawValue, forKey: "provider") } }
    var geminiKey: String { didSet { Keychain.set(geminiKey, for: "gemini_api_key") } }
    var geminiModel: String { didSet { defaults.set(geminiModel, forKey: "geminiModel") } }
    var speechLocale: String { didSet { defaults.set(speechLocale, forKey: "speechLocale") } }
    /// Защита входа кодом-паролем приложения.
    var lockEnabled: Bool { didSet { defaults.set(lockEnabled, forKey: "lockEnabled") } }
    /// «Сегодня потрачено» в Dynamic Island и на экране блокировки.
    var liveActivityEnabled: Bool { didSet { defaults.set(liveActivityEnabled, forKey: "liveActivityEnabled") } }
    /// Скрыть остатки на картах («глаз»).
    var hideBalances: Bool { didSet { defaults.set(hideBalances, forKey: "hideBalances") } }
    /// Открывать по Face ID, не вводя код.
    var biometricsEnabled: Bool { didSet { defaults.set(biometricsEnabled, forKey: "biometricsEnabled") } }
    /// Светлая, тёмная или как в iPhone.
    var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: "theme")
            AppTheme.apply(theme)
        }
    }

    private init() {
        // Ключ из настроек приложения важнее; иначе — вшитый при сборке из Config/Secrets.xcconfig.
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "AnthropicAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        apiKey = Keychain.get("anthropic_api_key") ?? (bundled.hasPrefix("sk-ant-") ? bundled : "")
        model = defaults.string(forKey: "model") ?? Self.defaultModel
        let bundledGemini = (Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        geminiKey = Keychain.get("gemini_api_key") ?? (bundledGemini.count > 20 ? bundledGemini : "")
        geminiModel = defaults.string(forKey: "geminiModel") ?? Self.defaultGeminiModel
        provider = AIProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .gemini
        speechLocale = defaults.string(forKey: "speechLocale") ?? Self.systemSpeechLocale
        lockEnabled = defaults.object(forKey: "lockEnabled") as? Bool ?? true
        biometricsEnabled = defaults.object(forKey: "biometricsEnabled") as? Bool ?? true
        hideBalances = defaults.bool(forKey: "hideBalances")
        liveActivityEnabled = defaults.object(forKey: "liveActivityEnabled") as? Bool ?? true
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
    }

    /// В Узбекистане интерфейс телефона часто английский, а говорят по-русски,
    /// поэтому русский выбираем, если он вообще есть среди языков телефона, затем узбекский.
    private static var systemSpeechLocale: String {
        let codes = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        if codes.contains("ru") { return "ru-RU" }
        if codes.contains("uz") { return "uz-UZ" }
        if codes.first == "en" && !Locale.current.identifier.hasSuffix("UZ") { return "en-US" }
        return "ru-RU"
    }

    var aiConfig: AIConfig {
        switch provider {
        case .gemini: AIConfig(provider: .gemini, apiKey: geminiKey, model: geminiModel)
        case .claude: AIConfig(provider: .claude, apiKey: apiKey, model: model)
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Авто"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// На все окна сразу — так меняются и листы, и окна UIKit («Сообщения», выбор фото), и плашка.
    @MainActor
    static func apply(_ theme: AppTheme, animated: Bool = true) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                guard animated else {
                    window.overrideUserInterfaceStyle = theme.style
                    continue
                }
                UIView.transition(with: window, duration: 0.3, options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = theme.style
                }
            }
        }
    }
}

/// Язык приложения: свой, а не как в iPhone. iOS читает его при запуске — после выбора нужен перезапуск.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Как в iPhone")
        case .ru: "Русский"
        case .en: "English"
        }
    }

    /// Свой выбор помним отдельно; если язык потом сменили в «Настройках iPhone → Hamyon», он уже не наш.
    static var current: AppLanguage {
        let defaults = UserDefaults.standard
        guard let saved = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? ""), saved != .system,
              defaults.stringArray(forKey: "AppleLanguages")?.first?.hasPrefix(saved.rawValue) == true else { return .system }
        return saved
    }

    /// `AppleLanguages` приложения — то же место, куда пишет «Настройки → Hamyon → Язык».
    static func set(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: "appLanguage")
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Язык, на котором приложение показано сейчас.
    static var shown: AppLanguage { Bundle.main.preferredLocalizations.first == "en" ? .en : .ru }
}

enum Keychain {
    private static let service = "uz.fayzullo.hamyon"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Доступен после первой разблокировки — нужен действию «Команд», которое работает в фоне.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
