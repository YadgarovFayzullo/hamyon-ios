import Compression
import Foundation

/// Выписка в Excel (.xlsx) → текстовая таблица для ИИ. Gemini и Claude не читают .xlsx напрямую,
/// поэтому распаковываем файл сами: .xlsx — это ZIP с XML внутри (общие строки, лист, стили).
enum SpreadsheetReader {
    enum Failure: LocalizedError {
        case oldExcel, unreadable

        var errorDescription: String? {
            switch self {
            case .oldExcel: String(localized: "Старый формат Excel (.xls) не читается. Сохраните выписку как .xlsx или PDF.")
            case .unreadable: String(localized: "Не удалось прочитать таблицу.")
            }
        }
    }

    /// Первый лист книги — строками «ячейка; ячейка; …». Даты Excel переводим в «2026-10-01 14:39».
    static func table(fromXLSX data: Data) throws -> String {
        let zip = try Zip(data)
        let shared = zip.file("xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        let dateStyles = zip.file("xl/styles.xml").map(StylesParser.dateStyles) ?? []
        let sheetName = zip.names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
        guard let sheetName, let sheet = zip.file(sheetName) else { throw Failure.unreadable }
        let rows = SheetParser.parse(sheet, shared: shared, dateStyles: dateStyles)
        let lines = rows.map { row in
            row.map { normalizeDate($0).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ";", with: ",") }
                .joined(separator: "; ")
        }
        .filter { !$0.replacingOccurrences(of: ";", with: "").trimmed.isEmpty }
        guard !lines.isEmpty else { throw Failure.unreadable }
        return lines.joined(separator: "\n")
    }

    /// Длинная выписка (за год — сотни строк) — частями: в каждой шапка банка, заголовок колонок и до `size` строк.
    /// Иначе ответ ИИ обрезается и часть операций теряется.
    static func chunks(_ table: String, size: Int = 60) -> [String] {
        let lines = table.components(separatedBy: "\n")
        // Заголовок колонок — первая строка, где хотя бы 4 ячейки.
        guard let header = lines.firstIndex(where: { $0.components(separatedBy: ";").count >= 4 }) else { return [table] }
        let prefix = lines[...header].joined(separator: "\n")
        let rows = Array(lines[(header + 1)...])
        guard rows.count > size else { return [table] }
        return stride(from: 0, to: rows.count, by: size).map { start in
            prefix + "\n" + rows[start..<min(start + size, rows.count)].joined(separator: "\n")
        }
    }

    /// «02/09/2026 04:21:18», «02.09.2026» → «2026-09-02 04:21»: даты приводим сами, а не доверяем ИИ.
    /// В Узбекистане сначала день; если второе число больше 12 — значит, наоборот (месяц/день).
    static func normalizeDate(_ cell: String) -> String {
        let pattern = #"^(\d{1,2})[./-](\d{1,2})[./-](\d{4})(?:[ T,]+(\d{1,2}):(\d{2})(?::\d{2})?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell)) else { return cell }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: cell).map { String(cell[$0]) } }
        guard var day = group(1).flatMap(Int.init), var month = group(2).flatMap(Int.init), let year = group(3) else { return cell }
        if month > 12 && day <= 12 { swap(&day, &month) }
        guard (1...12).contains(month), (1...31).contains(day) else { return cell }
        var result = String(format: "%@-%02d-%02d", year, month, day)
        if let hour = group(4).flatMap(Int.init), let minute = group(5) { result += String(format: " %02d:%@", hour, minute) }
        return result
    }

    /// CSV как есть — в текст (UTF-8, иначе Windows-1251, как часто у банков).
    static func table(fromCSV data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? String(decoding: data, as: UTF8.self)
    }

