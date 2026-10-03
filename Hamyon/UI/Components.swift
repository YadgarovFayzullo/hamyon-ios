import SwiftUI

/// Цветной круг с белым значком — как у списков в «Напоминаниях».
struct IconCircle: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
    }
}

/// Квадратная иконка строки в форме «Подробнее».
struct SquareIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Плавающие кнопки внизу справа: стеклянный микрофон и цветной «+».
struct FloatingAddButtons: View {
    let tint: Color
    let onMic: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            micButton
            addButton
        }
        .padding(.trailing, 20)
        // Над панелью вкладок, а не поверх неё.
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var micButton: some View {
        let label = Image(systemName: "mic.fill")
            .font(.system(size: 20, weight: .regular))
            .frame(width: 36, height: 36)
        if #available(iOS 26.0, *) {
            Button(action: onMic) { label }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(tint)
                .accessibilityLabel("Надиктовать")
        } else {
            Button(action: onMic) {
                label.foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Надиктовать")
        }
    }

    @ViewBuilder
    private var addButton: some View {
        // Как в «Напоминаниях» iOS 27: круг ~50 pt, тонкий плюс.
        let label = Image(systemName: "plus")
            .font(.system(size: 24, weight: .regular))
            .frame(width: 36, height: 36)
        if #available(iOS 26.0, *) {
            Button(action: onAdd) { label }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(tint)
                .accessibilityLabel("Новая операция")
        } else {
            Button(action: onAdd) {
                label.foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(tint, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Новая операция")
        }
    }
}

/// Переливающийся градиент «как в Gemini»: синий → фиолетовый → розовый бежит слева направо.
struct GeminiShimmer: ViewModifier {
    static let colors: [Color] = [
        Color(red: 0.28, green: 0.59, blue: 0.89),
        Color(red: 0.57, green: 0.47, blue: 0.78),
        Color(red: 0.79, green: 0.40, blue: 0.45),
        Color(red: 0.57, green: 0.47, blue: 0.78),
        Color(red: 0.28, green: 0.59, blue: 0.89),
    ]

    func body(content: Content) -> some View {
        TimelineView(.animation) { timeline in
            // Полный проход за 2,4 с; градиент вдвое шире текста и повторяется, поэтому шва не видно.
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            content
                .foregroundStyle(.clear)
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(colors: Self.colors + Self.colors.dropFirst(), startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 3)
                            .offset(x: -proxy.size.width * 2 * phase)
                    }
                    .mask(content)
                }
        }
    }
}

extension View {
    func geminiShimmer() -> some View { modifier(GeminiShimmer()) }
}

/// «↗ Расход / ↙ Доход» — как системный сегментный переключатель, но со стрелками: системный их не показывает.
struct IncomeSwitch: View {
    @Binding var isIncome: Bool
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            segment(false, title: "Расход", symbol: "arrow.up.right", color: .red)
            segment(true, title: "Доход", symbol: "arrow.down.left", color: .green)
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .sensoryFeedback(.selection, trigger: isIncome)
    }

    private func segment(_ value: Bool, title: LocalizedStringKey, symbol: String, color: Color) -> some View {
        let selected = isIncome == value
        return Button {
            withAnimation(.snappy(duration: 0.25)) { isIncome = value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .fontWeight(.bold)
                    .foregroundStyle(color)
                Text(title)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                if selected {
                    Capsule()
                        .fill(Color(UIColor { $0.userInterfaceStyle == .dark ? .systemGray3 : .white }))
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
