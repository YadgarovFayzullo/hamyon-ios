import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct HamyonWidgets: WidgetBundle {
    var body: some Widget {
        VoiceWidget()
        BalanceWidget()
        VoiceControl()
        SpendingLiveActivity()
    }
}

private let brandGreen = Color(red: 0.16, green: 0.66, blue: 0.40)

/// Зелёная плашка с белым кошельком — «логотип» Hamyon в острове.
private struct Logo: View {
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "wallet.bifold.fill")
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(brandGreen, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct SpendingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpendingAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(brandGreen)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Logo(size: 30)
                        Text("Hamyon").font(.headline).foregroundStyle(.white)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Сегодня").font(.caption2).foregroundStyle(.white.opacity(0.6))
                        Text("−" + ActivityMoney.full(context.state.spentToday))
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let title = context.state.lastTitle, let amount = context.state.lastAmount {
                        HStack {
                            Text("Последняя: \(title)").lineLimit(1)
                            Spacer()
                            Text((context.state.lastIsIncome ? "+" : "−") + ActivityMoney.full(amount))
                                .foregroundStyle(context.state.lastIsIncome ? brandGreen : .white)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                    }
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    Image(systemName: "wallet.bifold.fill").font(.system(size: 12, weight: .bold))
                    Text("Hamyon").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(brandGreen, in: Capsule())
            } compactTrailing: {
                Text("−" + ActivityMoney.short(context.state.spentToday))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            } minimal: {
                Logo(size: 22)
            }
            .keylineTint(brandGreen)
        }
    }
}

private struct LockScreenView: View {
    let state: SpendingAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wallet.bifold.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(brandGreen)
                .frame(width: 42, height: 42)
                .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Hamyon · сегодня").font(.caption.weight(.semibold)).opacity(0.85)
                Text("−" + ActivityMoney.full(state.spentToday))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                if let title = state.lastTitle, let amount = state.lastAmount {
                    Text("\(title) \((state.lastIsIncome ? "+" : "−") + ActivityMoney.full(amount))")
                        .font(.caption)
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}


// MARK: - «Сказать расход» с главного экрана и экрана блокировки

private let voiceURL = URL(string: "hamyon://voice")!

struct VoiceEntry: TimelineEntry {
    let date: Date
}

struct VoiceProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceEntry { VoiceEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (VoiceEntry) -> Void) { completion(VoiceEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceEntry>) -> Void) {
        completion(Timeline(entries: [VoiceEntry(date: .now)], policy: .never))
    }
}

/// Нажатие открывает Hamyon сразу на записи голоса (после Face ID). Сам виджет микрофон не получает — так устроена iOS.
struct VoiceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VoiceWidget", provider: VoiceProvider()) { _ in
            VoiceWidgetView()
        }
        .configurationDisplayName("Сказать расход")
        .description("Нажмите и скажите, на что потратили.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct VoiceWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill").font(.title2.weight(.semibold))
                }
                .containerBackground(for: .widget) { Color.clear }
            case .accessoryRectangular:
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.title3.weight(.semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Hamyon").font(.headline)
                        Text("Сказать расход").font(.caption)
                    }
                }
                .containerBackground(for: .widget) { Color.clear }
            default:
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: "wallet.bifold.fill").font(.system(size: 11, weight: .bold))
                        Text("Hamyon").font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Image(systemName: "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(brandGreen)
                        .frame(width: 58, height: 58)
                        .background(.white, in: Circle())
                    Spacer()
                    Text("Сказать расход")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.36, green: 0.80, blue: 0.52), Color(red: 0.10, green: 0.52, blue: 0.32)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .widgetURL(voiceURL)
    }
}

/// Кнопка в Пункте управления и на кнопке действия.
struct VoiceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "VoiceControl") {
            ControlWidgetButton(action: OpenURLIntent(voiceURL)) {
                Label("Сказать расход", systemImage: "mic.fill")
            }
        }
        .displayName("Сказать расход")
        .description("Открывает Hamyon на записи голоса.")
    }
}


