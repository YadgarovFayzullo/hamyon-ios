import LocalAuthentication
import SwiftUI

// MARK: - Фон и общие элементы

/// Тёмно-зелёный фон экрана входа с мягкими пятнами света.
struct LockBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.24, blue: 0.16), Color(red: 0.02, green: 0.10, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(Color(red: 0.25, green: 0.78, blue: 0.50).opacity(0.45))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: -130, y: -300)
            Circle()
                .fill(Color(red: 0.10, green: 0.55, blue: 0.65).opacity(0.35))
                .frame(width: 380, height: 380)
                .blur(radius: 120)
                .offset(x: 160, y: 320)
        }
        .ignoresSafeArea()
    }
}

private struct AppGlyph: View {
    var body: some View {
        Image(systemName: "wallet.bifold.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 68, height: 68)
            .background(
                LinearGradient(colors: [Color(red: 0.43, green: 0.84, blue: 0.55), Color(red: 0.13, green: 0.59, blue: 0.37)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }
}

/// Покачивание точек при неверном коде.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 12 * sin(animatableData * .pi * 4), y: 0))
    }
}

private struct CodeDots: View {
    enum Look { case normal, error, success }
    let filled: Int
    var look: Look = .normal

    var body: some View {
        HStack(spacing: 20) {
            ForEach(0..<AppLock.codeLength, id: \.self) { index in
                let on = index < filled
                Circle()
                    .fill(on ? color : .clear)
                    .overlay { Circle().strokeBorder(on ? color : .white.opacity(0.45), lineWidth: 1.5) }
                    .frame(width: 15, height: 15)
                    .scaleEffect(on ? 1.1 : 1)
                    .animation(.spring(duration: 0.2), value: on)
            }
        }
    }

    private var color: Color {
        switch look {
        case .normal: .white
        case .error: Color(red: 1, green: 0.42, blue: 0.42)
        case .success: Color(red: 0.42, green: 0.92, blue: 0.6)
        }
    }
}

private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 78, height: 78)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.32 : 0.10)))
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Цифровая клавиатура: 1–9, слева внизу — Face ID (или пусто), 0, «стереть».
private struct CodePad: View {
    var biometryIcon: String?
    var disabled = false
    let onDigit: (Int) -> Void
    let onDelete: () -> Void
    var onBiometry: () -> Void = {}

    var body: some View {
        Grid(horizontalSpacing: 26, verticalSpacing: 16) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(1...3, id: \.self) { column in key(row * 3 + column) }
                }
            }
            GridRow {
                if let biometryIcon {
                    Button(action: onBiometry) {
                        Image(systemName: biometryIcon).font(.system(size: 30, weight: .light))
                    }
                    .frame(width: 78, height: 78)
                    .accessibilityLabel("Face ID")
                } else {
                    Color.clear.frame(width: 78, height: 78)
                }
                key(0)
                Button(action: onDelete) {
                    Image(systemName: "delete.left").font(.system(size: 24, weight: .light))
                }
                .frame(width: 78, height: 78)
                .accessibilityLabel("Стереть")
            }
        }
        .foregroundStyle(.white)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func key(_ digit: Int) -> some View {
        Button { onDigit(digit) } label: {
            Text("\(digit)").font(.system(size: 34, weight: .regular, design: .rounded))
        }
        .buttonStyle(KeyStyle())
    }
}

// MARK: - Вход

