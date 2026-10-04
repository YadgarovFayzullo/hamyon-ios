import SwiftUI

@main
struct HamyonApp: App {
    @State private var store = ExpenseStore.shared
    @State private var settings = AppSettings.shared
    @State private var lock = AppLock()
    @State private var navigation = AppNavigation.shared

    init() {
        Notifier.setUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .environment(lock)
                .environment(navigation)
        }
    }
}

struct RootView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase
    /// Шторка — только когда уходят из открытого приложения. Окно Face ID тоже делает приложение
    /// «неактивным», и без этого после разблокировки мелькала шторка, похожая на экран блокировки.
    @State private var privacyCover = false
    @Environment(AppNavigation.self) private var navigation
    @State private var showVoice = false
    @State private var pendingVoice = false
    /// PDF или картинка, открытые в Hamyon из «Файлов», Telegram и т.п.
    @State private var importFile: ImportFile?

    struct ImportFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        ZStack {
            // Системный таббар спрятан: своя панель ниже одинаково выглядит на iOS 26 и 27
            // и держит голосовую кнопку отдельно, справа.
            // Системный таббар iOS (жидкое стекло) и отдельная круглая кнопка голоса над ним, справа.
            TabView(selection: Bindable(navigation).tab) {
                Tab(AppTab.overview.title, systemImage: AppTab.overview.symbol, value: AppTab.overview) {
                    NavigationStack { ExpensesView() }.voiceButton { showVoice = true }
                }
                Tab(AppTab.operations.title, systemImage: AppTab.operations.symbol, value: AppTab.operations) {
                    NavigationStack { OperationsView() }.voiceButton { showVoice = true }
                }
                Tab(AppTab.cards.title, systemImage: AppTab.cards.symbol, value: AppTab.cards) {
                    NavigationStack { CardsView() }.voiceButton { showVoice = true }
                }
            }

            switch lock.state {
            case .locked:
                LockScreen()
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    .zIndex(2)
            case .setup:
                CodeSetupView(onCancel: { lock.disable() })
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    .zIndex(2)
            case .unlocked:
                // В переключателе приложений суммы не видны.
                if privacyCover && settings.lockEnabled {
                    PrivacyCover().zIndex(1)
                }
            }

        }
        .tint(.green)
        // Чтение выписки в фоне — плашка сверху экрана, как уведомление.
        .overlay(alignment: .top) {
            if lock.state == .unlocked { ImportPill() }
        }
        // Плашка «Hamyon» на месте Dynamic Island — в своём окне поверх всего, и над листами тоже.
        .task {
            IslandBadgeWindow.show()
            AppTheme.apply(settings.theme, animated: false)
        }
        .sheet(isPresented: $showVoice) { ExpenseVoiceView() }
        .sheet(item: $importFile) { ImportView(initialFile: $0.url) }
        .sheet(item: lock.state == .unlocked ? Bindable(navigation).sheet : .constant(nil)) { sheet in
            SheetScreen(sheet: sheet)
        }
        .onOpenURL { url in
            if url.isFileURL {
                importFile = ImportFile(url: url)
            } else if let host = url.host, let sheet = AppNavigation.Sheet(rawValue: host) {
                navigation.sheet = sheet
            } else if url.host == "voice" {
                // Виджет «Сказать расход»: запись откроется сразу после входа по Face ID / коду.
                if lock.state == .unlocked { showVoice = true } else { pendingVoice = true }
            }
        }
        #if DEBUG
        // `-importFile путь`: прочитать выписку в фоне, не открывая экран импорта (проверка плашки).
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-importFile"), i + 1 < args.count {
                ImportJob.shared.readFiles(args[i + 1].split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            }
            // `-forgetOwnName "bashirjon rabbimov"`: снять «Это я» с имени — как смахнуть его в «Вы в выписках».
            if let i = args.firstIndex(of: "-forgetOwnName"), i + 1 < args.count {
                ExpenseStore.shared.forgetOwnName(args[i + 1])
            }
            // `-requestNotifications`: спросить разрешение сразу — в симуляторе «Разрешить» нажимает UI-тест.
            if args.contains("-requestNotifications") { await Notifier.requestPermission() }
            // `-demoSMS "Xarid: …"`: как будто пришла SMS банка — тот же путь, что у автоматизации «Команд».
            if let i = args.firstIndex(of: "-demoSMS"), i + 1 < args.count {
                if let j = args.firstIndex(of: "-demoNotifyAt"), j + 1 < args.count, let at = TimeInterval(args[j + 1]) {
                    Notifier.demoNotifyAt = Date(timeIntervalSince1970: at)
                }
                _ = try? await SMSIntake.handle(args[i + 1])
            }
            // `-testNotification`: пробное уведомление, как кнопка в настройках.
            if args.contains("-testNotification") { await Notifier.sendTest(store: ExpenseStore.shared) }
        }
        #endif
        #if DEBUG
        // `-demoEntry`: симулятор без окна не становится активным — имитируем вход.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-demoEntry") else { return }
            try? await Task.sleep(for: .seconds(2))
            navigation.entry += 1
        }
        #endif
        .onChange(of: lock.state) { _, state in
            if state == .unlocked && pendingVoice {
                pendingVoice = false
                showVoice = true
            }
            if state == .unlocked {
                navigation.entry += 1
                Task { await Notifier.requestPermission() }
            }
        }
        .onChange(of: scenePhase, initial: true) { old, phase in
            switch phase {
            case .active:
                privacyCover = false
                // Без кода вход — это возврат в приложение; с кодом вход считает разблокировка (выше),
                // иначе после Face ID цифры прокручивались бы дважды.
                if !settings.lockEnabled && lock.state == .unlocked {
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        navigation.entry += 1
                    }
                }
                // SMS, добавленные автоматизацией, пока приложение было в фоне.
                store.reload()
                LiveActivity.endAll()
                RecurringStore.shared.detect(from: store)
                Notifier.scheduleWeekly(store: store)
                WidgetSnapshot.update(from: store)
                Task { await Rates.shared.refresh() }
                // SMS, пришедшие, пока был открыт демо-аккаунт, — в основной.
                Task { await SMSIntake.processPending() }
            case .inactive:
                if old == .active && lock.state == .unlocked { privacyCover = true }
            case .background:
                privacyCover = true
                lock.lock()
            default:
                break
            }
        }
    }
}

