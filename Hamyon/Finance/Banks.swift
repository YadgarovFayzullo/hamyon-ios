import SwiftUI
import UIKit

/// Банки Узбекистана: название и приложение в App Store — по его иконке берём логотип и цвета карты.
struct Bank: Identifiable, Hashable {
    let id: String
    let name: String
    /// Запрос в App Store, по которому находится приложение банка.
    let app: String
    /// Сайт банка — с него берём логотип (иконка приложения банка часто другая, например Zoomrad у Aloqabank).
    let site: String

    /// Фирменные цвета карт, где они известны; для остальных цвет берётся из иконки приложения.
    var brand: CardColors? {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
        switch id {
        case "aloqabank": return CardColors(top: rgb(78, 160, 245), bottom: rgb(38, 112, 214), light: false)
        case "sqb": return CardColors(top: rgb(28, 86, 168), bottom: rgb(12, 46, 110), light: false)
        case "tbc": return CardColors(top: .white, bottom: rgb(244, 245, 247), light: true,
                                      stripes: [rgb(30, 80, 90), rgb(225, 40, 120), rgb(140, 150, 60)])
        case "kapitalbank": return CardColors(top: rgb(232, 52, 52), bottom: rgb(170, 22, 32), light: false)
        case "agrobank": return CardColors(top: rgb(40, 170, 90), bottom: rgb(16, 112, 58), light: false)
        case "uzum": return CardColors(top: rgb(130, 60, 255), bottom: rgb(84, 20, 200), light: false)
        default: return nil
        }
    }

    static let all: [Bank] = [
        Bank(id: "aloqabank", name: "Aloqabank", app: "Zoomrad", site: "aloqabank.uz"),
        Bank(id: "sqb", name: "SQB", app: "SQB Mobile", site: "sqb.uz"),
        Bank(id: "kapitalbank", name: "Kapitalbank", app: "Kapitalbank", site: "kapitalbank.uz"),
        Bank(id: "tbc", name: "TBC Bank", app: "TBC Bank", site: "tbcbank.uz"),
        Bank(id: "hamkorbank", name: "Hamkorbank", app: "Hamkor", site: "hamkorbank.uz"),
        Bank(id: "ipakyuli", name: "Ipak Yo‘li", app: "Ipak Yuli", site: "ipakyulibank.uz"),
        Bank(id: "agrobank", name: "Agrobank", app: "Agrobank", site: "agrobank.uz"),
        Bank(id: "xalqbank", name: "Xalq banki", app: "xazna", site: "xb.uz"),
        Bank(id: "anorbank", name: "Anorbank", app: "Anorbank", site: "anorbank.uz"),
        Bank(id: "uzum", name: "Uzum Bank", app: "Uzum Bank", site: "uzumbank.uz"),
        Bank(id: "asakabank", name: "Asakabank", app: "Asakabank", site: "asakabank.uz"),
        Bank(id: "nbu", name: "Milliy bank (NBU)", app: "Milliy", site: "nbu.uz"),
        Bank(id: "infinbank", name: "InfinBANK", app: "InfinBANK", site: "infinbank.com"),
        Bank(id: "davrbank", name: "Davr bank", app: "Davr Mobile", site: "davrbank.uz"),
        Bank(id: "trastbank", name: "Trastbank", app: "Trastpay", site: "trustbank.uz"),
        Bank(id: "turonbank", name: "Turonbank", app: "My Turon", site: "turonbank.uz"),
        Bank(id: "mkbank", name: "Mikrokreditbank", app: "Mavrid", site: "mkbank.uz"),
        Bank(id: "poytaxt", name: "Poytaxt bank", app: "Poytaxt Mobile", site: "poytaxtbank.uz"),
        Bank(id: "ipoteka", name: "Ipoteka bank", app: "Ipoteka Mobile", site: "ipotekabank.uz"),
        Bank(id: "garant", name: "Garant bank", app: "Garant bank", site: "garantbank.uz"),
    ]

    static func find(_ id: String?) -> Bank? { all.first { $0.id == id } }
}

enum CardNetwork: String, CaseIterable, Identifiable {
    case uzcard, humo, visa, mastercard, unionpay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uzcard: "Uzcard"
        case .humo: "Humo"
        case .visa: "Visa"
        case .mastercard: "Mastercard"
        case .unionpay: "UnionPay"
        }
    }

    /// Короткий значок в углу мини-карты.
    var badge: String {
        switch self {
        case .uzcard: "U"
        case .humo: "H"
        case .visa: "VISA"
        case .mastercard: "MC"
        case .unionpay: "UP"
        }
    }
}

/// Что пользователь задал для карты: название, банк, платёжная система; ручная карта — без SMS.
struct CardMeta: Codable, Equatable {
    var name = ""
    var bank: String?
    var network: String?
    var manual = false
    /// Остаток со скриншота, из выписки или вписанный вручную — для карт без SMS.
    var balance: Double?
    var balanceDate: Date?
}

extension CardNetwork {
    /// Платёжная система по первым цифрам полного номера: 8600 — Uzcard, 9860 — Humo, 4 — Visa…
    init?(cardNumber: String) {
        let digits = cardNumber.filter(\.isNumber)
        guard digits.count >= 6 else { return nil }
        if digits.hasPrefix("8600") || digits.hasPrefix("5614") { self = .uzcard }
        else if digits.hasPrefix("9860") { self = .humo }
        else if digits.hasPrefix("4") { self = .visa }
        else if digits.hasPrefix("5") || digits.hasPrefix("2") { self = .mastercard }
        else if digits.hasPrefix("62") { self = .unionpay }
        else { return nil }
    }
}

