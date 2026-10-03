import SwiftUI

/// Иконка приложения бренда из App Store (Payme, Korzinka, Yandex Go…), иначе — значок категории.
struct MerchantLogo: View {
    let brand: String?
    let category: ExpenseCategory
    var size: CGFloat = 34

    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            } else {
                fallback
            }
        }
        .task(id: brand) { url = await LogoStore.shared.url(for: brand) }
    }

    private var fallback: some View {
        IconCircle(symbol: category.symbol, color: category.color, size: size)
    }
}

/// Ищет приложение бренда в узбекском App Store и запоминает ссылку на иконку.
@MainActor
final class LogoStore {
    static let shared = LogoStore()

    private let defaults = UserDefaults.standard
    /// бренд → ссылка на иконку; "" — приложения не нашлось.
    private var cache: [String: String]
    private var inFlight: [String: Task<String?, Never>] = [:]

    private init() {
        cache = defaults.dictionary(forKey: "brandLogos") as? [String: String] ?? [:]
        // Раньше неудачный поиск (в том числе из-за сети) запоминался навсегда — разово даём второй шанс.
        if !defaults.bool(forKey: "brandLogosRetry1") {
            cache = cache.filter { !$0.value.isEmpty }
            defaults.set(cache, forKey: "brandLogos")
            defaults.set(true, forKey: "brandLogosRetry1")
        }
        // Иконки небольшие, но их много — даём кэшу URLSession место, чтобы не качать заново.
        URLCache.shared = URLCache(memoryCapacity: 20_000_000, diskCapacity: 100_000_000)
    }

    func url(for brand: String?) async -> URL? {
        guard let brand = brand?.trimmed, !brand.isEmpty else { return nil }
        let key = brand.lowercased()
        if let cached = cache[key] { return URL(string: cached) }

        let task = inFlight[key] ?? Task { await Self.lookup(brand) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        // Сеть не ответила — не запоминаем: иначе логотип не появится никогда.
        guard let result else { return nil }
        cache[key] = result
        defaults.set(cache, forKey: "brandLogos")
        return URL(string: result)
    }

    /// Ссылка на иконку; "" — поиск ответил, но такого приложения нет; nil — сеть не ответила.
    private nonisolated static func lookup(_ brand: String) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: brand),
            .init(name: "country", value: "uz"),
            .init(name: "entity", value: "software"),
            .init(name: "limit", value: "5"),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }

        // Берём только приложение, в названии которого есть сам бренд, — иначе поиск подсунет чужое.
        let word = brand.lowercased().split(separator: " ").first.map(String.init) ?? brand.lowercased()
        let match = results.first { ($0["trackName"] as? String)?.lowercased().contains(word) == true }
        guard let artwork = match?["artworkUrl100"] as? String else { return "" }
        return artwork.replacingOccurrences(of: "100x100bb", with: "180x180bb")
    }
}
