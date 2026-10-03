import Foundation

/// Превращает продиктованную фразу («обед 45 тысяч, такси 18») или SMS банка в операции.
enum ExpenseParser {
    private static let toolName = "record_transactions"

    /// Карта пользователя для подсказки ИИ: «•9138 Kapitalbank Visa «Путешествия»».
    struct CardOption {
        let digits: String
        let label: String
    }

    static func parse(_ text: String, config: AIConfig, cards: [CardOption] = [], now: Date = .now) async throws -> [ExpenseDraft] {
        guard !config.apiKey.trimmed.isEmpty else { return LocalExpenseParser.parse(text, now: now) }

        let object = try await AIClient.object(
            system: systemPrompt(now: now) + cardsHint(cards), text: text, schema: { schema(upper: $0, cards: cards) },
            toolName: toolName, toolDescription: "Записать денежные операции из текста.",
            config: config
        )
        let items = object["transactions"] as? [[String: Any]] ?? []
        let card = cardDigits(in: text)
        let balance = balance(in: text)
        return items.compactMap { item in
            var draft = draft(from: item, now: now)
            if draft?.card == nil { draft?.card = card }
            // Остаток относится к операции из этой SMS; если операций несколько — только к последней.
            if items.count == 1 { draft?.balance = balance }
            return draft
        }
    }

    /// «Qoldiq:1381230.00 UZS», «Balans: 2 345 000,00», «Dostupno: 1234567.00» → остаток после операции.
    static func balance(in text: String) -> Double? {
        let pattern = #"(?i)(qoldiq|balans|balance|dostupno|ostatok|остаток|баланс|доступно)\s*:?\s*(-?\d[\d\s]*(?:[.,]\d{1,2})?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 2), in: text) else { return nil }
        var number = text[range].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
        number = number.replacingOccurrences(of: ",", with: ".")
        return Double(number)
    }

