import SwiftUI

/// Выдвижная панель «Счета»: карты с галочками — какие учитывать на «Обзоре», как в банковских приложениях.
struct AccountsDrawer: View {
    /// Пустой набор — все карты (тогда и новые карты учитываются сами).
    @Binding var cards: Set<String>

    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings

    private var options: [String] {
        store.cards + (store.cashTracking ? [ExpenseStore.cashCard] : [])
    }

    private func isOn(_ card: String) -> Bool { cards.isEmpty || cards.contains(card) }

    private func balance(_ card: String) -> Double? {
        card == ExpenseStore.cashCard ? store.cashBalance : store.cardBalances.first { $0.card == card }?.balance
    }

    var body: some View {
        let total = options.filter(isOn).compactMap(balance).reduce(0, +)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Счета").font(.title.weight(.bold))
                    Text(settings.hideBalances ? "•••••• \(String(localized: "сум"))" : Money.string(total))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.smooth, value: total)
                    Text(cards.isEmpty ? String(localized: "на всех картах") : String(localized: "на выбранных картах"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element) { index, card in
                        if index > 0 { Divider().padding(.leading, 70) }
                        Button { toggle(card) } label: { row(card) }
                            .buttonStyle(.plain)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if !cards.isEmpty {
                    Button("Выбрать все") {
                        withAnimation(.smooth) { cards = [] }
                    }
                    .fontWeight(.semibold)
                    .tint(.green)
                }

                Text("Отмеченные карты учитываются в сумме месяца, графиках, календаре и последних операциях на «Обзоре».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .sensoryFeedback(.selection, trigger: cards)
    }

    private func row(_ card: String) -> some View {
        let on = isOn(card)
        let meta = store.meta(card)
        let bank = Bank.find(meta.bank)
        let cash = card == ExpenseStore.cashCard
        let name = cash ? String(localized: "Наличные") : (meta.name.isEmpty ? (bank?.name ?? String(localized: "Карта")) : meta.name)
        return HStack(spacing: 10) {
            Group {
                if cash {
                    Image(systemName: "banknote.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 33)
                        .background(Color.mint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    CardThumbnail(bank: bank, network: meta.network.flatMap(CardNetwork.init(rawValue:)), width: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
                if !cash {
                    Text(["•\(card)", bank?.name].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(settings.hideBalances ? "••••" : (balance(card).map { Money.string($0) } ?? "—"))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? .primary : .secondary)
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(on ? Color.green : Color(.tertiaryLabel))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    /// Последнюю отмеченную карту снять нельзя — иначе на «Обзоре» нечего показывать.
    private func toggle(_ card: String) {
        var set = cards.isEmpty ? Set(options) : cards
        if set.contains(card) {
            guard set.count > 1 else { return }
            set.remove(card)
        } else {
            set.insert(card)
        }
        withAnimation(.smooth) { cards = set == Set(options) ? [] : set }
    }
}
