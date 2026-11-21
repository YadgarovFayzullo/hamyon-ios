import SwiftUI
import UIKit

/// Месяц и сумма над «Обзором». Свайп влево-вправо меняет месяц, цифры прокручиваются барабаном.
/// Отдельный экран: при свайпе перерисовывается только он, а графики и операции — когда цифры уже докрутились.
struct MonthSwitcher: View {
    @Binding var month: DateInterval
    let months: [DateInterval]
    /// Учитываемые карты; пустой набор — все.
    let cards: Set<String>
    /// Нажали на сумму — открыть выбор карт.
    let onTapCards: () -> Void

    @Environment(ExpenseStore.self) private var store

    @State private var index: Int
    /// Листаем назад — цифры крутятся вниз, вперёд — вверх.
    @State private var countsDown = false
    @State private var commit: Task<Void, Never>?

    private static let roll = Animation.spring(response: 0.42, dampingFraction: 0.95)

    init(month: Binding<DateInterval>, months: [DateInterval], cards: Set<String>, onTapCards: @escaping () -> Void) {
        _month = month
        self.months = months
        self.cards = cards
        self.onTapCards = onTapCards
        // Сразу нужный месяц — иначе при открытии цифры прокручиваются с первого месяца до текущего.
        _index = State(initialValue: months.firstIndex(of: month.wrappedValue) ?? max(months.count - 1, 0))
    }

