import SwiftUI
import UIKit

/// Удержание с перемещением пальца для графиков — системный жест, который не мешает прокрутке:
/// пока палец едет — прокручивается экран; держите на месте ~0,4 с — начинается выбор по графику.
/// SwiftUI-удержание с перетаскиванием внутри списка забирало прокрутку целиком — область графика была «мёртвой».
struct PressGesture: UIGestureRecognizerRepresentable {
    var minimumDuration: TimeInterval = 0.35
    /// Палец на графике (в координатах вида) — при начале удержания и при каждом движении.
    let onChange: (CGPoint) -> Void
    let onEnd: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = minimumDuration
        // До начала удержания палец почти на месте; сдвинули раньше — это прокрутка.
        press.allowableMovement = 10
        return press
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChange(context.converter.localLocation)
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }
}
