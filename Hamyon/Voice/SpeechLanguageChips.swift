import Speech
import SwiftUI

/// RU / UZ / EN прямо на экране записи: язык распознавания меняется на лету и запоминается.
struct SpeechLanguageChips: View {
    @Binding var localeID: String
    var tint: Color = .blue
    /// Узбекский через Gemini — только когда в iOS своего нет, а ключ Gemini задан.
    var cloudUzbek = false
    let onChange: () -> Void

    private static let supported = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "_", with: "-") })

    private var options: [(id: String, title: String)] {
        [("ru-RU", "RU"), ("uz-UZ", "UZ"), ("en-US", "EN")].filter {
            Self.supported.contains($0.0) || ($0.0 == SpeechRecognizer.cloudLocale && cloudUzbek)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.id) { option in
                let selected = localeID == option.id
                Button {
                    guard !selected else { return }
                    localeID = option.id
                    onChange()
                } label: {
                    Text(option.title)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(selected ? .white : .secondary)
                        .background(selected ? tint : Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("Язык речи")
    }
}
