import LocalAuthentication
import Speech
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppLock.self) private var lock
    @Environment(ExpenseStore.self) private var store
    @State private var showSMSSetup = false
    @State private var showCodeSetup = false
    @State private var showImport = false
    @State private var notifyEachSMS = Notifier.notifyEachSMS
    @State private var testSent = false
    @State private var language = AppLanguage.current
    @State private var askRestart = false

    private var locales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { a, b in
            name(a).localizedCompare(name(b)) == .orderedAscending
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Тема", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Оформление")
            } footer: {
                Text("«Авто» — как в настройках iPhone.")
            }

            Section {
                Picker(selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Язык", systemImage: "globe")
                }
                .onChange(of: language) { _, new in
                    AppLanguage.set(new)
                    // Уже показан этот язык (например, «Как в iPhone» = русский) — перезапуск не нужен.
                    let target = new == .system ? (Locale.preferredLanguages.first?.hasPrefix("en") == true ? AppLanguage.en : .ru) : new
                    if target != AppLanguage.shown { askRestart = true }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { settings.lockEnabled }, set: { on in
                    if on {
                        showCodeSetup = true
                    } else {
                        // Выключить защиту может только владелец.
                        Task { if await Self.confirmOwner() { lock.disable() } }
                    }
                })) {
                    Label("Код-пароль при входе", systemImage: "lock.fill")
                }
                if settings.lockEnabled {
                    if AppLock.biometryType != .none {
                        Toggle(isOn: $settings.biometricsEnabled) {
                            Label(AppLock.biometryType == .touchID ? "Touch ID" : "Face ID",
                                  systemImage: AppLock.biometryType == .touchID ? "touchid" : "faceid")
                        }
                    }
                    Button {
                        showCodeSetup = true
                    } label: {
                        Label("Сменить код", systemImage: "key.fill")
                    }
                }
            } header: {
                Text("Защита")
            } footer: {
                Text("Приложение закрывается, когда вы из него выходите. Открывается по Face ID, а если он не сработал — по коду из 4 цифр. В переключателе приложений суммы скрыты.")
            }

            Section {
                Toggle(isOn: Binding(get: { notifyEachSMS }, set: { notifyEachSMS = $0; Notifier.notifyEachSMS = $0 })) {
                    Label("О каждой операции из SMS", systemImage: "bell.badge")
                }
                .tint(.green)
                Button {
                    Task { await Notifier.sendTest(store: store) }
                    testSent = true
                } label: {
                    Label(testSent ? String(localized: "Придёт через 5 секунд") : String(localized: "Прислать пробное"),
                          systemImage: testSent ? "checkmark" : "paperplane")
                }
                .disabled(testSent)
                .task(id: testSent) {
                    guard testSent else { return }
                    try? await Task.sleep(for: .seconds(6))
                    testSent = false
                }
            } header: {
                Text("Уведомления")
            } footer: {
                Text("Сумма, остаток бюджета, а для перевода без имени — вопрос «Кому?», на который можно ответить прямо в уведомлении. Предупреждения бюджета, напоминания о долгах и платежах и итог недели приходят всегда.")
            }

            Section("Данные") {
                NavigationLink {
                    CardsView()
                } label: {
                    Label("Мои карты", systemImage: "creditcard")
                }
                Button {
                    showSMSSetup = true
                } label: {
                    Label("SMS банка", systemImage: "message")
                }
                Button {
                    showImport = true
                } label: {
                    Label("Импорт: скриншоты и PDF", systemImage: "doc.viewfinder")
                }
            }

        }
        // Последние строки прокручиваются выше таббара.
        .contentMargins(.bottom, 12, for: .scrollContent)
        .navigationTitle("Настройки")
        .alert("Язык поменяется после перезапуска", isPresented: $askRestart) {
            // Приложение закрывается только по нажатию: iOS читает язык при запуске.
            Button("Закрыть Hamyon") { exit(0) }
            Button("Позже", role: .cancel) {}
        } message: {
            Text("Закройте Hamyon и откройте снова — интерфейс и ответы ИИ будут на новом языке.")
        }
        .sheet(isPresented: $showSMSSetup) { SMSSetupView() }
        .sheet(isPresented: $showImport) { ImportView() }
        .fullScreenCover(isPresented: $showCodeSetup) {
            CodeSetupView(onCancel: { showCodeSetup = false })
                .onChange(of: lock.state) { _, _ in showCodeSetup = false }
        }
    }

    private static func confirmOwner() async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: String(localized: "Подтвердите, что это вы"))) ?? false
    }

    private func name(_ locale: Locale) -> String {
        DueFormat.locale.localizedString(forIdentifier: locale.identifier)?.capitalizedFirst ?? locale.identifier
    }
}
