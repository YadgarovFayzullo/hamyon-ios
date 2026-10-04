import Foundation

/// Демо-аккаунт для съёмки рекламы на iPhone: демо-данные, «Прислать SMS», сброс для нового дубля.
enum DemoMode {
    static var isOn: Bool { Account.current == .demo }

    /// Магазины для «Прислать SMS» по кругу: каждый дубль — с новой операцией (одинаковая SMS — повтор).
    private static let samples: [(merchant: String, amount: Int)] = [
        ("EVOS", 64_000), ("KORZINKA", 86_500), ("YANDEX GO", 23_000), ("MAKRO", 145_000),
    ]

    /// SMS банка 5800 (формат Aloqabank) с текущими датой и временем.
    static func nextSMS() -> String {
        let defaults = Account.defaults
        let index = defaults.integer(forKey: "demoSMSIndex")
        defaults.set(index + 1, forKey: "demoSMSIndex")
        let sample = samples[index % samples.count]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yy HH:mm"
        func grouped(_ value: Int) -> String {
            var digits = String(value), result = ""
            while digits.count > 3 {
                result = " " + digits.suffix(3) + result
                digits.removeLast(3)
            }
            return digits + result
        }
        return "Xarid: \(sample.merchant), UZ,\(formatter.string(from: .now)),karta ***4503. "
            + "Miqdor:\(grouped(sample.amount)).00 UZS Qoldiq:\(grouped(2_000_000 - sample.amount)).00 UZS"
    }

    /// «Прислать SMS через 10 с»: SMS разбирается сразу — тем же путём, что у автоматизации «Команд», —
    /// а уведомление приходит через `delay`: успеваете выйти на главный экран.
    @MainActor
    static func sendSMS(delay: TimeInterval = 10) async {
        await Notifier.requestPermission()
        Notifier.demoNotifyAt = .now.addingTimeInterval(delay)
        _ = try? await SMSIntake.handle(nextSMS())
        Notifier.demoNotifyAt = nil
    }

    /// Первый запуск демо: имя в профиле и вход без кода-пароля — для съёмки.
    @MainActor
    static func firstLaunchSetup() {
        if Profile.shared.name.isEmpty { Profile.shared.name = "Азиз Каримов" }
        AppSettings.shared.lockEnabled = false
    }
}
