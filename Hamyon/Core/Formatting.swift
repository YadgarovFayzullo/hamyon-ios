import Foundation
import SwiftUI

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Узбекский номер как его пишут: «+998 90 123 45 67».
enum PhoneFormat {
    /// «901234567», «998901234567», «+998 (90) 123-45-67» → «+998 90 123 45 67»; по мере ввода — «+998 90 12».
    /// Номер с кодом другой страны («+7 916…») остаётся как ввели. `deleting` — стёрли последнюю цифру:
    /// тогда пустое поле, а не снова «+998 ».
    static func uz(_ text: String, deleting: Bool = false) -> String {
        var digits = text.filter { $0.isASCII && $0.isNumber }
        let plus = text.trimmed.hasPrefix("+")
        if digits.hasPrefix("998") {
            digits.removeFirst(3)
        } else if plus {
            return text
        }
        guard !digits.isEmpty else { return deleting || !plus ? "" : "+998 " }
        let local = Array(digits.prefix(9))
        var result = "+998 "
        for (index, digit) in local.enumerated() {
            if index == 2 || index == 5 || index == 7 { result.append(" ") }
            result.append(digit)
        }
        return result
    }

    /// Номер введён полностью (или это номер другой страны) — иначе в профиле не сохраняем.
    static func hasNumber(_ text: String) -> Bool {
        text.filter { $0.isASCII && $0.isNumber }.count > 3
    }
}

/// Даты на языке интерфейса: «Сегодня, 14:00», «Вчера», «01.10.2026».
enum DueFormat {
    /// Язык интерфейса, который выбрала iOS (ru или en), а не регион — чтобы даты совпадали с текстом.
    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "ru")

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let shortDate = formatter("ddMMyyyy")
    private static let time = formatter("HHmm")
    private static let longDay = formatter("EEEEdMMMM")

    static func string(_ date: Date, hasTime: Bool) -> String {
        let day = relativeDay(date) ?? shortDate.string(from: date)
        return hasTime ? "\(day), \(time.string(from: date))" : day
    }

    static func day(_ date: Date) -> String {
        relativeDay(date) ?? longDay.string(from: date).capitalizedFirst
    }

    static func timeString(_ date: Date) -> String { time.string(from: date) }

    private static func relativeDay(_ date: Date) -> String? {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Сегодня") }
        if cal.isDateInYesterday(date) { return String(localized: "Вчера") }
        return nil
    }
}
