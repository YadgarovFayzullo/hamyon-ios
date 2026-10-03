import Foundation
import SwiftData
import SwiftUI

/// Одна операция: расход или поступление. Хранится только на телефоне (SwiftData).
@Model
final class Expense {
    var id: UUID = UUID()
    var amount: Double = 0
    var currency: String = "UZS"
    var title: String = ""
    var categoryRaw: String = ExpenseCategory.other.rawValue
    var date: Date = Date.now
    var note: String = ""
    var isIncome: Bool = false
    var sourceRaw: String = ExpenseSource.manual.rawValue
    /// Исходный текст SMS — по нему отсекаем повторы.
    var rawText: String?
    var createdAt: Date = Date.now
    /// Бренд для логотипа («Payme», «Korzinka»); "" — бренда нет, nil — ещё не определяли.
    var brand: String?
    /// Последние 4 цифры вашей карты из SMS.
    var card: String?
    /// Тип операции (`ExpenseKind`); nil — старая запись, тип ещё не определяли.
    var kindRaw: String?
    /// Получатель или отправитель, если он есть в SMS («OSMON»).
    var counterparty: String?
    /// Через что прошёл перевод: Payme, Tez, Zoomrad, SQB Mobile…
    var channel: String?
    /// Перевод между своими картами — не расход и не доход.
    var isInternal: Bool = false
    /// Комиссия за перевод между своими картами (списали больше, чем пришло).
    var fee: Double = 0
    /// Остаток на карте после операции — из SMS («Qoldiq: 363530.00 UZS»).
    var balance: Double?
    /// Пользователь уже ответил, кому перевод (или пропустил вопрос).
    var reviewed: Bool = false
    /// «Себе на другой счёт» — отмечено вручную, а не найдено парой SMS.
    var manualInternal: Bool = false
    /// Последние 4 цифры карты другой стороны (получателя или отправителя) — есть в выписках, в SMS обычно нет.
    var counterpartCard: String?

    init(draft: ExpenseDraft, source: ExpenseSource, rawText: String?) {
        id = UUID()
        createdAt = .now
        self.sourceRaw = source.rawValue
        self.rawText = rawText
        apply(draft)
    }

    var category: ExpenseCategory { ExpenseCategory(rawValue: categoryRaw) ?? .other }
    var kind: ExpenseKind? { kindRaw.flatMap(ExpenseKind.init(rawValue:)) }
    var isTransfer: Bool { kind == .transferOut || kind == .transferIn }
    var source: ExpenseSource { ExpenseSource(rawValue: sourceRaw) ?? .manual }
    var isCash: Bool { card == ExpenseStore.cashCard }

    /// Кому перевели или от кого пришло — имя, которое знает пользователь.
    var person: String? {
        let name = counterparty?.trimmed ?? ""
        return name.isEmpty ? nil : name
    }

    /// «Rabbimov B», «Rabbimov B.» и «Rabbimov Bashirjon» — один человек: фамилия + первая буква имени.
    static func personKey(_ name: String) -> String {
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return name.lowercased() }
        guard words.count > 1, let initial = words[1].first else { return first }
        return "\(first) \(initial)"
    }

    /// Тот же ключ, но с именем и фамилией в обратном порядке («Fayzullo Yadgarov» ↔ «Yadgarov Fayzullo»).
    static func reversedPersonKey(_ name: String) -> String? {
        let words = name.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard words.count > 1, let initial = words[0].first else { return nil }
        return "\(words[1]) \(initial)"
    }

    /// Имя без учёта порядка слов и регистра — для правила «это я».
    static func normalizedName(_ name: String) -> String {
        name.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.sorted().joined(separator: " ")
    }

    /// Название похоже на имя человека, а не на сервис («Перевод на карту», «Payme P2P»).
    static func looksLikeName(_ title: String) -> Bool {
        let text = title.lowercased()
        let generic = ["p2p", "payme", "click", "tez", "zoomrad", "uzum", "paynet", "перевод", "transfer", "o'tkazma",
                       "otkazma", "kartaga", "kartadan", "popolnenie", "perevod", "пополнение", "card", "карт", "bank",
                       "банк", "humo", "uzcard", "visa", "mastercard", "atm", "oplata", "оплата", "to'lov", "tolov", "mchj",
                       "ooo", "ооо", "llc", "xk", "yatt", "чп", "ип"]
        guard !generic.contains(where: text.contains), text.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let words = text.split(separator: " ").filter { !$0.isEmpty }
        return (1...4).contains(words.count) && text.rangeOfCharacter(from: .letters) != nil
    }

    /// Перевод без имени, о котором стоит спросить «Кому?».
    var needsReview: Bool {
        isTransfer && !isInternal && !reviewed && person == nil && currency == "UZS"
    }

    func apply(_ draft: ExpenseDraft) {
        amount = draft.amount
        currency = draft.currency
        title = draft.title.trimmed
        categoryRaw = draft.category.rawValue
        date = draft.date
        note = draft.note.trimmed
        isIncome = draft.isIncome
        if let brand = draft.brand { self.brand = brand }
        if let kind = draft.kind { kindRaw = kind.rawValue }
        if let card = draft.card { self.card = card }
        if let counterparty = draft.counterparty { self.counterparty = counterparty }
        if let channel = draft.channel { self.channel = channel }
        if let balance = draft.balance { self.balance = balance }
        if let counterpartCard = draft.counterpartCard { self.counterpartCard = counterpartCard }
        if draft.internalTransfer {
            isInternal = true
            manualInternal = true
            reviewed = true
        }
    }

    var draft: ExpenseDraft {
        ExpenseDraft(title: title, amount: amount, currency: currency, category: category,
                     isIncome: isIncome, date: date, note: note, brand: brand, kind: kind, card: card,
                     counterparty: counterparty, channel: channel, counterpartCard: counterpartCard,
                     internalTransfer: manualInternal)
    }
}

