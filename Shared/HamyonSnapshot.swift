import Foundation

/// Цифры для виджета «Баланс»: приложение пишет их в общую папку App Group, виджет читает.
struct HamyonSnapshot: Codable {
    struct Card: Codable, Identifiable {
        var id: String { digits }
        let digits: String
        let title: String
        let balance: Double
        /// Цвет банка для полоски в виджете (RGB 0…1).
        let color: [Double]?
    }

    var spentToday: Double = 0
    var spentMonth: Double = 0
    var incomeMonth: Double = 0
    var budget: Double?
    var cards: [Card] = []
    var cash: Double?
    var hideBalances = false
    var updated = Date.now

    var totalBalance: Double { cards.reduce(0) { $0 + $1.balance } + (cash ?? 0) }

    static let appGroup = "group.uz.fayzullo.hamyon"

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    static func load() -> HamyonSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HamyonSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: url, options: .atomic)
    }

    static let preview = HamyonSnapshot(
        spentToday: 186_000, spentMonth: 2_430_000, incomeMonth: 9_000_000, budget: 4_000_000,
        cards: [Card(digits: "4503", title: "Aloqabank", balance: 363_530, color: [0.13, 0.36, 0.78]),
                Card(digits: "2136", title: "SQB", balance: 1_250_000, color: [0.10, 0.30, 0.70])],
        cash: 350_000)
}
