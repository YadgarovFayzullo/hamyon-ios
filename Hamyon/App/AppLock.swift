import CryptoKit
import LocalAuthentication
import SwiftUI

/// Защита входа: свой код из 4 цифр (хранится как хеш в Связке ключей) и Face ID.
@MainActor
@Observable
final class AppLock {
    enum State: Equatable { case setup, locked, unlocked }

    static let codeLength = 4
    private static let maxAttempts = 5

    private(set) var state: State
    /// До какого момента ввод кода заблокирован после пяти ошибок.
    private(set) var lockedOutUntil: Date?
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private var authenticating = false

    init() {
        let settings = AppSettings.shared
        if !settings.lockEnabled {
            state = .unlocked
        } else {
            state = Self.hasCode ? .locked : .setup
        }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-setCode"), i + 1 < args.count {
            let salt = UUID().uuidString
            Keychain.set(salt, for: "app_code_salt")
            Keychain.set(Self.hash(args[i + 1], salt: salt), for: "app_code_hash")
            AppSettings.shared.lockEnabled = true
            state = .locked
        }
        if args.contains("-previewLock") { state = .locked }
        if args.contains("-unlocked") { state = .unlocked; AppSettings.shared.lockEnabled = false }
        #endif
    }

    var isLocked: Bool { state != .unlocked }

    // MARK: - Код

    static var hasCode: Bool { Keychain.get("app_code_hash") != nil }

    private static func hash(_ code: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + code).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func setCode(_ code: String) {
        let salt = UUID().uuidString
        Keychain.set(salt, for: "app_code_salt")
        Keychain.set(Self.hash(code, salt: salt), for: "app_code_hash")
        AppSettings.shared.lockEnabled = true
        failedAttempts = 0
        withAnimation(.easeOut(duration: 0.3)) { state = .unlocked }
    }

    /// true — код верный и приложение открыто.
    func enter(_ code: String) -> Bool {
        if let until = lockedOutUntil, until > .now { return false }
        guard let salt = Keychain.get("app_code_salt"),
              Self.hash(code, salt: salt) == Keychain.get("app_code_hash") else {
            failedAttempts += 1
            if failedAttempts >= Self.maxAttempts {
                failedAttempts = 0
                lockedOutUntil = .now.addingTimeInterval(30)
            }
            return false
        }
        failedAttempts = 0
        lockedOutUntil = nil
        return true
    }

    func open() {
        withAnimation(.easeOut(duration: 0.3)) { state = .unlocked }
    }

    func lock() {
        guard AppSettings.shared.lockEnabled else { return }
        state = Self.hasCode ? .locked : .setup
    }

    func disable() {
        Keychain.set("", for: "app_code_hash")
        Keychain.set("", for: "app_code_salt")
        AppSettings.shared.lockEnabled = false
        state = .unlocked
    }

    // MARK: - Face ID

    static var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    var canUseBiometrics: Bool {
        AppSettings.shared.biometricsEnabled && Self.biometryType != .none
    }

    /// Face ID. Если не узнал — остаётся ввод кода.
    func unlockWithBiometrics() async -> Bool {
        guard state == .locked, canUseBiometrics, !authenticating else { return false }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Ввести код")
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                     localizedReason: String(localized: "Откройте ваши финансы"))) ?? false
        return ok
    }

    /// «Забыли код?» — подтверждаем владельца кодом самого iPhone и задаём новый код.
    func resetWithDevicePasscode() async {
        let context = LAContext()
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                     localizedReason: String(localized: "Подтвердите, что это вы, чтобы задать новый код"))) ?? false
        if ok { withAnimation { state = .setup } }
    }
}
