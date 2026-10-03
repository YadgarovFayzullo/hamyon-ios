import SwiftUI

/// Суммы в полях ввода — с пробелами между разрядами, как пишут в Узбекистане: «10 000», «1 250 000».
enum AmountFormat {
    /// «1234567» → «1 234 567»; «35000+12000» → «35 000 + 12 000»; дробная часть сохраняется.
    static func grouped(_ text: String) -> String {
        guard text.contains("+") else { return group(text) }
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map { group(String($0)) }
        var result = parts.filter { !$0.isEmpty }.joined(separator: " + ")
        // Только что поставили «+» — оставляем его, чтобы можно было вписать следующую позицию.
        if text.trimmingCharacters(in: .whitespaces).hasSuffix("+") { result += " +" }
        return result
    }

    private static func group(_ text: String) -> String {
        let clean = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
        guard !clean.isEmpty else { return "" }
        let separator: Character = clean.contains(",") ? "," : "."
        let parts = clean.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, whole.allSatisfy(\.isNumber) else { return text }
        var result = ""
        for (index, char) in whole.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { result.insert(" ", at: result.startIndex) }
            result.insert(char, at: result.startIndex)
        }
        if parts.count > 1 { result += String(separator) + parts[1] }
        return result
    }
}

extension View {
    /// Расставляет пробелы между разрядами прямо при вводе.
    func amountFormatting(_ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue, initial: true) { _, new in
            let formatted = AmountFormat.grouped(new)
            if formatted != new { text.wrappedValue = formatted }
        }
    }
}

extension AmountFormat {
    /// Суммы в ответах ИИ — как в остальном приложении: «190000 UZS» → «190 000 сум».
    /// Годы, время, даты, номера карт и телефонов не трогает; пробелы неразрывные — сумма не рвётся на две строки.
    static func prettify(_ text: String) -> String {
        var result = text
        let ns = text as NSString
        for match in numberPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let digits = ns.substring(with: match.range)
            let before = ns.substring(to: match.range.location)
            let after = ns.substring(from: match.range.upperBound)
            let hasCurrency = after.range(of: #"^[ \u00A0]?(UZS|сум|сўм|so['ʻ’]?m|sum)"#, options: [.regularExpression, .caseInsensitive]) != nil
            // 2025 — год; «8600 1234 …» — номер карты.
            if digits.count == 4, let year = Int(digits), (1900...2100).contains(year), !hasCurrency { continue }
            if after.range(of: #"^ \d{4}"#, options: .regularExpression) != nil
                || before.range(of: #"\d{4} $"#, options: .regularExpression) != nil { continue }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: group(digits).replacingOccurrences(of: " ", with: "\u{00A0}"))
        }
        return currencyPattern.stringByReplacingMatches(
            in: result, range: NSRange(location: 0, length: (result as NSString).length),
            withTemplate: "$1\u{00A0}" + NSRegularExpression.escapedTemplate(for: String(localized: "сум")))
    }

    /// Число от 4 цифр, не часть даты, времени, номера карты (•2135) или телефона (+998…).
    private static let numberPattern = try! NSRegularExpression(pattern: #"(?<![\d.,:/•*#+\-])\d{4,}(?![\d:/]|[.,]\d|-\d)"#)
    private static let currencyPattern = try! NSRegularExpression(
        pattern: #"(\d)[ \u00A0]?(?:UZS|сум|сўм|so['ʻ’]?m)(?!\p{L})"#, options: .caseInsensitive)
}
