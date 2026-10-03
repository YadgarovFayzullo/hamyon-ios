import SwiftUI
import UIKit

/// Фирменная плашка «Hamyon» ровно на месте Dynamic Island — как у Uzum Bank.
/// Она меньше выреза камеры, поэтому на живом экране спрятана под «островом»,
/// а видна на скриншотах и в переключателе приложений.
struct IslandBadge: View {
    /// Центр Dynamic Island на iPhone 14 Pro и новее: 11.33 pt сверху + половина высоты 37.33 pt.
    private static let islandCenterY: CGFloat = 30

    /// Dynamic Island есть только у телефонов с большим верхним отступом (59+ pt).
    static var isAvailable: Bool {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return (window?.safeAreaInsets.top ?? 0) >= 51
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wallet.bifold.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Hamyon")
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 19)
        .background(Color(red: 0.16, green: 0.66, blue: 0.40), in: Capsule())
        .position(x: UIScreen.main.bounds.width / 2, y: Self.islandCenterY)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Отдельное окно для плашки: в общем слое её закрывают листы («Долги», «Импорт»), а окно лежит поверх всего —
/// листов, алертов и экрана блокировки. Касания проходят насквозь.
@MainActor
enum IslandBadgeWindow {
    private static var window: UIWindow?

    static func show() {
        guard window == nil, IslandBadge.isAvailable,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        let host = BadgeHost(rootView: IslandBadge())
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.isUserInteractionEnabled = false
        window.overrideUserInterfaceStyle = AppSettings.shared.theme.style
        window.isHidden = false
        self.window = window
    }

    /// Строка состояния — по приложению под окном, а не по пустому окну плашки.
    private final class BadgeHost: UIHostingController<IslandBadge> {
        override var childForStatusBarStyle: UIViewController? { nil }
        override var preferredStatusBarStyle: UIStatusBarStyle { .default }
    }
}