enum ExpenseSource: String {
    case manual, voice, sms, statement
}

/// Редактируемая копия операции — её заполняют форма и разбор ИИ.
struct ExpenseDraft: Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var amount: Double = 0
    var currency = "UZS"
    var category: ExpenseCategory = .other
    var isIncome = false
    var date = Date.now
    var note = ""
    var brand: String?
    var kind: ExpenseKind?
    var card: String?
    var counterparty: String?
    var channel: String?
    var balance: Double?
    /// Последние 4 цифры карты другой стороны, если видны в выписке.
    var counterpartCard: String?
    /// Перевод между своими картами (так написано в выписке или так решил пользователь).
    var internalTransfer = false
    /// В выписке у строки не нашлось даты — стоит «сейчас», сверять с имеющимися по сумме, а не по времени.
    var dateUnknown = false
}

enum ExpenseKind: String, CaseIterable {
    case purchase, payment, transferOut = "transfer_out", transferIn = "transfer_in", income, refund, cash

    var title: String {
        switch self {
        case .purchase: String(localized: "Покупка")
        case .payment: String(localized: "Оплата")
        case .transferOut: String(localized: "Перевод")
        case .transferIn: String(localized: "Поступление")
        case .income: String(localized: "Доход")
        case .refund: String(localized: "Возврат")
        case .cash: String(localized: "Снятие наличных")
        }
    }

    var isIncoming: Bool { self == .transferIn || self == .income || self == .refund }

    /// Подсказка для ИИ.
    static let hint = """
    - purchase: paid in a shop or terminal (Xarid, Pokupka, Purchase)
    - payment: paid a service or bill online, incl. Payme/Click payments for utilities, phone, internet (To'lov/Online to'lov … OPLATA, MUNIS, KOMMUNAL)
    - transfer_out: money sent from this card to another card — P2P (Kartadan chiqim, … P2P, P2P CHIQIM, UZCARD NA MC, BOSHQA BANK)
    - transfer_in: money arrived on this card from another card (Kartaga o'tkazma, Kirim … P2P, Popolnenie, Zachislenie)
    - income: salary or payment from an employer/organization (Kirim from a company or bank payroll)
    - refund: refund or cashback
    - cash: ATM cash withdrawal
    """
}

enum ExpenseCategory: String, CaseIterable, Identifiable {
    case groceries, cafe, transport, shopping, home, connection, health, beauty, loans, entertainment,
         subscriptions, education, travel, gifts, transfers, fees, other, income

    var id: String { rawValue }

    static var expenseCases: [ExpenseCategory] { allCases.filter { $0 != .income } }

    var title: String {
        switch self {
        case .groceries: String(localized: "Продукты")
        case .cafe: String(localized: "Кафе и доставка")
        case .transport: String(localized: "Транспорт")
        case .shopping: String(localized: "Покупки")
        case .home: String(localized: "Дом и коммуналка")
        case .connection: String(localized: "Связь и интернет")
        case .health: String(localized: "Здоровье")
        case .beauty: String(localized: "Красота и уход")
        case .loans: String(localized: "Кредиты и рассрочка")
        case .entertainment: String(localized: "Развлечения")
        case .subscriptions: String(localized: "Подписки")
        case .education: String(localized: "Образование")
        case .travel: String(localized: "Путешествия")
        case .gifts: String(localized: "Подарки")
        case .transfers: String(localized: "Переводы")
        case .fees: String(localized: "Комиссии")
        case .other: String(localized: "Другое")
        case .income: String(localized: "Доход")
        }
    }