struct LockScreen: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    @State private var code = ""
    @State private var look: CodeDots.Look = .normal
    @State private var shakes: CGFloat = 0
    @State private var message: String?

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: String(localized: "Доброе утро")
        case 12..<18: String(localized: "Добрый день")
        case 18..<23: String(localized: "Добрый вечер")
        default: String(localized: "Доброй ночи")
        }
    }

    private var biometryIcon: String? {
        guard lock.canUseBiometrics else { return nil }
        return AppLock.biometryType == .touchID ? "touchid" : "faceid"
    }

    var body: some View {
        ZStack {
            LockBackground()
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                AppGlyph()
                Text(greeting)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 22)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(status(now: context.date))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .contentTransition(.opacity)
                }
                .padding(.top, 6)
                CodeDots(filled: code.count, look: look)
                    .modifier(Shake(animatableData: shakes))
                    .padding(.top, 30)
                Spacer(minLength: 30)
                CodePad(
                    biometryIcon: biometryIcon,
                    disabled: (lock.lockedOutUntil ?? .distantPast) > .now || look == .success,
                    onDigit: type,
                    onDelete: { if !code.isEmpty { code.removeLast() } },
                    onBiometry: { Task { await biometrics() } }
                )
                Button("Забыли код?") { Task { await lock.resetWithDevicePasscode() } }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 22)
                    .padding(.bottom, 12)
            }
        }
        .sensoryFeedback(.error, trigger: shakes)
        .sensoryFeedback(.success, trigger: look) { _, new in new == .success }
        .task { await biometrics() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await biometrics() } }
        }
    }

    private func status(now: Date) -> String {
        if let until = lock.lockedOutUntil, until > now {
            return String(localized: "Слишком много попыток. Подождите \(Int(until.timeIntervalSince(now).rounded(.up))) с")
        }
        return message ?? String(localized: "Введите код")
    }

    private func type(_ digit: Int) {
        guard code.count < AppLock.codeLength else { return }
        look = .normal
        message = nil
        code.append(String(digit))
        guard code.count == AppLock.codeLength else { return }
        if lock.enter(code) {
            succeed()
        } else {
            look = .error
            message = String(localized: "Неверный код")
            withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            Task {
                try? await Task.sleep(for: .seconds(0.45))
                code = ""
                look = .normal
            }
        }
    }

    private func biometrics() async {
        guard scenePhase == .active, look != .success else { return }
        if await lock.unlockWithBiometrics() {
            code = String(repeating: "•", count: AppLock.codeLength)
            succeed()
        }
    }

    private func succeed() {
        look = .success
        Task {
            try? await Task.sleep(for: .seconds(0.25))
            lock.open()
        }
    }
}

// MARK: - Создание кода

struct CodeSetupView: View {
    /// Можно ли закрыть без кода (из настроек — да; при первом запуске — «Не сейчас»).
    var onCancel: (() -> Void)?

    @Environment(AppLock.self) private var lock
    @State private var first: String?
    @State private var code = ""
    @State private var look: CodeDots.Look = .normal
    @State private var shakes: CGFloat = 0
    @State private var message: String?

    var body: some View {
        ZStack {
            LockBackground()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if let onCancel {
                        Button(first == nil ? String(localized: "Не сейчас") : String(localized: "Отменить"), action: onCancel)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                Spacer(minLength: 30)
                AppGlyph()
                Text(first == nil ? String(localized: "Придумайте код") : String(localized: "Повторите код"))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 22)
                    .contentTransition(.opacity)
                Text(message ?? String(localized: "4 цифры — для входа, если Face ID не сработает"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 30)
                CodeDots(filled: code.count, look: look)
                    .modifier(Shake(animatableData: shakes))
                    .padding(.top, 30)
                Spacer(minLength: 30)
                CodePad(disabled: look == .success, onDigit: type, onDelete: { if !code.isEmpty { code.removeLast() } })
                    .padding(.bottom, 50)
            }
        }
        .sensoryFeedback(.error, trigger: shakes)
        .sensoryFeedback(.success, trigger: look) { _, new in new == .success }
    }

    private func type(_ digit: Int) {
        guard code.count < AppLock.codeLength else { return }
        look = .normal
        code.append(String(digit))
        guard code.count == AppLock.codeLength else { return }
        let entered = code
        Task {
            try? await Task.sleep(for: .seconds(0.15))
            if let first {
                if first == entered {
                    look = .success
                    try? await Task.sleep(for: .seconds(0.25))
                    lock.setCode(entered)
                } else {
                    look = .error
                    message = String(localized: "Коды не совпали. Придумайте заново")
                    withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                    try? await Task.sleep(for: .seconds(0.45))
                    withAnimation { self.first = nil }
                    code = ""
                    look = .normal
                }
            } else {
                withAnimation { first = entered }
                message = nil
                code = ""
            }
        }
    }
}

// MARK: - Заставка в переключателе приложений

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            LockBackground()
            AppGlyph()
        }
    }
}
