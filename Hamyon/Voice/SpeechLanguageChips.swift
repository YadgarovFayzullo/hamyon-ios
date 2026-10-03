import Speech
import SwiftUI

/// RU / UZ / EN прямо на экране записи: язык распознавания меняется на лету и запоминается.
struct SpeechLanguageChips: View {
    @Binding var localeID: String
    var tint: Color = .blue
    let onChange: () -> Void

    private static let options: [(id: String, title: String)] = {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        return [("ru-RU", "RU"), ("uz-UZ", "UZ"), ("en-US", "EN")].filter {
            supported.contains($0.0) || supported.contains($0.0.replacingOccurrences(of: "-", with: "_"))
        }
    }()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.options, id: \.id) { option in
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
