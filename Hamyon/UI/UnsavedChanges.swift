import SwiftUI
import UIKit

extension View {
    /// Есть несохранённые изменения — свайп вниз не закрывает лист, а спрашивает «Выйти без сохранения?».
    /// `confirm` — тот же вопрос по кнопке «Отменить».
    func unsavedChanges(_ hasChanges: Bool, confirm: Binding<Bool>, onDiscard: @escaping () -> Void) -> some View {
        self
            .interactiveDismissDisabled(hasChanges)
            .background(DismissAttemptObserver { if hasChanges { confirm.wrappedValue = true } })
            .confirmationDialog("Изменения не сохранены", isPresented: confirm, titleVisibility: .visible) {
                Button("Выйти без сохранения", role: .destructive, action: onDiscard)
                Button("Продолжить редактирование", role: .cancel) {}
            } message: {
                Text("Если выйти сейчас, изменения пропадут.")
            }
    }
}

/// Ловит попытку смахнуть лист, который закрывать нельзя (`interactiveDismissDisabled`).
/// Делегат листа принадлежит SwiftUI — всё, кроме попытки закрыть, пересылаем ему как есть.
private struct DismissAttemptObserver: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(onAttempt: onAttempt) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onAttempt = onAttempt
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var onAttempt: () -> Void
        private var original: UIAdaptivePresentationControllerDelegate?

        init(onAttempt: @escaping () -> Void) {
            self.onAttempt = onAttempt
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard let presentation = root.presentationController, presentation.delegate !== self else { return }
            original = presentation.delegate
            presentation.delegate = self
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt()
            original?.presentationControllerDidAttemptToDismiss?(presentationController)
        }

        // Остальные методы делегата — как у SwiftUI.
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}

/// «Сдвиньте, чтобы подтвердить» — для действий, которые не хочется сделать случайно.
struct SlideToConfirm: View {
    let title: String
    var tint: Color = .green
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var done = false

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 52
            let limit = max(1, proxy.size.width - knob - 8)
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule()
                    .fill(tint.opacity(0.35))
                    .frame(width: offset + knob + 8)
                Text(done ? String(localized: "Готово") : title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity)
                    .opacity(done ? 1 : 1 - offset / limit)
                Circle()
                    .fill(tint.gradient)
                    .overlay(Image(systemName: done ? "checkmark" : "chevron.right.2")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white))
                    .frame(width: knob, height: knob)
                    .padding(4)
                    .offset(x: offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard !done else { return }
                                offset = min(max(0, value.translation.width), limit)
                            }
                            .onEnded { _ in
                                guard !done else { return }
                                if offset > limit * 0.85 {
                                    withAnimation(.spring(duration: 0.25)) { offset = limit; done = true }
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
                                } else {
                                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { offset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: 60)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
