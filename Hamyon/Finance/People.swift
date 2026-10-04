import Foundation

/// Переводы людям: в SMS банка нет имени получателя, поэтому один раз спрашиваем «Кому?»,
/// а дальше подсказываем имя по похожим переводам.
extension ExpenseStore {
    /// Переводы без имени за последние 60 дней — новые первыми.
    var reviewQueue: [Expense] {
        let since = Calendar.current.date(byAdding: .day, value: -60, to: .now)!
        return expenses.filter { $0.needsReview && $0.date >= since }
    }

    func expense(id: UUID) -> Expense? { expenses.first { $0.id == id } }

    /// «Это Азиз»: имя становится названием перевода, анализ видит получателя.
    func assign(_ expense: Expense, person: String) {
        let name = person.trimmed.capitalizedFirst
        guard !name.isEmpty else { return }
        // Название (поставщик из SMS) не трогаем — имя хранится отдельно и показывается в списке.
        expense.counterparty = name
        expense.reviewed = true
        save()
    }

    /// Перевод себе — на карту, о которой банк не присылает SMS (другой банк, вклад).
    func markOwn(_ expense: Expense, counterpartCard: String? = nil) {
        if let counterpartCard { expense.counterpartCard = counterpartCard }
        expense.isInternal = true
        expense.manualInternal = true
        expense.reviewed = true
        // Запоминаем карту (или имя) другой стороны — такие же переводы тоже станут «себе».
        learnOwn(card: expense.counterpartCard, name: expense.person)
        applyOwnRules()
        save()
    }

    func undoOwn(_ expense: Expense) {
        expense.manualInternal = false
        expense.isInternal = false
        // Передумали — правило для этой карты или имени тоже снимаем.
        var cards = ownCounterpartCards
        if let card = expense.counterpartCard { cards.remove(card) }
        ownCounterpartCards = cards
        var names = ownCounterpartNames
        if let name = expense.person { names.remove(Expense.normalizedName(name)) }
        ownCounterpartNames = names
        save()
        linkInternalTransfers()
    }

    /// «Это не я» — обратное к «Это я»: имя уходит из «Вы в выписках», а его переводы, отмеченные «себе»
    /// по этому имени, снова считаются переводами человеку. Переводы на вашу известную карту и найденные пары не трогаем.
    func forgetOwnName(_ name: String) {
        let key = Expense.personKey(name)
        let reversed = Expense.reversedPersonKey(name)
        func samePerson(_ other: String) -> Bool {
            let otherKey = Expense.personKey(other)
            return otherKey == key || otherKey == reversed || Expense.reversedPersonKey(other) == key
        }
        // Вместе с вариантами написания: «Rabbimov B.», «Bashirjon R.».
        ownCounterpartNames = ownCounterpartNames.filter { !samePerson($0) }
        for expense in expenses where expense.manualInternal && expense.isTransfer {
            guard let person = expense.person, samePerson(person) else { continue }
            if let card = expense.counterpartCard, ownCounterpartCards.contains(card) || cards.contains(card) { continue }
            expense.isInternal = false
            expense.manualInternal = false
        }
        save()
        linkInternalTransfers()
    }

    /// «Это я»: все переводы этому человеку (в любом порядке имени и фамилии) — себе, и в будущих выписках тоже.
    func markPersonAsMe(_ name: String) {
        let key = Expense.personKey(name)
        let reversed = Expense.reversedPersonKey(name)
        for expense in expenses where expense.isTransfer {
            guard let person = expense.person else { continue }
            let personKey = Expense.personKey(person)
            if personKey == key || personKey == reversed || Expense.reversedPersonKey(person) == key {
                learnOwn(card: nil, name: person)
                expense.isInternal = true
                expense.manualInternal = true
                expense.reviewed = true
            }
        }
        learnOwn(card: nil, name: name)
        save()
    }

    // MARK: - Свои карты другой стороны