    var symbol: String {
        switch self {
        case .groceries: "cart.fill"
        case .cafe: "fork.knife"
        case .transport: "car.fill"
        case .shopping: "bag.fill"
        case .home: "house.fill"
        case .connection: "wifi"
        case .health: "pills.fill"
        case .beauty: "scissors"
        case .loans: "building.columns.fill"
        case .entertainment: "gamecontroller.fill"
        case .subscriptions: "repeat"
        case .education: "graduationcap.fill"
        case .travel: "airplane"
        case .gifts: "gift.fill"
        case .transfers: "arrow.left.arrow.right"
        case .fees: "percent"
        case .other: "ellipsis"
        case .income: "arrow.down"
        }
    }

    var color: Color {
        switch self {
        case .groceries: .green
        case .cafe: .orange
        case .transport: .yellow
        case .shopping: .pink
        case .home: .brown
        case .connection: .cyan
        case .health: .red
        case .beauty: .mint
        case .loans: Color(red: 0.85, green: 0.45, blue: 0.20)
        case .entertainment: .purple
        case .subscriptions: .indigo
        case .education: .blue
        case .travel: .teal
        case .gifts: Color(red: 0.85, green: 0.35, blue: 0.55)
        case .transfers: Color(red: 0.35, green: 0.45, blue: 0.95)
        case .fees: Color(.systemGray)
        case .other: Color(.systemGray2)
        case .income: .green
        }
    }

    /// Подсказка для ИИ — что относится к категории.
    var hint: String {
        switch self {
        case .groceries: "supermarkets, bazaar, Korzinka, Makro, Havas"
        case .cafe: "restaurants, cafes, coffee, food delivery (Wolt, Yandex Eda, Express24)"
        case .transport: "taxi (Yandex Go, MyTaxi), metro, bus, fuel, parking, car service"
        case .shopping: "clothes, electronics, marketplaces (Uzum Market), household goods"
        case .home: "rent, utilities (electricity, gas, water), repairs, furniture"
        case .connection: "mobile (Beeline, Ucell, Uzmobile, Mobiuz), home internet"
        case .health: "pharmacy, clinic, doctor, sport club"
        case .beauty: "barbershop, hair and beauty salon, manicure, cosmetics, spa"
        case .loans: "loan and installment repayments: bank credit, Uzum Nasiya, Alif nasiya, Payme loan (Payme Kredit/Nasiya)"
        case .entertainment: "cinema, games, events, hobbies"
        case .subscriptions: "recurring services: streaming, apps, cloud, Telegram Premium, YouTube"
        case .education: "courses, books, school, university"
        case .travel: "flights, hotels, trips"
        case .gifts: "gifts, charity"
        case .transfers: "card-to-card transfers (P2P), sent or received"
        case .fees: "bank and transfer fees, commissions"
        case .other: "anything else"
        case .income: "salary, incoming transfers, refunds, cashback"
        }
    }
}

/// «45 000 сум», «$12.50».
enum Money {
    /// `unit: false` — только число со знаком («+40 000»), когда валюта и так видна рядом.
    static func string(_ amount: Double, currency: String = "UZS", sign: Bool = false, unit: Bool = true) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = DueFormat.locale
        f.groupingSeparator = " "
        f.usesGroupingSeparator = true
        let fraction = currency == "UZS" || amount.rounded() == amount ? 0 : 2
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        let number = f.string(from: NSNumber(value: abs(amount))) ?? "\(abs(amount))"
        let prefix = sign ? (amount < 0 ? "−" : "+") : (amount < 0 ? "−" : "")
        guard unit else { return prefix + number }
        switch currency {
        case "UZS": return prefix + number + " " + String(localized: "сум")
        case "USD": return prefix + "$" + number
        case "EUR": return prefix + "€" + number
        case "RUB": return prefix + number + " ₽"
        default: return prefix + number + " " + currency
        }
    }

    /// Короткая запись для плиток: «2,4 млн», «850 тыс.».
    static func short(_ amount: Double) -> String {
        let value = abs(amount)
        if value >= 1_000_000 {
            return String(localized: "\((value / 1_000_000).formatted(.number.precision(.fractionLength(0...1)).locale(DueFormat.locale))) млн")
        }
        if value >= 10_000 {
            return String(localized: "\(Int(value / 1000)) тыс.")
        }
        return string(value)
    }
}
