import ActivityKit
import Foundation

/// Live Activity «Сегодня потрачено» — в Dynamic Island и на экране блокировки.
struct SpendingAttributes: ActivityAttributes {
    /// День, за который считаем; на следующий день активность начинается заново.
    var day: Date

    struct ContentState: Codable, Hashable {
        var spentToday: Double
        var lastTitle: String?
        var lastAmount: Double?
        var lastIsIncome = false
    }
}

/// Суммы для «острова»: короткая «125K» и полная «125 000 сум».
enum ActivityMoney {
    static func full(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: amount)) ?? "\(Int(amount))") + " " + String(localized: "сум")
    }

    static func short(_ amount: Double) -> String {
        switch amount {
        case 1_000_000...: return String(format: "%.1fM", amount / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        case 1_000...: return "\(Int(amount / 1_000))K"
        default: return "\(Int(amount))"
        }
    }
}
