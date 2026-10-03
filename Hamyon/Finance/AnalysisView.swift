import SwiftUI

/// Карточка на «Обзоре»: вывод ИИ в две строки и сколько можно сэкономить. Нажатие — полный анализ.
struct AnalysisCard: View {
    let month: DateInterval

    @Environment(ExpenseStore.self) private var store

    var body: some View {
        let analysis = ExpenseAnalyzer.cached(for: month)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .geminiShimmer()
                .frame(width: 28)
            // Высота карточки одинаковая с анализом и без — страница не прыгает при смене месяца.
            VStack(alignment: .leading, spacing: 4) {
                Text("ИИ-анализ").font(.headline)
                Text(analysis.map { AmountFormat.prettify($0.summary) } ?? String(localized: "Узнайте, куда уходят деньги и что можно сократить"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                status(analysis)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            // Тонкая градиентная рамка в цветах Gemini.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: GeminiShimmer.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.7), lineWidth: 1.2)
        }
    }

    /// Одна строка под выводом: экономия, «есть новые операции» или подсказка.
    @ViewBuilder
    private func status(_ analysis: ExpenseAnalysis?) -> some View {
        if let analysis {
            if analysis.transactionCount != store.expenses(in: month).count {
                Text("Есть новые операции — обновите").foregroundStyle(.orange)
            } else if analysis.totalSaving > 0 {
                Text(String(localized: "Можно сэкономить ≈ \(Money.string(analysis.totalSaving)) / мес")).foregroundStyle(.green)
            } else {
                Text(String(localized: "Обновлено \(DueFormat.string(analysis.generatedAt, hasTime: false))")).foregroundStyle(.secondary)
            }
        } else {
            Text("Нажмите — разбор за пару секунд").foregroundStyle(.green)
        }
    }
}

/// Полный анализ месяца: вывод, все советы, экономия, обновление.
struct AnalysisView: View {
    let month: DateInterval

    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var analysis: ExpenseAnalysis?
    @State private var analyzing = false
    @State private var error: String?

    var body: some View {
        List {
            if let analysis, !analyzing {
                Section {
                    Text(AmountFormat.prettify(analysis.summary)).padding(.vertical, 4)
                    if analysis.totalSaving > 0 {
                        HStack {
                            Text("Можно сэкономить")
                            Spacer()
                            Text(String(localized: "≈ \(Money.string(analysis.totalSaving)) / мес"))
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }
                    }
                }
                Section("Советы") {
                    ForEach(analysis.insights) { InsightRow(insight: $0) }
                }
            }
            if analyzing {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Анализирую расходы…", systemImage: "sparkles")
                            .fontWeight(.medium)
                            .geminiShimmer()
                        ForEach([1.0, 0.85, 0.6], id: \.self) { width in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .frame(height: 10)
                                .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in length * width * 0.8 }
                                .opacity(0.35)
                                .geminiShimmer()
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                Button(action: analyze) {
                    Label(analysis == nil ? String(localized: "Проанализировать расходы") : String(localized: "Обновить анализ"),
                          systemImage: "sparkles")
                }
                .disabled(analyzing || settings.aiConfig.apiKey.trimmed.isEmpty)
            } footer: {
                if settings.aiConfig.apiKey.trimmed.isEmpty {
                    Text("Добавьте ключ Gemini в настройках, чтобы получить анализ.")
                } else {
                    Text("В ИИ уходят только суммы, категории и названия покупок — без номеров карт и SMS.")
                }
            }
        }
        // Кнопка «Обновить анализ» внизу не прячется под таббаром.
        .contentMargins(.bottom, 12, for: .scrollContent)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            analysis = ExpenseAnalyzer.cached(for: month)
            if analysis == nil && !settings.aiConfig.apiKey.trimmed.isEmpty { analyze() }
        }
    }

    private var title: String {
        let f = DateFormatter()
        f.locale = DueFormat.locale
        f.dateFormat = "LLLL yyyy"
        return String(localized: "Анализ: \(f.string(from: month.start))")
    }

    private func analyze() {
        withAnimation { analyzing = true }
        error = nil
        Task {
            do {
                let result = try await ExpenseAnalyzer.analyze(month: month, store: store, config: settings.aiConfig)
                ExpenseAnalyzer.cache(result, for: month)
                withAnimation { analysis = result }
            } catch {
                self.error = error.localizedDescription
            }
            withAnimation { analyzing = false }
        }
    }
}