enum AppTab: Hashable, CaseIterable {
    case overview, operations, cards

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Обзор"
        case .operations: "Операции"
        case .cards: "Карты"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "chart.pie.fill"
        case .operations: "arrow.up.arrow.down"
        case .cards: "creditcard.fill"
        }
    }
}

extension View {
    /// «Жидкое стекло» iOS 26+, на старых системах — матовый материал.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? .regular.interactive(), in: shape)
        } else {
            background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.regularMaterial), in: shape)
        }
    }
}

/// Экраны поверх вкладок: из уведомлений, «Обзора», виджета и Siri.
struct SheetScreen: View {
    let sheet: AppNavigation.Sheet

    var body: some View {
        if sheet == .review {
            ReviewView()
        } else if sheet == .reviewAll {
            ReviewView(includeSkipped: true)
        } else if sheet == .importStatement {
            ImportView()
        } else {
            // Выдвижная панель с полоской сверху: закрывается свайпом вниз, без кнопки «Закрыть».
            NavigationStack {
                content
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .review: ReviewView()
        case .reviewAll: ReviewView(includeSkipped: true)
        case .week: WeekView()
        case .debts: DebtsView()
        case .recurring: RecurringView()
        case .budgets: BudgetsView()
        case .people: PeopleView()
        case .ask: AskView()
        case .cash: CashView()
        case .importStatement: ImportView()
        }
    }
}

extension View {
    /// Круглая кнопка «Сказать расход» справа внизу — внутри вкладки, поэтому стоит ровно над таббаром.
    func voiceButton(_ action: @escaping () -> Void) -> some View {
        overlay(alignment: .bottomTrailing) {
            Button(action: action) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), tint: .green)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.trailing, 16)
            .padding(.bottom, 10)
            .accessibilityLabel("Сказать расход")
        }
    }
}