    /// «karta ***4503», «*4521», «HUMOCARD *4521» → «4503».
    static func cardDigits(in text: String) -> String? {
        guard let range = text.range(of: #"\*+\s?(\d{4})\b"#, options: .regularExpression) else { return nil }
        return String(text[range].filter(\.isNumber).suffix(4))
    }

    /// Для старых SMS без типа операции: один запрос на пачку сообщений.
    struct Details {
        let kind: ExpenseKind
        let counterparty: String
        let channel: String
        let category: ExpenseCategory
    }

    static func details(for sms: [String], config: AIConfig) async throws -> [Int: Details] {
        let numbered = sms.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let object = try await AIClient.object(
            system: """
            Classify bank SMS from Uzbekistan. For every numbered SMS return its index, kind, counterparty, \
            channel and category.
            kind:
            \(ExpenseKind.hint)
            counterparty: the person or company on the other side if the SMS names one ("UZCARD NA MC OSMON" → "Osmon", \
            "MCHJ SIROJBOY" → "Sirojboy"), else empty.
            channel: the app or service that carried a transfer or payment (Payme, Click, Tez, Zoomrad, SQB Mobile, \
            Uzum, Paynet), else empty.
            category — one of: \(ExpenseCategory.allCases.map(\.rawValue).joined(separator: ", ")). \
            Transfers between cards are "transfers"; MUNIS and KOMMUNAL are "home".
            """,
            text: numbered,
            schema: { upper in
                func t(_ type: String) -> String { upper ? type.uppercased() : type }
                return [
                    "type": t("object"),
                    "properties": [
                        "items": [
                            "type": t("array"),
                            "items": [
                                "type": t("object"),
                                "properties": [
                                    "index": ["type": t("integer")],
                                    "kind": ["type": t("string"), "enum": ExpenseKind.allCases.map(\.rawValue)],
                                    "counterparty": ["type": t("string")],
                                    "channel": ["type": t("string")],
                                    "category": ["type": t("string"), "enum": ExpenseCategory.allCases.map(\.rawValue)],
                                ],
                                "required": ["index", "kind", "category"],
                            ],
                        ],
                    ],
                    "required": ["items"],
                ]
            },
            toolName: "classify_sms", toolDescription: "Определить тип операций в SMS.",
            config: config, maxTokens: 4096, timeout: 60
        )
        var result: [Int: Details] = [:]
        for item in object["items"] as? [[String: Any]] ?? [] {
            guard let index = (item["index"] as? NSNumber)?.intValue,
                  let kind = ExpenseKind(rawValue: item["kind"] as? String ?? "") else { continue }
            result[index] = Details(
                kind: kind,
                counterparty: (item["counterparty"] as? String)?.trimmed ?? "",
                channel: (item["channel"] as? String)?.trimmed ?? "",
                category: ExpenseCategory(rawValue: item["category"] as? String ?? "") ?? .other
            )
        }
        return result
    }

    /// Бренды для уже сохранённых операций: «PAYME P2P» → «Payme», «Akmal R.» → "".
    static func brands(for titles: [String], config: AIConfig) async throws -> [String: String] {
        let object = try await AIClient.object(
            system: """
            For each payment title from a bank statement in Uzbekistan, name the company or app that was PAID \
            (not the app the user paid with: a taxi ride paid through Payme is "WB Taxi", not "Payme") \
            as it is called in the App Store, so its logo can be shown: "PAYME P2P" → "Payme", \
            "ZOOMRAD P2P UZ2UZ" → "Zoomrad", "KORZINKA SERGELI" → "Korzinka", "YANDEX.GO" → "Yandex Go", \
            "TEZ P2P" → "Tez", "OOO WB TAXI OPLATA" → "WB Taxi", "OOO ATTO TOLOV" → "ATTO", "HUMANS" → "HUMANS.uz". \
            Use an empty brand for people, cash, generic words and unknown shops. \
            Return every title exactly as given.
            """,
            text: titles.joined(separator: "\n"),
            schema: { upper in
                func t(_ type: String) -> String { upper ? type.uppercased() : type }
                return [
                    "type": t("object"),
                    "properties": [
                        "items": [
                            "type": t("array"),
                            "items": [
                                "type": t("object"),
                                "properties": ["title": ["type": t("string")], "brand": ["type": t("string")]],
                                "required": ["title", "brand"],
                            ],
                        ],
                    ],
                    "required": ["items"],
                ]
            },
            toolName: "merchant_brands", toolDescription: "Вернуть бренды для названий платежей.",
            config: config, maxTokens: 2048
        )
        var result: [String: String] = [:]
        for item in object["items"] as? [[String: Any]] ?? [] {
            if let title = item["title"] as? String { result[title] = (item["brand"] as? String)?.trimmed ?? "" }
        }
        return result
    }

    private static func cardsHint(_ cards: [CardOption]) -> String {
        guard !cards.isEmpty else { return "" }
        return """

        The user's cards: \(cards.map { "•\($0.digits) \($0.label)" }.joined(separator: "; ")).
        - card: the last 4 digits of the card used. Take it from the SMS or statement if shown; if the user names a card \
        by bank, name or network ("с визы", "с алока", "с зарплатной", "kapitaldan"), use that card. Omit it for cash or \
        when unknown.
        """
    }

    // MARK: - Скриншоты и выписки

    struct StatementResult {
        var drafts: [ExpenseDraft]
        /// Карта, к которой относится выписка (если видна).
        var card: String?
        /// Текущий остаток, если он виден на скриншоте или в выписке.
        var balance: Double?
        var balanceDate: Date?
    }

    /// Скриншот истории операций или PDF-выписка банка → операции и остаток.
    static func parseStatement(_ file: AIClient.Attachment, config: AIConfig, cards: [CardOption],
                               now: Date = .now) async throws -> StatementResult {
        try await parseStatement([file], config: config, cards: cards, now: now)
    }

    /// Несколько кадров одного списка (скриншоты подряд или кадры записи экрана) — одним запросом.
    static func parseStatement(_ files: [AIClient.Attachment], config: AIConfig, cards: [CardOption],
                               now: Date = .now) async throws -> StatementResult {
        let file = files[0]
        let isTable = files.count == 1 && file.mimeType.hasPrefix("text/")
        let object = try await AIClient.object(
            system: systemPrompt(now: now) + cardsHint(cards) + """

            Now you get a screenshot or PDF statement from a banking or payment app in Uzbekistan (bank apps, Payme, \
            Click, Uzum…) instead of text. Extract every completed transaction you can see — do not invent hidden ones, \
            skip pending, declined and cancelled ones. Lists are often grouped under day headers ("Сегодня", "Вчера", \
            "2 октября", "Bugun") — apply the header date to the rows below it. Amounts shown with "−" are expenses, \
            with "+" are income. Also return statement_card (last 4 digits of the card if shown), balance (the current \
            card balance if shown, never a transaction amount) and balance_date (YYYY-MM-DD) if shown.
            """,
            // Таблица из Excel/CSV приходит текстом — её кладём прямо в запрос, без вложения.
            text: isTable
                ? "Bank statement exported as a table (one row per line, cells separated by \";\"). "
                    + "Dates are already normalized to yyyy-MM-dd HH:mm — copy them exactly into date and time; if a date is still "
                    + "written like 02/09/2026, it is day/month/year (Uzbekistan). Rows marked as transfers between own cards are transfers, "
                    + "not spending. Skip rows that are only headers or totals.\n" + String(String(decoding: file.data, as: UTF8.self).prefix(150_000))
                : files.count > 1
                    ? "These \(files.count) images are consecutive screenshots of one transaction list while scrolling. "
                        + "Neighbouring images overlap, so the same rows appear twice — return each transaction only once. "
                        + "Day headers can be above the visible part: carry the last seen date header to the rows below it."
                    : "Extract the transactions from this file.",
            schema: { upper in
                var object = schema(upper: upper, cards: cards)
                func t(_ type: String) -> String { upper ? type.uppercased() : type }
                var props = object["properties"] as! [String: Any]
                props["statement_card"] = ["type": t("string"), "description": "Последние 4 цифры карты выписки."]
                props["balance"] = ["type": t("number"), "description": "Текущий остаток карты, если виден."]
                props["balance_date"] = ["type": t("string"), "description": "Дата остатка YYYY-MM-DD."]
                object["properties"] = props
                return object
            },
            toolName: toolName, toolDescription: "Записать операции из выписки.",
            config: config, maxTokens: 8192, timeout: 90, attachments: isTable ? [] : files
        )
        let items = object["transactions"] as? [[String: Any]] ?? []
        let card = (object["statement_card"] as? String).flatMap { digits in
            let only = digits.filter(\.isNumber)
            return only.count >= 4 ? String(only.suffix(4)) : nil
        }
        var drafts = items.compactMap { draft(from: $0, now: now) }
        for index in drafts.indices where drafts[index].card == nil { drafts[index].card = card }
        return StatementResult(
            drafts: drafts,
            card: card,
            balance: (object["balance"] as? NSNumber)?.doubleValue,
            balanceDate: (object["balance_date"] as? String).flatMap(parseDay)
        )
    }

    private static func systemPrompt(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd HH:mm"
        let categories = ExpenseCategory.allCases.map { "- \($0.rawValue): \($0.hint)" }.joined(separator: "\n")

        return """
        You extract money transactions for a personal finance app in Uzbekistan.

        The text is either a phrase the user dictated or typed (speech-to-text, may contain recognition errors), \
        e.g. "обед 45 тысяч, такси 18", "kecha bozorga 200 ming", "зарплата 8 миллионов", or a bank SMS \
        (Uzcard, Humo, Visa, Mastercard; Russian, Uzbek or English, often transliterated, e.g. \
        "HUMOCARD *1234: oplata 45000.00 UZS; KORZINKA; 03.10.26 14:22; Dostupno: 1234567.00 UZS").

        Now: \(formatter.string(from: now)), time zone \(TimeZone.current.identifier).

        Rules:
        - Return an empty list for anything that is not a completed transaction: confirmation/OTP codes, \
        declined or failed operations (otkaz, rad etildi, declined, oshibka), balance notices, ads, login alerts.
        - Only bank card/account SMS count. Messages from mobile operators and other services about their own \
        account (phone balance topped up, package activated, minutes left, offers) are NOT transactions — the \
        bank SMS already records the payment. Return an empty list for them.
        - In an SMS the transaction amount is never the balance ("Dostupno", "Balans", "Ostatok", "Qoldiq", "Balance").
        - income = true for money received: salary, incoming transfer, top-up (popolnenie, zachislenie, kirim, \
        tushum, "Kartaga o'tkazma" = transfer TO this card, received), refund, cashback. Paying, buying, \
        withdrawing and sending money ("Kartadan chiqim" = transfer FROM this card, P2P CHIQIM) are expenses.
        - kind:
        \(ExpenseKind.hint)
        - counterpart_card: last 4 digits of the OTHER side's card if shown (receiver card for outgoing, sender card for \
        incoming), e.g. "8600 **** **** 2135" → "2135". Never the user's own card used for this transaction. Omit if not shown.
        - own_transfer: true only if the text explicitly says it is a transfer between the user's own cards or accounts \
        ("Transfer between own cards", "Перевод между своими картами", "O'z kartalari orasida").
        - counterparty: the person or company on the other side if named ("PAYME P2P UZCARD NA MC OSMON" → "Osmon"); \
        channel: the app that carried a transfer or payment (Payme, Click, Tez, Zoomrad, SQB Mobile…).
        - Transfers (transfer_out, transfer_in) use category "transfers". For a transfer the title is the \
        counterparty if known, else "<channel> P2P". Payme/Click payments for utilities (MUNIS, KOMMUNAL) are "home".
        - Spoken amounts: "45 тысяч", "45 ming", "45k" = 45000; "1.5 миллиона", "1,5 mln" = 1500000. \
        In everyday speech in Uzbekistan a bare small number for a typical purchase means thousands of sum: \
        "такси 18" = 18000, "кофе 25" = 25000.
        - currency: UZS unless dollars/euros/rubles are clearly meant ($, USD, доллар, dollar).
        - title: the merchant or what was bought, short and human: "KORZINKA SUPERMARKET SERGELI" → "Korzinka", \
        "YANDEX.GO" → "Yandex Go", "обед" → "Обед". For a transfer use the recipient name if present. \
        Keep the user's language for things they named.
        - Several purchases in one phrase → several transactions.
        - date/time: from the SMS if present, else resolve "вчера", "в понедельник", "kecha"; omit when not said.
        - category — one of:
        \(categories)
        Use "income" only for income, and never "income" for expenses.
        """
    }

    private static func schema(upper: Bool, cards: [CardOption] = []) -> [String: Any] {
        func t(_ type: String) -> String { upper ? type.uppercased() : type }
        var props: [String: Any] = [
            "title": ["type": t("string"), "description": "Магазин или что купили, коротко."],
            "amount": ["type": t("number"), "description": "Сумма операции, положительное число, в единицах валюты."],
            "currency": ["type": t("string"), "enum": ["UZS", "USD", "EUR", "RUB"]],
            "income": ["type": t("boolean"), "description": "true — деньги пришли, false — потрачены."],
            "category": ["type": t("string"), "enum": ExpenseCategory.allCases.map(\.rawValue)],
            "date": ["type": t("string"), "description": "YYYY-MM-DD, если известна."],
            "time": ["type": t("string"), "description": "HH:mm, если известно."],
            "note": ["type": t("string"), "description": "Подробности, если были."],
            "kind": ["type": t("string"), "enum": ExpenseKind.allCases.map(\.rawValue)],
            "counterparty": ["type": t("string"), "description": "Получатель или отправитель, если назван."],
            "channel": ["type": t("string"), "description": "Приложение или сервис перевода/платежа."],
            "counterpart_card": ["type": t("string"), "description": "Последние 4 цифры карты другой стороны, если видны."],
            "own_transfer": ["type": t("boolean"), "description": "Явно указан перевод между своими картами."],
            "brand": ["type": t("string"), "description": "Company or app that was PAID, as named in the App Store, to show its logo: Korzinka, Yandex Go, WB Taxi, ATTO, HUMANS.uz, Uzum Market. Not the app used to pay (a taxi paid via Payme is WB Taxi). Payme/Click/Tez/Zoomrad only for P2P transfers through them or payments to them. Empty for people, cash and unknown shops."],
        ]
        props["card"] = cards.isEmpty
            ? ["type": t("string"), "description": "Последние 4 цифры карты, если известны."]
            : ["type": t("string"), "enum": cards.map(\.digits), "description": "Карта, которой платили."]
        return [
            "type": t("object"),
            "properties": [
                "transactions": [
                    "type": t("array"),
                    "items": ["type": t("object"), "properties": props, "required": ["title", "amount", "income", "category"]],
                ],
            ],
            "required": ["transactions"],
        ]
    }

    private static func draft(from item: [String: Any], now: Date) -> ExpenseDraft? {
        let amount = (item["amount"] as? NSNumber)?.doubleValue ?? Double(item["amount"] as? String ?? "") ?? 0
        guard amount > 0 else { return nil }
        var draft = ExpenseDraft()
        draft.amount = amount
        draft.currency = item["currency"] as? String ?? "UZS"
        draft.kind = ExpenseKind(rawValue: item["kind"] as? String ?? "")
        draft.isIncome = draft.kind?.isIncoming ?? (item["income"] as? Bool ?? false)
        let category = ExpenseCategory(rawValue: item["category"] as? String ?? "") ?? .other
        if draft.kind == nil && category == .transfers {
            draft.kind = draft.isIncome ? .transferIn : .transferOut
        }
        if draft.kind == .transferOut || draft.kind == .transferIn {
            draft.category = .transfers
        } else {
            draft.category = draft.isIncome ? .income : (category == .income ? .other : category)
        }
        draft.counterparty = (item["counterparty"] as? String)?.trimmed
        draft.channel = (item["channel"] as? String)?.trimmed
        draft.title = ((item["title"] as? String)?.trimmed).flatMap { $0.isEmpty ? nil : $0.capitalizedFirst } ?? draft.category.title
        draft.note = (item["note"] as? String)?.trimmed ?? ""
        draft.brand = (item["brand"] as? String)?.trimmed ?? ""
        if let digits = (item["counterpart_card"] as? String)?.filter(\.isNumber), digits.count >= 4 {
            draft.counterpartCard = String(digits.suffix(4))
        }
        if item["own_transfer"] as? Bool == true {
            draft.internalTransfer = true
            if draft.kind != .transferIn && draft.kind != .transferOut { draft.kind = draft.isIncome ? .transferIn : .transferOut }
            draft.category = .transfers
        }
        if (item["card"] as? String) == ExpenseStore.cashCard {
            draft.card = ExpenseStore.cashCard
        } else if let card = (item["card"] as? String)?.filter(\.isNumber), card.count >= 4 {
            draft.card = String(card.suffix(4))
        }

        let cal = Calendar.current
        let day = (item["date"] as? String).flatMap(parseDay)
        let time = (item["time"] as? String).flatMap(parseTime)
        var date = day ?? now
        if let time {
            date = cal.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date) ?? date
        } else if day != nil, !cal.isDate(date, inSameDayAs: now) {
            date = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        } else if day != nil {
            date = now
        }
        // Дата из будущего — почти наверняка ошибка распознавания.
        draft.date = date > now.addingTimeInterval(3600) ? now : date
        draft.dateUnknown = day == nil
        return draft
    }

    private static func parseDay(_ string: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }

    private static func parseTime(_ string: String) -> (hour: Int, minute: Int)? {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }
}

/// Без API-ключа: первое число в тексте — сумма, остальное — название.
enum LocalExpenseParser {
    static func parse(_ text: String, now: Date = .now) -> [ExpenseDraft] {
        let pattern = #"(\d[\d\s]*(?:[.,]\d+)?)\s*(тысяч\w*|тыс\.?|ming|k|млн|миллион\w*|mln)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text) else { return [] }

        let digits = text[numberRange].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        guard var amount = Double(digits) else { return [] }
        if let unitRange = Range(match.range(at: 2), in: text) {
            let unit = text[unitRange].lowercased()
            amount *= unit.hasPrefix("м") || unit.hasPrefix("mln") ? 1_000_000 : 1000
        }
        var title = text
        if let full = Range(match.range, in: text) { title.removeSubrange(full) }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let income = text.range(of: #"зарплат|доход|получил|пришл|maosh|kirim"#, options: [.regularExpression, .caseInsensitive]) != nil
        return [ExpenseDraft(title: title.isEmpty ? String(localized: "Расход") : title.capitalizedFirst,
                             amount: amount, category: income ? .income : .other, isIncome: income, date: now)]
    }
}
