import SwiftUI

/// «Поделиться итогами месяца»: картинка в формате Stories с фирменной плашкой Hamyon —
/// её отправляют в Telegram/Instagram, и друзья видят приложение.
struct ShareSummaryView: View {
    /// Месяц, открытый на «Обзоре», — с него начинаем; дальше можно выбрать любой.
    let month: DateInterval
    @State private var selected: DateInterval?

    private var shown: DateInterval { selected ?? month }

    /// Месяцы, где есть операции, — новые первыми.
    private var months: [DateInterval] {
        var seen = Set<Date>()
        return store.expenses.compactMap { expense in
            let month = ExpenseStore.month(containing: expense.date)
            return seen.insert(month.start).inserted ? month : nil
        }
        .sorted { $0.start > $1.start }
    }

    @Environment(ExpenseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var hideAmounts = false
    @State private var image: UIImage?
    /// Та же картинка PNG-файлом — Telegram и Instagram принимают его без сюрпризов.
    @State private var file: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                monthPicker
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                        .padding(.horizontal, 40)
                }
                Toggle("Скрыть суммы — только проценты", isOn: $hideAmounts)
                    .padding(.horizontal, 24)
                if let image, let file {
                    ShareLink(item: file,
                              preview: SharePreview(String(localized: "Мои итоги в Hamyon"), image: Image(uiImage: image))) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .buttonBorderShape(.capsule)
                    .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 12)
            .navigationTitle("Итоги месяца")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onAppear(perform: render)
        .onChange(of: hideAmounts) { _, _ in render() }
        .onChange(of: selected) { _, _ in render() }
    }

    /// «‹ Октябрь 2026 ›»: стрелки — соседний месяц, нажатие на название — список месяцев.
    private var monthPicker: some View {
        let list = months
        let index = list.firstIndex(of: shown)
        return HStack {
            Button { if let index, index + 1 < list.count { selected = list[index + 1] } } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 36)
            }
            .disabled(index.map { $0 + 1 >= list.count } ?? true)
            Spacer()
            Menu {
                ForEach(list, id: \.start) { month in
                    Button(MonthSwitcher.title(month)) { selected = month }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(MonthSwitcher.title(shown)).font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .foregroundStyle(.primary)
            }
            Spacer()
            Button { if let index, index > 0 { selected = list[index - 1] } } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 36)
            }
            .disabled(index.map { $0 == 0 } ?? true)
        }
        .tint(.green)
        .padding(.horizontal, 16)
    }

    private func render() {
        let card = ShareCard(month: shown, totals: store.totals(in: shown),
                             saving: ExpenseAnalyzer.cached(for: shown)?.totalSaving ?? 0, hideAmounts: hideAmounts)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.isOpaque = true
        image = renderer.uiImage
        guard let png = image?.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Hamyon.png")
        try? png.write(to: url, options: .atomic)
        file = url
    }
}

/// Сама картинка: 360×640 pt → 1080×1920 px.
private struct ShareCard: View {
    let month: DateInterval
    let totals: MonthTotals
    let saving: Double
    let hideAmounts: Bool

    private var monthName: String {
        let f = DateFormatter()
        f.locale = DueFormat.locale
        f.dateFormat = "LLLL"
        return f.string(from: month.start)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.36, blue: 0.24), Color(red: 0.02, green: 0.12, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 0.3, green: 0.85, blue: 0.55).opacity(0.45)).frame(width: 340).blur(radius: 90).offset(x: -120, y: -230)
            Circle().fill(Color(red: 0.15, green: 0.6, blue: 0.75).opacity(0.35)).frame(width: 300).blur(radius: 90).offset(x: 140, y: 250)

            VStack(alignment: .leading, spacing: 0) {
                // Фирменная плашка — как на месте Dynamic Island.
                HStack(spacing: 5) {
                    Image(systemName: "wallet.bifold.fill").font(.system(size: 11, weight: .bold))
                    Text("Hamyon").font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(red: 0.16, green: 0.66, blue: 0.40), in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.top, 26)

                Text(String(localized: "Мой \(monthName)"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .padding(.top, 34)
                Text(hideAmounts ? String(localized: "куда ушли деньги") : String(localized: "потрачено"))
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.7)
                    .padding(.top, 2)
                if !hideAmounts {
                    Text(Money.string(totals.spent))
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.top, 6)
                }

                VStack(spacing: 14) {
                    ForEach(totals.sortedCategories.prefix(3), id: \.category) { row in
                        let share = row.amount / max(totals.spent, 1)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: row.category.symbol).font(.system(size: 13, weight: .bold))
                                    .frame(width: 26, height: 26)
                                    .background(row.category.color, in: Circle())
                                Text(row.category.title).font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Text(hideAmounts ? "\(Int((share * 100).rounded()))%" : Money.short(row.amount))
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                            }
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.15))
                                    Capsule().fill(row.category.color).frame(width: max(8, proxy.size.width * share))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
                .padding(.top, 30)

                if saving > 0 {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 18, weight: .semibold))
                        Text(hideAmounts ? String(localized: "ИИ нашёл, где сэкономить в следующем месяце")
                                         : String(localized: "ИИ нашёл, как сэкономить ≈ \(Money.short(saving)) в месяц"))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 26)
                }

                Spacer()

                HStack(spacing: 10) {
                    Image(systemName: "wallet.bifold.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(LinearGradient(colors: [Color(red: 0.43, green: 0.84, blue: 0.55), Color(red: 0.13, green: 0.59, blue: 0.37)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Hamyon").font(.system(size: 15, weight: .bold))
                        Text("Расходы голосом и из SMS, анализ ИИ").font(.system(size: 12)).opacity(0.75)
                    }
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 28)
            .foregroundStyle(.white)
        }
        .frame(width: 360, height: 640)
    }
}
