import SwiftUI

/// Инструкция: автоматизация «Команд» пересылает каждую SMS банка в приложение.
struct SMSSetupView: View {
    @Environment(ExpenseStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var sample = ""
    @State private var result: String?
    @State private var checking = false

    private let steps: [LocalizedStringKey] = [
        "Откройте «Команды» → вкладка «Автоматизация» → «+».",
        "Выберите «Сообщение». В поле «Отправитель» укажите банк (например, 900 или имя отправителя SMS) — или «Сообщение содержит»: UZS.",
        "Включите «Запускать сразу» и нажмите «Далее».",
        "Добавьте действие «Добавить расход из SMS» (приложение Hamyon).",
        "Нажмите на поле «Текст» и выберите «Ввод быстрой команды».",
        "Готово. Каждая SMS о покупке будет сама появляться в «Расходах».",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.green, in: Circle())
                            Text(step)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Открыть «Команды»", systemImage: "arrow.up.forward.app") {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    }
                } header: {
                    Text("Как подключить")
                } footer: {
                    Text("iOS не даёт приложениям читать SMS напрямую — это делает автоматизация, и только для выбранного отправителя. Коды подтверждения и отказы ИИ пропускает, повторы не добавляются.")
                }

                Section {
                    TextField("Вставьте текст SMS из банка", text: $sample, axis: .vertical)
                        .lineLimit(3...8)
                    Button {
                        check()
                    } label: {
                        HStack {
                            Text("Разобрать и добавить")
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                    .disabled(sample.trimmed.isEmpty || checking)
                    if let result {
                        Text(result).font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Проверить или добавить старую SMS")
                }

                if !Account.pendingSMS.isEmpty {
                    Section {
                        Text("SMS в очереди: \(Account.pendingSMS.count). Они добавятся при следующем открытии основного аккаунта.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if store.smsLog.isEmpty {
                        Text("Действие ещё ни разу не вызывалось из «Команд».")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.smsLog, id: \.self) { line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } header: {
                    Text("Журнал SMS")
                } footer: {
                    Text("Здесь видно каждое сообщение, которое прислали «Команды», и что с ним стало.")
                }
            }
            .onAppear { store.reloadLog() }
            .navigationTitle("SMS банка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func check() {
        checking = true
        result = nil
        Task {
            do {
                let text = sample.trimmed
                let drafts = try await ExpenseParser.parse(text, config: settings.aiConfig, cards: store.cardOptions)
                if drafts.isEmpty { store.markSkipped(text) }
                let added = store.add(drafts, source: .sms, rawText: text)
                result = Self.describe(drafts: drafts, added: added)
                if !added.isEmpty { sample = "" }
            } catch {
                result = error.localizedDescription
            }
            checking = false
        }
    }

    static func describe(drafts: [ExpenseDraft], added: [Expense]) -> String {
        if drafts.isEmpty { return String(localized: "Это не покупка — пропущено.") }
        if added.isEmpty { return String(localized: "Эта SMS уже добавлена.") }
        let list = added.map { "\($0.title) \(Money.string($0.isIncome ? $0.amount : -$0.amount, currency: $0.currency, sign: $0.isIncome))" }
        return String(localized: "Добавлено: \(list.joined(separator: ", "))")
    }
}
