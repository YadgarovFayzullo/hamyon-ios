import SwiftUI
import UIKit

/// Своя анимация обновления: монеты падают в кошелёк Hamyon, вокруг — кольцо удержания.
struct WalletRefreshIndicator: View {
    /// Когда экран натянули до порога (nil — не натянут); кольцо заполняется за `holdDuration`.
    let holdStart: Date?
    let holdDuration: TimeInterval
    let refreshing: Bool

    private static let coin = LinearGradient(colors: [Color(red: 1.0, green: 0.86, blue: 0.35), Color(red: 0.93, green: 0.65, blue: 0.10)],
                                             startPoint: .top, endPoint: .bottom)
    private static let green = Color(red: 0.16, green: 0.66, blue: 0.40)

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let hold = refreshing ? 1 : holdStart.map { min(context.date.timeIntervalSince($0) / holdDuration, 1) } ?? 0
            ZStack {
                // Кольцо удержания: заполнилось — можно отпускать.
                Circle()
                    .stroke(Self.green.opacity(0.15), lineWidth: 3)
                    .opacity(refreshing ? 0 : 1)
                Circle()
                    .trim(from: 0, to: hold)
                    .stroke(Self.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(refreshing ? 0 : 1)

                // Монеты позади кошелька: уходят «внутрь» за его переднюю стенку.
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * 1.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    // Сначала монета крутится на месте, потом падает — иначе поворот растягивает её в полосу.
                    coinView
                        .rotation3DEffect(.degrees(phase * 360), axis: (x: 0, y: 1, z: 0))
                        .offset(x: CGFloat(i - 1) * 7, y: -22 + phase * 24)
                        .opacity(phase < 0.85 ? 1 : (1 - phase) / 0.15)
                }
                wallet
                    .scaleEffect(1 + 0.06 * sin(t * 10) * (refreshing ? 1 : hold))
            }
            .frame(width: 58, height: 58)
        }
    }

    private var coinView: some View {
        Circle()
            .fill(Self.coin)
            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
            .overlay(Text("S").font(.system(size: 7, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.9)))
            .frame(width: 12, height: 12)
            .shadow(color: .orange.opacity(0.3), radius: 2, y: 1)
    }

    private var wallet: some View {
        Image(systemName: "wallet.bifold.fill")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 25)
            .background(LinearGradient(colors: [Color(red: 0.42, green: 0.84, blue: 0.55), Color(red: 0.13, green: 0.59, blue: 0.37)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .offset(y: 6)
    }
}

extension View {
    /// Обновление свайпом вниз: натяните экран, подержите полсекунды, отпустите — монеты сыплются 3 секунды.
    func walletRefreshable(_ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(WalletRefreshModifier(action: action))
    }
}

private struct WalletRefreshModifier: ViewModifier {
    let action: @MainActor () async -> Void

    @State private var pull: CGFloat = 0
    @State private var interacting = false
    @State private var holdStart: Date?
    @State private var armed = false
    @State private var refreshing = ProcessInfo.processInfo.arguments.contains("-demoRefresh")
    @State private var armTask: Task<Void, Never>?

    /// Насколько натянуть: примерно седьмая часть экрана.
    private static let threshold: CGFloat = 120
    private static let holdDuration: TimeInterval = 0.5
    private static let playDuration: TimeInterval = 3
    private static let space: CGFloat = 70

    func body(content: Content) -> some View {
        let visible = refreshing || pull >= Self.threshold
        content
            // Пока идёт обновление, содержимое сдвинуто вниз — анимации есть где играть.
            .contentMargins(.top, refreshing ? Self.space : 0, for: .scrollContent)
            .animation(.smooth(duration: 0.35), value: refreshing)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                -(geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, value in
                pull = max(0, value)
                updateHold()
            }
            .onScrollPhaseChange { old, new in
                interacting = new == .interacting
                if old == .interacting && new != .interacting {
                    // Палец отпустили: обновляем, только если кольцо успело заполниться.
                    if armed { start() }
                    resetHold()
                }
            }
            .overlay(alignment: .top) {
                // Кошелёк появляется только когда экран натянут до порога (или идёт обновление).
                WalletRefreshIndicator(holdStart: holdStart, holdDuration: Self.holdDuration, refreshing: refreshing)
                    .offset(y: refreshing ? 6 : max(0, pull - 58) / 2)
                    .opacity(visible ? 1 : 0)
                    .scaleEffect(visible ? 1 : 0.6)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: visible)
                    .allowsHitTesting(false)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new }
    }

    /// Натянули до порога — запускаем отсчёт полсекунды; ослабили — сбрасываем.
    private func updateHold() {
        guard !refreshing, interacting else { return }
        if pull >= Self.threshold {
            guard holdStart == nil else { return }
            holdStart = .now
            armTask?.cancel()
            armTask = Task {
                try? await Task.sleep(for: .seconds(Self.holdDuration))
                guard !Task.isCancelled, holdStart != nil else { return }
                armed = true
            }
        } else if holdStart != nil {
            resetHold()
        }
    }

    private func resetHold() {
        armTask?.cancel()
        holdStart = nil
        armed = false
    }

    private func start() {
        refreshing = true
        Task {
            let started = Date.now
            await action()
            let left = Self.playDuration - Date.now.timeIntervalSince(started)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            refreshing = false
        }
    }
}