    /// Карты (последние 4 цифры), переводы на которые и с которых — себе.
    var ownCounterpartCards: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ownCounterpartCards") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ownCounterpartCards") }
    }

    /// Имена в выписке, которые на самом деле вы («YADGAROV FAYZULLO»).
    var ownCounterpartNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "ownCounterpartNames") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "ownCounterpartNames") }
    }

    func learnOwn(card: String?, name: String?) {
        if let card, card.count == 4 {
            var cards = ownCounterpartCards
            cards.insert(card)
            ownCounterpartCards = cards
        }
        if let name, !name.trimmed.isEmpty {
            var names = ownCounterpartNames
            names.insert(Expense.normalizedName(name))
            ownCounterpartNames = names
        }
    }

    /// Другая сторона — ваша карта (из SMS или отмеченная раньше) или ваше имя.
    func isOwnCounterpart(card: String?, name: String?) -> Bool {
        if let card, ownCounterpartCards.contains(card) || cards.contains(card) { return true }
        if let name, !name.trimmed.isEmpty, ownCounterpartNames.contains(Expense.normalizedName(name)) { return true }
        return false
    }

    /// Ваше имя узнаём из выписок: у обычных покупок банк пишет держателя карты отправителем
    /// («Congress-Hall Bus» — отправитель «FAYZULLO YADGAROV»). Переводы на это имя и с него — себе.
    @discardableResult
    func learnOwnNameFromStatements() -> Bool {
        var counts: [String: (name: String, count: Int)] = [:]
        for expense in expenses where !expense.isTransfer && expense.source == .statement {
            guard let name = expense.counterparty?.trimmed, !name.isEmpty, Expense.looksLikeName(name),
                  Expense.normalizedName(name) != Expense.normalizedName(expense.title) else { continue }
            let key = Expense.normalizedName(name)
            counts[key] = (name, (counts[key]?.count ?? 0) + 1)
        }
        guard let best = counts.values.max(by: { $0.count < $1.count }), best.count >= 2,
              !ownCounterpartNames.contains(Expense.normalizedName(best.name)) else { return false }
        learnOwn(card: nil, name: best.name)
        return true
    }

    /// Применяем правила ко всем переводам: прошлым и только что добавленным.
    @discardableResult
    func applyOwnRules() -> Bool {
        var changed = false
        // Строка выписки, где в названии — ваше имя, но банк записал её доходом или оплатой
        // («Yadgarov Fayzullo», +16,9 млн) — это перевод между своими картами.
        let ownNames = ownCounterpartNames
        if !ownNames.isEmpty {
            for expense in expenses where !expense.isTransfer && !expense.isInternal && expense.source == .statement
                && ownNames.contains(Expense.normalizedName(expense.title)) {
                expense.kindRaw = (expense.isIncome ? ExpenseKind.transferIn : .transferOut).rawValue
                expense.categoryRaw = ExpenseCategory.transfers.rawValue
                if (expense.counterparty ?? "").isEmpty { expense.counterparty = expense.title }
                changed = true
            }
        }
        for expense in expenses where expense.isTransfer && !expense.isInternal
            && isOwnCounterpart(card: expense.counterpartCard, name: expense.person) {
            expense.isInternal = true
            expense.manualInternal = true
            expense.reviewed = true
            changed = true
        }
        return changed
    }

    /// «Назад» на экране «Кому были переводы?»: вернуть перевод в очередь как был.
    func reopenReview(_ expense: Expense, counterparty: String?, wasOwn: Bool) {
        if wasOwn { undoOwn(expense) }
        expense.counterparty = counterparty
        expense.reviewed = false
        save()
    }

    func skipReview(_ expense: Expense) {
        expense.reviewed = true
        save()
    }

    /// Все известные люди — по частоте.
    var people: [String] {
        // Варианты одного человека («Yadgarov Fayzullo» / «Fayzullo Yadgarov» / «Yadgarov F.») — одно имя, самое полное.
        var groups: [String: (name: String, count: Int)] = [:]
        func add(_ name: String) {
            var key = Expense.personKey(name)
            if groups[key] == nil, let reversed = Expense.reversedPersonKey(name), groups[reversed] != nil { key = reversed }
            var group = groups[key] ?? (name, 0)
            if name.count > group.name.count { group.name = name }
            group.count += 1
            groups[key] = group
        }
        for expense in expenses where expense.isTransfer && !expense.isInternal {
            if let person = expense.person { add(person) }
        }
        for debt in debts { add(debt.person) }
        return groups.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }.map(\.name)
    }

    /// Самое полное написание этого человека среди известных имён.
    func canonicalName(_ name: String) -> String {
        let key = Expense.personKey(name)
        let reversed = Expense.reversedPersonKey(name)
        return people.first { Expense.personKey($0) == key || Expense.personKey($0) == reversed
            || Expense.reversedPersonKey($0) == key } ?? name
    }

    /// Кому скорее всего этот перевод: тот же сервис, та же сумма, то же время суток.
    /// Первым идёт самый вероятный; остальные — по частоте.
    func suggestions(for expense: Expense, limit: Int = 8) -> [String] {
        var score: [String: Double] = [:]
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: expense.date)
        for other in expenses where other.id != expense.id && other.kind == expense.kind && !other.isInternal {
            guard let person = other.person else { continue }
            var points = 1.0
            if abs(other.amount - expense.amount) < 1 { points += 4 }
            else if abs(other.amount - expense.amount) <= expense.amount * 0.1 { points += 1.5 }
            if other.channel != nil && other.channel?.lowercased() == expense.channel?.lowercased() { points += 1 }
            if other.card == expense.card { points += 0.5 }
            if abs(calendar.component(.hour, from: other.date) - hour) <= 2 { points += 0.5 }
            score[person, default: 0] += points
        }
        // Открытый долг: вернули ровно эту сумму — почти наверняка этот человек.
        for debt in debts where debt.isOpen && abs(debt.left - expense.amount) < 1 {
            score[debt.person, default: 0] += 6
        }
        // Склеиваем варианты одного имени, показываем самое полное.
        var merged: [String: Double] = [:]
        for (person, points) in score { merged[canonicalName(person), default: 0] += points }
        var ranked = merged.keys.sorted { merged[$0]! > merged[$1]! }
        for person in people where !ranked.contains(person) { ranked.append(person) }
        return Array(ranked.prefix(limit))
    }

    /// Уверенная догадка: этот человек уже получал ровно такую сумму через тот же сервис не меньше двух раз,
    /// а больше никто — такую сумму не получал.
    func likelyPerson(for expense: Expense) -> String? {
        let same = expenses.filter {
            $0.id != expense.id && $0.kind == expense.kind && !$0.isInternal
                && abs($0.amount - expense.amount) < 1
                && $0.channel?.lowercased() == expense.channel?.lowercased()
        }
        let names = Set(same.compactMap(\.person))
        guard names.count == 1, let name = names.first, same.filter({ $0.person == name }).count >= 2 else { return nil }
        return name
    }

    /// Сводка по людям за период: сколько отправили и получили.
    func peopleSummary(in interval: DateInterval) -> [PersonSummary] {
        var result: [String: PersonSummary] = [:]
        for expense in expenses where expense.isTransfer && !expense.isInternal && expense.currency == "UZS"
            && interval.start <= expense.date && expense.date < interval.end {
            let name = expense.person ?? String(localized: "Без имени")
            // Варианты одного имени («Rabbimov B.», «Rabbimov Bashirjon») — одна строка с самым полным именем.
            var key = expense.person.map(Expense.personKey) ?? "?"
            // «Yadgarov Fayzullo» — тот же человек, что «Fayzullo Yadgarov».
            if let person = expense.person, result[key] == nil, let reversed = Expense.reversedPersonKey(person),
               result[reversed] != nil { key = reversed }
            var row = result[key] ?? PersonSummary(name: name, known: expense.person != nil)
            if name.count > row.name.count { row.name = name }
            if expense.kind == .transferIn { row.received += expense.amount } else { row.sent += expense.amount }
            row.count += 1
            result[key] = row
        }
        return result.values.sorted { ($0.known ? 0 : 1, -($0.sent + $0.received)) < ($1.known ? 0 : 1, -($1.sent + $1.received)) }
    }
}

struct PersonSummary: Identifiable {
    var id: String { name }
    var name: String
    let known: Bool
    var sent: Double = 0
    var received: Double = 0
    var count = 0
}
