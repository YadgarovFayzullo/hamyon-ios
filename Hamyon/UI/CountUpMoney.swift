import SwiftUI

/// Сумма, которая при каждом входе в приложение прокручивается барабаном от нуля до своего значения —
/// так же, как цифры при смене месяца.
struct CountUpMoney: View {
    let value: Double
    var currency = "UZS"
    var transition: ContentTransition = .numericText()
    /// Шрифт для «сум» после числа — мельче и серым, чтобы сумма читалась легче. Нет — одним шрифтом.
    var unitFont: Font?

    @Environment(AppNavigation.self) private var navigation
    /// Показываем ноль — в момент входа, до начала прокрутки.
    @State private var zero = false

    private static let roll = Animation.spring(response: 0.6, dampingFraction: 0.92)

    var body: some View {
        amount
            .monospacedDigit()
            .contentTransition(transition)
            // Анимация на самом тексте: внутри списка общая анимация до цифр не доходит.
            .animation(Self.roll, value: zero)
            .onChange(of: navigation.entry) {
                Task { @MainActor in
                    var reset = Transaction()
                    reset.disablesAnimations = true
                    withTransaction(reset) { zero = true }
                    try? await Task.sleep(for: .milliseconds(60))
                    zero = false
                }
            }
    }

    private var amount: Text {
        let shown = zero ? 0 : value
        guard let unitFont, currency == "UZS" else { return Text(Money.string(shown, currency: currency)) }
        return Text(Money.string(shown, unit: false))
            + Text(" " + String(localized: "сум")).font(unitFont).foregroundStyle(.secondary)
    }
}
