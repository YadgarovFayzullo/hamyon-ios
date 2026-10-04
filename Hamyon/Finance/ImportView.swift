import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Импорт операций со скриншотов истории или PDF-выписки банка: ИИ читает файл, вы проверяете и добавляете.
struct ImportView: View {
    /// Файл, открытый из «Файлов» или Telegram через «Поделиться».
    var initialFile: URL?

    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// Чтение идёт в фоновой задаче: экран можно закрыть — ИИ дочитает, придёт уведомление.
    @State private var job = ImportJob.shared
    @State private var photos: [PhotosPickerItem] = []
    @State private var video: PhotosPickerItem?
    @State private var showFiles = false

    private var phase: ImportJob.Phase { job.phase }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Импорт операций")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if phase == .review {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Добавить (\(job.rows.filter(\.selected).count))")) {
                                job.save()
                                dismiss()
                            }
                            .fontWeight(.semibold)
                            .disabled(job.rows.allSatisfy { !$0.selected } && !job.balances.contains(where: \.apply))
                        }
                    }
                }
        }
        // Выдвижная панель: полоска сверху, закрывается свайпом вниз. Во время чтения — сворачивается,
        // а чтение продолжается в фоне.
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onAppear { job.visibleScreens += 1 }
        .onDisappear { job.visibleScreens -= 1 }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            job.readPhotos(items)
            photos = []
        }
        .onChange(of: video) { _, item in
            guard let item else { return }
            job.readVideo(item)
            video = nil
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image, .spreadsheet, .commaSeparatedText,
                                                                           UTType("org.openxmlformats.spreadsheetml.sheet") ?? .spreadsheet,
                                                                           UTType("com.microsoft.excel.xls") ?? .spreadsheet], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { job.readFiles(urls) }
        }
        .task {
            if let initialFile, !job.isBusy { job.readFiles([initialFile]) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .pick:
            pick
        case .preparing:
            VStack(spacing: 14) {
                ProgressView()
                Text("Готовлю файл…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .reading(let index, let total):
            VStack(spacing: 14) {
                Label(total > 1 ? String(localized: "Читаю часть \(index) из \(total)…") : String(localized: "Читаю выписку…"),
                      systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                    .geminiShimmer()
                ReadingProgress(index: index, total: total, started: job.partStarted)
                    .frame(maxWidth: 260)
                Text(job.foundSoFar > 0 ? String(localized: "Найдено операций: \(job.foundSoFar)") : String(localized: "Обычно это занимает 5–20 секунд на часть"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: job.foundSoFar)
                Text("Можно свернуть — дочитаю в фоне и пришлю уведомление.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                Button("Остановить", role: .destructive) { job.cancel() }
                    .font(.subheadline)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review:
            review
        case .failed(let message):
            ContentUnavailableView {
                Label("Не получилось", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("Выбрать другой файл") { job.reset() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var pick: some View {
        List {
            Section {
                PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .screenshots) {
                    Label("Скриншоты из «Фото»", systemImage: "photo.on.rectangle")
                }
                PhotosPicker(selection: $video, matching: .videos) {
                    Label("Запись экрана", systemImage: "record.circle")
                }
                Button {
                    showFiles = true
                } label: {
                    Label("PDF-выписка или файл", systemImage: "doc.text")
                }
            } footer: {
                Text("Откройте историю операций в приложении банка, Payme или Click, сделайте скриншоты (можно несколько) или скачайте выписку в PDF или Excel. ИИ найдёт операции и остаток, а уже добавленные по SMS пропустит.\n\nЕсли выписку не скачать (как в SQB Mobile): включите запись экрана в Пункте управления, откройте историю и медленно пролистайте её вниз, затем выберите это видео здесь.")
            }
            if !store.cards.isEmpty {
                Section {
                    Picker("Карта", selection: $job.defaultCard) {
                        Text("Определить по файлу").tag(String?.none)
                        ForEach(store.cards, id: \.self) { Text(store.cardTitle($0)).tag(Optional($0)) }
                    }
                } footer: {
                    Text("Если на скриншоте не видно номера карты, операции запишутся на выбранную.")
                }
            }
        }
    }

    private var review: some View {
        @Bindable var job = job
        let rows = job.rows
        return List {
            if !job.balances.isEmpty {
                Section("Остаток") {
                    ForEach($job.balances) { $found in
                        Toggle(isOn: $found.apply) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "\(store.cardTitle(found.card)): \(Money.string(found.amount))"))
                                Text(DueFormat.string(found.date, hasTime: false))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            let fresh = rows.indices.filter { !rows[$0].duplicate }
            let known = rows.indices.filter { rows[$0].duplicate }
            if rows.isEmpty {
                Section { Text("Операций не найдено.").foregroundStyle(.secondary) }
            }
            if !fresh.isEmpty {
                Section(String(localized: "Новые — \(fresh.count)")) {
                    ForEach(fresh, id: \.self) { index in row(index) }
                }
            }
            if !known.isEmpty {
                Section {
                    ForEach(known, id: \.self) { index in row(index) }
                } header: {
                    Text(String(localized: "Уже есть — \(known.count)"))
                } footer: {
                    Text("Эти операции уже пришли по SMS или были импортированы раньше — они не отмечены.")
                }
            }
            if job.crossDuplicates > 0 || rows.contains(where: \.own) {
                Section {
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if job.crossDuplicates > 0 {
                            Text(String(localized: "Повторов между файлами убрано: \(job.crossDuplicates)."))
                        }
                        Text("Удерживайте перевод, чтобы отметить «Это перевод себе», — такие же переводы на ту же карту отметятся сами.")
                    }
                }
            }
        }
    }

    /// Номера строк считаются по одному снимку списка, а строка рисуется позже — список мог уже сократиться
    /// (повтор убран, файл дочитан). Вне диапазона — ничего, а не падение (было дважды 4 октября).
    @ViewBuilder
    private func row(_ index: Int) -> some View {
        if job.rows.indices.contains(index) { rowContent(index) }
    }

    private func rowContent(_ index: Int) -> some View {
        let rows = job.rows
        let draft = rows[index].draft
        return Button {
            job.rows[index].selected.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: rows[index].selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(rows[index].selected ? Color.green : Color(.systemGray3))
                MerchantLogo(brand: draft.brand, category: draft.category, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title).lineLimit(1)
                    Text([rows[index].own ? String(localized: "↻ себе") : nil,
                          draft.dateUnknown ? String(localized: "дата не найдена") : DueFormat.string(draft.date, hasTime: true),
                          draft.card.map { "•\($0)" },
                          draft.counterpartCard.map { "→ •\($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Money.string(draft.isIncome ? draft.amount : -draft.amount, currency: draft.currency, sign: draft.isIncome))
                    .monospacedDigit()
                    .foregroundStyle(draft.isIncome ? .green : .primary)
            }
            .opacity(rows[index].duplicate && !rows[index].selected ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if draft.kind == .transferIn || draft.kind == .transferOut || draft.category == .transfers {
                let id = rows[index].id
                if rows[index].own {
                    Button("Это не перевод себе", systemImage: "person.fill") { job.setOwn(false, for: id) }
                } else {
                    Button("Это перевод себе", systemImage: "arrow.triangle.2.circlepath") { job.setOwn(true, for: id) }
                }
            }
        }
    }
}

/// Аккуратный прогресс чтения: готовые части — целиком, текущая — плавно ползёт к 90%,
/// пока ИИ отвечает (точного времени ответа заранее не знает никто), и сразу видно, что работа идёт.
private struct ReadingProgress: View {
    let index: Int
    let total: Int
    let started: Date

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(started)
            // За ~12 секунд проходим большую часть отрезка, дальше — всё медленнее, но не останавливаемся.
            let current = 0.9 * (1 - exp(-elapsed / 6))
            let value = (Double(index - 1) + current) / Double(max(total, 1))
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule()
                            .fill(LinearGradient(colors: GeminiShimmer.colors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, proxy.size.width * value))
                    }
                }
                .frame(height: 6)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
