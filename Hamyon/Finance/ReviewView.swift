import SwiftUI

/// «Кому были переводы?»: переводы без имени по одному — ответ в одно касание.
struct ReviewView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var debt = false
    /// Все переводы без имени — и пропущенные, и старше 60 дней (открыли «Без имени» в «Людях»).
    var includeSkipped = false

    @State private var done = 0
    /// Пропущенные в этом режиме — только до закрытия экрана.
    @State private var sessionSkipped: Set<UUID> = []

    private var queue: [Expense] {
        guard includeSkipped else { return store.reviewQueue }
        return store.expenses.filter {
            $0.isTransfer && !$0.isInternal && $0.person == nil && $0.currency == "UZS" && !sessionSkipped.contains($0.id)
        }
    }
    /// Что сделали с каждым переводом — для кнопки «Назад».
    @State private var history: [Step] = []

    private struct Step {
        let id: UUID
        let counterparty: String?
        let own: Bool
        var sessionSkip = false
    }
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let expense = queue.first {
                    card(expense)
                        .id(expense.id)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    ContentUnavailableView {
                        Label("Все переводы разобраны", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text(done > 0 ? String(localized: "Отмечено: \(done). Теперь анализ знает, кому уходят деньги.")
                                      : String(localized: "Новые переводы без имени появятся здесь."))
                    } actions: {
                        Button("Готово") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                    }
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.1), value: queue.first?.id)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
        // Выдвижная панель: полоска сверху, закрывается свайпом вниз или нажатием мимо неё.
        .presentationDetents([.fraction(0.8)])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.disabled)
        .presentationCornerRadius(28)
    }

    /// Заголовок панели — вместо навигационной полосы с кнопкой «Закрыть».
    private var header: some View {
        VStack(spacing: 2) {
            Text("Кому были переводы?").font(.headline)
            if queue.count > 0 {
                Text(String(localized: "Осталось: \(queue.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity)
        // «Назад» — отменить последний ответ или пропуск и вернуть тот перевод.
        .overlay(alignment: .leading) {
            if !history.isEmpty {
                Button(action: undo) {
                    Label("Назад", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth(duration: 0.25), value: history.isEmpty)
        .padding(.top, 22)
        .padding(.bottom, 4)
        .background(Color(.systemGroupedBackground))
    }

    private func card(_ expense: Expense) -> some View {
        let incoming = expense.kind == .transferIn
        let suggestions = store.suggestions(for: expense)
        let likely = store.likelyPerson(for: expense) ?? suggestions.first
        let typed = name.trimmed
        let openDebt = typed.isEmpty ? nil : store.openDebt(person: typed, lent: incoming)
        return ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Image(systemName: incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(incoming ? .green : .primary)
                        .frame(width: 52, height: 52)
                        .background(Color(.tertiarySystemFill), in: Circle())
                    Text(Money.string(incoming ? expense.amount : -expense.amount, sign: incoming))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(incoming ? .green : .primary)
                    Text([expense.channel, expense.card.map { "•\($0)" }, DueFormat.string(expense.date, hasTime: true)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 12) {
                    Text(incoming ? "От кого пришло?" : "Кому отправили?")
                        .font(.title3.weight(.semibold))
                    HStack {
                        TextField(likely.map { String(localized: "Например, \($0)") } ?? String(localized: "Имя"), text: $name)
                            .focused($nameFocused)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit { save(expense) }
                        if !typed.isEmpty {
                            Button { save(expense) } label: {
                                Image(systemName: "arrow.up.circle.fill").font(.title)
                            }
                            .tint(.green)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if !suggestions.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(suggestions, id: \.self) { person in
                                Button { pick(person, expense) } label: {
                                    HStack(spacing: 4) {
                                        if person == likely { Image(systemName: "sparkles").font(.caption) }
                                        Text(person)
                                    }
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(person == likely ? .white : .primary)
                                    .background(person == likely ? Color.green : Color(.tertiarySystemFill), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Долг: дали в долг / вернули долг.
                    if !typed.isEmpty {
                        Toggle(isOn: $debt) {
                            if let openDebt {
                                Text(incoming ? "Это возврат долга (\(Money.string(openDebt.left)))" : "Это возврат моего долга (\(Money.string(openDebt.left)))")
                            } else {
                                Text(incoming ? "В долг — мне нужно вернуть" : "В долг — мне должны вернуть")
                            }
                        }
                        .tint(.green)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)

                VStack(spacing: 10) {
                    Button {
                        remember(expense, own: true)
                        withAnimation { store.markOwn(expense) }
                        next()
                    } label: {
                        Label(incoming ? "Это с моей карты" : "Себе на другую карту", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Пропустить") {
                        if includeSkipped {
                            history.append(Step(id: expense.id, counterparty: expense.counterparty, own: false, sessionSkip: true))
                            withAnimation { _ = sessionSkipped.insert(expense.id) }
                        } else {
                            remember(expense, own: false)
                            withAnimation { store.skipReview(expense) }
                        }
                        next()
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)

                if let raw = expense.rawText {
                    Text(raw)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }

    private func pick(_ person: String, _ expense: Expense) {
        name = person
        // Без долга — сохраняем сразу: один тап на перевод.
        if store.openDebt(person: person, lent: expense.kind == .transferIn) == nil { save(expense) }
    }

    private func save(_ expense: Expense) {
        let person = name.trimmed
        guard !person.isEmpty else { return }
        let incoming = expense.kind == .transferIn
        if debt {
            if let open = store.openDebt(person: person, lent: incoming) {
                store.repay(open, amount: expense.amount)
            } else {
                store.addDebt(DebtDraft(person: person, amount: expense.amount, lent: !incoming, date: expense.date))
            }
        }
        remember(expense, own: false)
        withAnimation { store.assign(expense, person: person) }
        done += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        next()
    }

    private func remember(_ expense: Expense, own: Bool) {
        history.append(Step(id: expense.id, counterparty: expense.counterparty, own: own))
    }

    /// Отменить последний шаг: перевод снова без ответа и снова на экране.
    private func undo() {
        guard let step = history.popLast(), let expense = store.expense(id: step.id) else { return }
        if step.sessionSkip {
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) { _ = sessionSkipped.remove(step.id) }
            return
        }
        if done > 0 && !step.own { done -= 1 }
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
            store.reopenReview(expense, counterparty: step.counterparty, wasOwn: step.own)
            if includeSkipped { expense.reviewed = true }
        }
        name = ""
        debt = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func next() {
        name = ""
        debt = false
    }
}

/// Плашки в несколько строк — переносятся, когда не помещаются.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