// MARK: - Баланс и траты

struct BalanceEntry: TimelineEntry {
    let date: Date
    let snapshot: HamyonSnapshot
}

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry { BalanceEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        completion(BalanceEntry(date: .now, snapshot: context.isPreview ? .preview : (HamyonSnapshot.load() ?? .preview)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        var snapshot = HamyonSnapshot.load() ?? HamyonSnapshot()
        // После полуночи «сегодня» начинается с нуля, даже если приложение не открывали.
        if !Calendar.current.isDateInToday(snapshot.updated) { snapshot.spentToday = 0 }
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86400))
        completion(Timeline(entries: [BalanceEntry(date: .now, snapshot: snapshot)], policy: .after(midnight)))
    }
}

struct BalanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BalanceWidget", provider: BalanceProvider()) { entry in
            BalanceWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Баланс и траты")
        .description("Остаток на картах и сколько потрачено сегодня и за месяц.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private enum WidgetMoney {
    static func full(_ value: Double) -> String { ActivityMoney.full(value) }
    static func short(_ value: Double) -> String { ActivityMoney.short(value) }
}

struct BalanceWidgetView: View {
    let snapshot: HamyonSnapshot
    @Environment(\.widgetFamily) private var family

    private var hidden: Bool { snapshot.hideBalances }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text("Сегодня −\(WidgetMoney.short(snapshot.spentToday))")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hamyon").font(.headline)
                    Text("Сегодня −\(WidgetMoney.short(snapshot.spentToday))").font(.caption)
                    Text("Месяц −\(WidgetMoney.short(snapshot.spentMonth))").font(.caption)
                }
                .privacySensitive()
                .containerBackground(for: .widget) { Color.clear }
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .widgetURL(URL(string: "hamyon://open"))
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "wallet.bifold.fill").font(.system(size: 11, weight: .bold))
            Text("Hamyon").font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private var background: some View {
        LinearGradient(colors: [Color(red: 0.36, green: 0.80, blue: 0.52), Color(red: 0.10, green: 0.52, blue: 0.32)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Spacer()
            Text("На картах").font(.caption).foregroundStyle(.white.opacity(0.75))
            Text(hidden ? "••••" : WidgetMoney.full(snapshot.totalBalance))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .privacySensitive()
            Spacer()
            Text("Сегодня −\(WidgetMoney.short(snapshot.spentToday))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .privacySensitive()
            budgetBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { background }
    }

    @ViewBuilder
    private var budgetBar: some View {
        if let budget = snapshot.budget, budget > 0 {
            let share = min(snapshot.spentMonth / budget, 1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(share >= 1 ? Color.red : .white).frame(width: max(3, proxy.size.width * share))
                }
            }
            .frame(height: 4)
            .padding(.top, 3)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                header
                Spacer()
                Text("Месяц").font(.caption).foregroundStyle(.white.opacity(0.75))
                Text("−" + WidgetMoney.full(snapshot.spentMonth))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .privacySensitive()
                if let budget = snapshot.budget {
                    Text("из \(WidgetMoney.short(budget))").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
                budgetBar
                Text("Сегодня −\(WidgetMoney.short(snapshot.spentToday))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.cards.prefix(3)) { card in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(card.color.map { Color(red: $0[0], green: $0[1], blue: $0[2]) } ?? .white.opacity(0.5))
                            .frame(width: 4, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(card.title).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                            Text(hidden ? "••••" : WidgetMoney.full(card.balance))
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .privacySensitive()
                        }
                    }
                }
                if let cash = snapshot.cash {
                    HStack(spacing: 6) {
                        Image(systemName: "banknote.fill").font(.caption2).foregroundStyle(.white).frame(width: 14)
                        Text(hidden ? "••••" : WidgetMoney.full(cash))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .privacySensitive()
                    }
                }
                if snapshot.cards.isEmpty && snapshot.cash == nil {
                    Text("Карты появятся после первой SMS банка").font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(for: .widget) { background }
    }
}