    var body: some View {
        let shown = months.indices.contains(index) ? months[index] : month
        let totals = store.totals(in: shown, cards: cards)
        VStack(spacing: 0) {
            header(shown)
            summary(totals, month: shown)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapCards)
        }
        .frame(maxWidth: .infinity)
        // Воздух под панелью с аватаром — месяц не прилипает к ней.
        .padding(.top, 10)
        .contentShape(Rectangle())
        .gesture(HorizontalSwipe { shift($0) })
        // Месяц сменили снаружи (столбик графика) — цифры тоже прокручиваются.
        .onChange(of: month) { _, target in
            guard let i = months.firstIndex(of: target), i != index else { return }
            countsDown = i < index
            index = i
        }
        .sensoryFeedback(.selection, trigger: index)
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-demoSwipe") else { return }
            try? await Task.sleep(for: .seconds(2))
            shift(-1)
            try? await Task.sleep(for: .seconds(2))
            shift(1)
        }
        #endif
    }

    private func jump(to target: Int) {
        guard target != index else { return }
        shift(target - index)
    }

    private func shift(_ delta: Int) {
        let target = index + delta
        guard months.indices.contains(target) else { return }
        countsDown = delta < 0
        index = target
        // Остальной экран — когда цифры докрутились; быстрые свайпы подряд — один пересчёт.
        commit?.cancel()
        commit = Task {
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled, months.indices.contains(index), months[index] != month else { return }
            month = months[index]
        }
    }

    // MARK: - Вид

    private func header(_ shown: DateInterval) -> some View {
        HStack {
            // Стрелки — на линии значков внутри карточек ниже: у самого края они срезались.
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 36, alignment: .leading) }
                .disabled(index == 0)
            Spacer()
            // Нажатие на месяц — список всех месяцев, чтобы сразу прыгнуть в нужный.
            Menu {
                ForEach(Array(months.enumerated()).reversed(), id: \.element.start) { i, month in
                    Button(Self.title(month)) { jump(to: i) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(Self.title(shown))
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.numericText(countsDown: countsDown))
                        .animation(Self.roll, value: index)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .tint(.primary)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 36, alignment: .trailing) }
                .disabled(index >= months.count - 1)
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 13)
    }

    private func summary(_ totals: MonthTotals, month: DateInterval) -> some View {
        let spent = Money.string(totals.spent)
        // Шрифт не подгоняется под ширину на лету — иначе цифры «дышат» во время прокрутки.
        let size: CGFloat = spent.count <= 13 ? 38 : spent.count <= 16 ? 32 : 26
        let current = month.contains(.now)
        return VStack(spacing: 6) {
            CountUpMoney(value: totals.spent, transition: .numericText(countsDown: countsDown),
                         unitFont: .system(size: size * 0.5, weight: .semibold, design: .rounded))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .animation(Self.roll, value: index)
            // Нажатие на сумму открывает выбор карт. Если выбраны не все — подсказываем, какие учтены.
            HStack(spacing: 5) {
                Text("потрачено").foregroundStyle(.secondary)
                if let daily = Self.dailyAverage(totals.spent, in: month) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(localized: "≈ \(Money.short(daily)) в день"))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(countsDown: countsDown))
                        .animation(Self.roll, value: index)
                }
                if !cards.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(scopeTitle).foregroundStyle(.green)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            // Доход и итог месяца — всегда, даже если дохода пока нет (тогда «+0» серым).
            // С подписями, как в Copilot и Buddy: значки ↓ и = без слов читались как загадка.
            HStack(spacing: 20) {
                stat("Доход", Money.string(totals.income, sign: true, unit: false),
                     color: totals.income > 0 ? .green : .secondary)
                Divider().frame(height: 30)
                stat("Итог", Money.string(totals.income - totals.spent, sign: true, unit: false),
                     color: totals.income >= totals.spent ? .primary : .red)
            }
            .padding(.top, 6)

            ForEach(totals.foreign.sorted(by: { $0.key < $1.key }), id: \.key) { currency, amount in
                Text(Rates.shared.rate(currency) != nil
                     ? String(localized: "в т.ч. \(Money.string(amount, currency: currency)) по курсу ЦБ")
                     : String(localized: "и ещё \(Money.string(amount, currency: currency))"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Бюджет — только у текущего месяца; у прошлых место остаётся, чтобы ничего не прыгало.
            if let limit = BudgetStore.shared.total, cards.isEmpty {
                VStack(spacing: 5) {
                    BudgetBar(share: totals.spent / max(limit, 1), color: .green)
                    HStack {
                        Text(totals.spent <= limit ? String(localized: "Осталось \(Money.string(limit - totals.spent, unit: false))")
                                                   : String(localized: "Перерасход \(Money.string(totals.spent - limit, unit: false))"))
                        Spacer()
                        if let daily = BudgetStore.shared.dailyAllowance(spent: totals.spent), daily > 0 {
                            // Не путать со средним расходом выше: это сколько ещё можно тратить в день.
                            Text(String(localized: "можно ≈ \(Money.short(daily)) в день"))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(totals.spent > limit ? .red : .secondary)
                }
                // На одной линии со стрелками месяца и значками в карточках.
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .opacity(current ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: current)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    /// Подпись сверху, сумма под ней — колонка в ряду «Доход | Итог».
    private func stat(_ title: LocalizedStringKey, _ value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText(countsDown: countsDown))
                .animation(Self.roll, value: index)
        }
        .lineLimit(1)
        .frame(minWidth: 110)
    }

    /// Средний расход в день: в текущем месяце — за прошедшие дни (включая сегодня), в прошлых — за весь месяц.
    static func dailyAverage(_ spent: Double, in month: DateInterval, now: Date = .now) -> Double? {
        guard spent > 0, month.start <= now else { return nil }
        let calendar = Calendar.current
        let end = month.contains(now) ? calendar.startOfDay(for: now).addingTimeInterval(86_400) : month.end
        let days = max(1, calendar.dateComponents([.day], from: month.start, to: end).day ?? 1)
        return spent / Double(days)
    }

    private var scopeTitle: String {
        if cards.isEmpty { return String(localized: "Все карты") }
        if cards.count == 1, let card = cards.first { return store.cardTitle(card) }
        return String(localized: "Карт: \(cards.count)")
    }

    static func title(_ month: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = DueFormat.locale
        f.dateFormat = "LLLL yyyy"
        return f.string(from: month.start).capitalizedFirst
    }
}

/// Горизонтальный свайп, который работает вместе с прокруткой списка, а не вместо неё.
/// SwiftUI-жест внутри списка часто отменяется прокруткой — отсюда «срабатывает через раз».
private struct HorizontalSwipe: UIGestureRecognizerRepresentable {
    /// +1 — следующий месяц (свайп влево), −1 — предыдущий.
    let onSwipe: (Int) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let t = recognizer.translation(in: recognizer.view)
        let v = recognizer.velocity(in: recognizer.view)
        let horizontal = abs(t.x) > abs(t.y) * 1.4
        switch recognizer.state {
        case .began:
            context.coordinator.handled = false
        case .changed:
            // Месяц меняется сразу, как только ясно, что это свайп вбок, — не дожидаясь, пока палец отпустят.
            guard !context.coordinator.handled, horizontal, abs(t.x) > 36 else { return }
            context.coordinator.handled = true
            onSwipe(t.x < 0 ? 1 : -1)
        case .ended:
            // Короткий резкий взмах.
            guard !context.coordinator.handled, horizontal, abs(t.x) > 12, abs(v.x) > 400 else { return }
            context.coordinator.handled = true
            onSwipe(t.x < 0 ? 1 : -1)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var handled = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
