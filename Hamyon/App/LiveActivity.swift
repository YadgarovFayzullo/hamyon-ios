import ActivityKit
import Foundation

/// Live Activity «Сегодня потрачено» больше не показываем: «остров» рисуется только внутри приложения
/// (`IslandBadge`). Здесь лишь закрываем активности, запущенные прошлой версией.
@MainActor
enum LiveActivity {
    static func endAll() {
        for activity in Activity<SpendingAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
