import SwiftUI

/// Голосом: «обед 45 тысяч, такси 18» → проверка → сохранение.
struct ExpenseVoiceView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var speech = SpeechRecognizer()
    @State private var phase: Phase = .listening
    @State private var transcript = ""
    @State private var drafts: [ExpenseDraft] = []
    @State private var editing: ExpenseDraft?

    private enum Phase: Equatable {
        case listening, parsing, review
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отменить") {
                            speech.cancel()
                            dismiss()
                        }
                    }
                    if phase == .review {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(drafts.count > 1 ? String(localized: "Добавить (\(drafts.count))") : String(localized: "Добавить"), action: save)
                                .fontWeight(.semibold)
                                .disabled(drafts.isEmpty)
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(phase == .parsing)
        .task { await start() }
        .onChange(of: speech.isRecording) { wasRecording, isRecording in
            if wasRecording && !isRecording && phase == .listening { Task { await finish() } }
        }
        .onDisappear { speech.cancel() }
        .sheet(item: $editing) { draft in
            ExpenseDetailView(expense: nil, initial: draft) { edited in
                if let index = drafts.firstIndex(where: { $0.id == edited.id }) { drafts[index] = edited }
            }
        }
    }

    private var title: String {
        switch phase {
        case .listening: String(localized: "Говорите")
        case .parsing: String(localized: "Разбираю…")
        case .review: String(localized: "Проверьте")
        case .failed: String(localized: "Не получилось")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .listening:
            VStack(spacing: 24) {
                Text(speech.transcript.isEmpty ? String(localized: "Например: «обед 45 тысяч, такси 18»") : speech.transcript)
                    .font(.title3)
                    .foregroundStyle(speech.transcript.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .frame(minHeight: 80)
                if let error = speech.error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Button { Task { await finish() } } label: {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.18))
                            .frame(width: 96, height: 96)
                            .scaleEffect(1 + CGFloat(speech.level) * 0.6)
                            .animation(.easeOut(duration: 0.12), value: speech.level)
                        Circle().fill(Color.green.gradient).frame(width: 72, height: 72)
                        Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закончить запись")

                SpeechLanguageChips(localeID: Binding(get: { settings.speechLocale }, set: { settings.speechLocale = $0 }), tint: .green) { restart() }
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .parsing:
            VStack(spacing: 16) {
                Text(transcript).font(.title3).multilineTextAlignment(.center).padding(.horizontal)
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review:
            List {
                Section {
                    ForEach(drafts) { draft in
                        Button { editing = draft } label: { DraftExpenseRow(draft: draft) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                }
                Section("Вы сказали") {
                    Text(transcript).foregroundStyle(.secondary)
                    Button("Записать заново", systemImage: "mic") { Task { await start() } }
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Не получилось", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("Повторить") { Task { await start() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
    }

    private func restart() {
        speech.cancel()
        Task { await start() }
    }

    private func start() async {
        drafts = []
        transcript = ""
        phase = .listening
        await speech.start(localeID: settings.speechLocale)
    }

    private func finish() async {
        guard phase == .listening else { return }
        transcript = await speech.stop()
        guard !transcript.isEmpty else {
            phase = .failed(speech.error ?? String(localized: "Ничего не распознано. Попробуйте ещё раз."))
            return
        }
        phase = .parsing
        do {
            drafts = try await ExpenseParser.parse(transcript, config: settings.aiConfig, cards: store.cardOptions)
            phase = drafts.isEmpty ? .failed(String(localized: "Не нашёл сумму. Скажите, например: «кофе 25 тысяч».")) : .review
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func save() {
        store.add(drafts, source: .voice)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

private struct DraftExpenseRow: View {
    let draft: ExpenseDraft

    var body: some View {
        HStack(spacing: 12) {
            MerchantLogo(brand: draft.brand, category: draft.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title)
                Text([draft.category.title, DueFormat.string(draft.date, hasTime: true), draft.card.map { $0 == ExpenseStore.cashCard ? String(localized: "Наличные") : "•\($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.string(draft.isIncome ? draft.amount : -draft.amount, currency: draft.currency, sign: draft.isIncome))
                .fontWeight(.medium)
                .foregroundStyle(draft.isIncome ? .green : .primary)
            Image(systemName: "info.circle").foregroundStyle(.green)
        }
        .contentShape(Rectangle())
    }
}