/// Цвета карты из иконки приложения банка: основной цвет и тёмный для градиента.
struct CardColors: Equatable {
    let top: Color
    let bottom: Color
    /// Светлая карта (например, белая TBC) — текст на ней тёмный.
    let light: Bool
    /// Вертикальные полоски слева, как на карте TBC.
    var stripes: [Color] = []

    static let fallback = CardColors(top: Color(red: 0.36, green: 0.40, blue: 0.48),
                                     bottom: Color(red: 0.18, green: 0.20, blue: 0.26), light: false)
}

@MainActor
@Observable
final class BankStyleStore {
    static let shared = BankStyleStore()

    private(set) var colors: [String: CardColors] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    /// Ссылка на иконку приложения банка (через тот же поиск App Store, что и логотипы магазинов).
    func iconURL(for bank: Bank) async -> URL? {
        await LogoStore.shared.url(for: bank.app)
    }

    /// Логотип с сайта банка; nil — у сайта нет нормальной иконки (меньше 32 px), тогда рисуем буквы.
    private(set) var logos: [String: UIImage] = [:]
    @ObservationIgnored private var logoRequested: Set<String> = []

    func logo(for bank: Bank) -> UIImage? {
        if let image = logos[bank.id] { return image }
        guard !logoRequested.contains(bank.id) else { return nil }
        logoRequested.insert(bank.id)
        Task {
            let url = URL(string: "https://www.google.com/s2/favicons?domain=\(bank.site)&sz=128")!
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), image.size.width * image.scale >= 32 else { return }
            withAnimation { logos[bank.id] = image }
        }
        return nil
    }

    func colors(for bank: Bank?) -> CardColors {
        guard let bank else { return .fallback }
        if let brand = bank.brand { return brand }
        if let known = colors[bank.id] { return known }
        load(bank)
        return .fallback
    }

    private func load(_ bank: Bank) {
        guard !loading.contains(bank.id) else { return }
        loading.insert(bank.id)
        if let saved = UserDefaults.standard.array(forKey: "bankColor-\(bank.id)") as? [Double], saved.count == 7 {
            colors[bank.id] = Self.make(saved)
            return
        }
        Task {
            guard let url = await iconURL(for: bank),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  let rgb = Self.dominant(image) else { return }
            UserDefaults.standard.set(rgb, forKey: "bankColor-\(bank.id)")
            withAnimation { colors[bank.id] = Self.make(rgb) }
        }
    }

    private static func make(_ v: [Double]) -> CardColors {
        CardColors(top: Color(red: v[0], green: v[1], blue: v[2]),
                   bottom: Color(red: v[3], green: v[4], blue: v[5]),
                   light: v[6] > 0.5)
    }

    /// Средний цвет насыщенных пикселей иконки; если иконка почти белая — светлая карта.
    nonisolated static func dominant(_ image: UIImage) -> [Double]? {
        let size = 32
        guard let cg = image.cgImage,
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0, light = 0.0
        for i in 0..<(size * size) {
            let pr = Double(data[i * 4]) / 255, pg = Double(data[i * 4 + 1]) / 255, pb = Double(data[i * 4 + 2]) / 255
            let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
            if minC > 0.88 { light += 1 }
            // Только заметно цветные пиксели — фон и белые надписи не в счёт.
            guard maxC - minC > 0.18, maxC > 0.15 else { continue }
            r += pr; g += pg; b += pb; n += 1
        }
        let total = Double(size * size)
        if n < total * 0.08 {
            // Почти белая или чёрная иконка.
            return light > total * 0.5 ? [0.97, 0.97, 0.98, 0.90, 0.91, 0.93, 1] : [0.25, 0.27, 0.32, 0.08, 0.09, 0.12, 0]
        }
        r /= n; g /= n; b /= n
        return [min(1, r * 1.08), min(1, g * 1.08), min(1, b * 1.08), r * 0.62, g * 0.62, b * 0.62, 0]
    }
}

/// Мини-карта в цветах банка: логотип слева сверху, значок платёжной системы справа снизу.
struct CardThumbnail: View {
    let bank: Bank?
    let network: CardNetwork?
    var width: CGFloat = 70

    private var styles: BankStyleStore { .shared }

    var body: some View {
        let colors = styles.colors(for: bank)
        let height = width * 0.68
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [colors.top, colors.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            if !colors.stripes.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(colors.stripes.enumerated()), id: \.offset) { _, color in
                        color.frame(width: width * 0.055)
                    }
                    Spacer(minLength: 0)
                }
            }
            if colors.stripes.isEmpty, let bank {
                Group {
                    if let logo = styles.logo(for: bank) {
                        Image(uiImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: height * 0.1, style: .continuous))
                    } else {
                        Text(initials(bank.name))
                            .font(.system(size: height * 0.26, weight: .heavy, design: .rounded))
                            .foregroundStyle(colors.light ? Color.black.opacity(0.75) : .white)
                            .minimumScaleFactor(0.5)
                    }
                }
                .frame(width: height * 0.46, height: height * 0.46, alignment: .topLeading)
                .padding(height * 0.12)
            }
            if let network {
                Text(network.badge)
                    .font(.system(size: network.badge.count > 1 ? height * 0.2 : height * 0.3, weight: .heavy, design: .rounded))
                    .italic(network == .visa)
                    .foregroundStyle(colors.light ? Color.black.opacity(0.7) : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(height * 0.1)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.1, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
                .strokeBorder(Color.black.opacity(colors.light ? 0.12 : 0), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
    }

    private func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