    /// Серийная дата Excel (дни с 30.12.1899) → «2026-10-01 14:39».
    static func excelDate(_ serial: Double) -> String {
        let date = Date(timeIntervalSince1970: (serial - 25569) * 86400)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

// MARK: - ZIP

/// Минимальный ZIP: центральный каталог + «stored» и «deflate» (как в .xlsx).
private struct Zip {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let offset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]

    var names: [String] { Array(entries.keys) }

    init(_ data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { throw SpreadsheetReader.Failure.unreadable }
        // Конец центрального каталога ищем с конца файла.
        var end = -1
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1)
        where bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 {
            end = i
            break
        }
        guard end >= 0 else {
            // Старый .xls — не ZIP, а двоичный формат.
            if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw SpreadsheetReader.Failure.oldExcel }
            throw SpreadsheetReader.Failure.unreadable
        }
        let count = Int(Self.u16(bytes, end + 10))
        var p = Int(Self.u32(bytes, end + 16))
        for _ in 0..<count {
            guard p + 46 <= bytes.count, Self.u32(bytes, p) == 0x02014B50 else { break }
            let method = Self.u16(bytes, p + 10)
            let compressed = Int(Self.u32(bytes, p + 20))
            let size = Int(Self.u32(bytes, p + 24))
            let nameLength = Int(Self.u16(bytes, p + 28))
            let extra = Int(Self.u16(bytes, p + 30))
            let comment = Int(Self.u16(bytes, p + 32))
            let offset = Int(Self.u32(bytes, p + 42))
            let name = String(decoding: bytes[(p + 46)..<min(bytes.count, p + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: method, compressedSize: compressed, size: size, offset: offset)
            p += 46 + nameLength + extra + comment
        }
    }

    func file(_ name: String) -> Data? {
        guard let entry = entries[name] else { return nil }
        let bytes = [UInt8](data)
        let p = entry.offset
        guard p + 30 <= bytes.count, Self.u32(bytes, p) == 0x04034B50 else { return nil }
        let start = p + 30 + Int(Self.u16(bytes, p + 26)) + Int(Self.u16(bytes, p + 28))
        guard start + entry.compressedSize <= bytes.count else { return nil }
        let raw = Array(bytes[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            // COMPRESSION_ZLIB в Apple — «сырой» DEFLATE, как в ZIP.
            var output = [UInt8](repeating: 0, count: max(entry.size, 1))
            let written = compression_decode_buffer(&output, output.count, raw, raw.count, nil, COMPRESSION_ZLIB)
            return written > 0 ? Data(output[0..<written]) : nil
        default:
            return nil
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

// MARK: - XML

/// xl/sharedStrings.xml: тексты ячеек хранятся отдельно, в ячейке — номер строки.
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Некоторые банки (TBC) пишут «x:row», «x:c» — с пространством имён; берём короткие имена.
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { strings.append(current) }
    }
}

/// xl/styles.xml: какие стили ячеек — даты (чтобы число 45931.6 стало «2026-10-01 14:24»).
private final class StylesParser: NSObject, XMLParserDelegate {
    private var customDateFormats: Set<Int> = []
    private var inCellXfs = false
    private var styles: [Bool] = []

    static func dateStyles(_ data: Data) -> Set<Int> {
        let delegate = StylesParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Некоторые банки (TBC) пишут «x:row», «x:c» — с пространством имён; берём короткие имена.
        parser.shouldProcessNamespaces = true
        parser.parse()
        return Set(delegate.styles.enumerated().filter(\.element).map(\.offset))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "numFmt":
            // Свой формат с днями/месяцами/годами — дата («dd.mm.yyyy hh:mm»).
            if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"]?.lowercased(),
               code.contains("y") || (code.contains("d") && code.contains("m")) {
                customDateFormats.insert(id)
            }
        case "cellXfs":
            inCellXfs = true
        case "xf" where inCellXfs:
            let id = attributes["numFmtId"].flatMap(Int.init) ?? 0
            styles.append((14...22).contains(id) || (45...47).contains(id) || customDateFormats.contains(id))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "cellXfs" { inCellXfs = false }
    }
}

/// Лист: строки и ячейки по адресам (A1, B1…), пропуски столбцов сохраняем.
private final class SheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private let dateStyles: Set<Int>
    private var rows: [[String]] = []
    private var row: [Int: String] = [:]
    private var column = 0
    private var type = ""
    private var style = 0
    private var value = ""
    private var collecting = false

    private init(shared: [String], dateStyles: Set<Int>) {
        self.shared = shared
        self.dateStyles = dateStyles
    }

    static func parse(_ data: Data, shared: [String], dateStyles: Set<Int>) -> [[String]] {
        let delegate = SheetParser(shared: shared, dateStyles: dateStyles)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Некоторые банки (TBC) пишут «x:row», «x:c» — с пространством имён; берём короткие имена.
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "row":
            row = [:]
        case "c":
            column = Self.column(attributes["r"] ?? "") ?? (row.keys.max().map { $0 + 1 } ?? 0)
            type = attributes["t"] ?? ""
            style = attributes["s"].flatMap(Int.init) ?? 0
            value = ""
        case "v", "t":
            collecting = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t":
            collecting = false
        case "c":
            var text = value
            if type == "s", let index = Int(value), shared.indices.contains(index) {
                text = shared[index]
            } else if type.isEmpty || type == "n", dateStyles.contains(style), let serial = Double(value) {
                text = SpreadsheetReader.excelDate(serial)
            }
            row[column] = text.trimmed
        case "row":
            let width = (row.keys.max() ?? -1) + 1
            rows.append((0..<width).map { row[$0] ?? "" })
        default:
            break
        }
    }

    /// «AB12» → 27 (номер столбца с нуля).
    private static func column(_ reference: String) -> Int? {
        let letters = reference.prefix { $0.isLetter }.uppercased()
        guard !letters.isEmpty else { return nil }
        return letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }
}
