import AVFoundation
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

/// Запись экрана с прокруткой истории операций → кадры для ИИ.
/// Берём новый кадр, когда список прокрутился примерно на две трети экрана: соседние кадры немного
/// перекрываются (строки не теряются), а одинаковые кадры (пока не листали) не отправляем.
enum VideoFrames {
    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? { String(localized: "Не удалось прочитать видео.") }
    }

    static func extract(from url: URL, maxFrames: Int = 120) async throws -> [AIClient.Attachment] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else { throw Failure.unreadable }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1000, height: 2200)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var kept: [CGImage] = []
        var previous: [Double]?
        var scrolled = 0
        var last: CGImage?
        var time = 0.2
        while time < duration, kept.count < maxFrames {
            defer { time += 0.3 }
            guard let (image, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else { continue }
            last = image
            let profile = Self.profile(image)
            var keep = previous == nil
            if let previous {
                let (shift, error) = Self.shift(from: previous, to: profile)
                // Плохое совпадение — пролистали слишком быстро или экран сменился: берём кадр сразу.
                if error > 0.04 { keep = true } else { scrolled += shift }
            }
            // Прокрутили на ~65% высоты — новый кадр (треть экрана перекрывается с прошлым).
            if scrolled >= Int(Double(profileHeight) * 0.65) { keep = true }
            if keep {
                kept.append(image)
                scrolled = 0
            }
            previous = profile
        }
        // Последний кадр — чтобы не потерять низ списка.
        if let last, let lastKeptImage = kept.last, lastKeptImage !== last, scrolled > profileHeight / 8 {
            kept.append(last)
        }
        guard !kept.isEmpty else { throw Failure.unreadable }
        return kept.compactMap { image in
            UIImage(cgImage: image).jpegData(compressionQuality: 0.7).map { AIClient.Attachment(mimeType: "image/jpeg", data: $0) }
        }
    }

    // MARK: - Насколько прокрутили

    private static let profileWidth = 32
    private static let profileHeight = 400

    /// Яркость по строкам средней части кадра (без статус-бара и таббара).
    private static func profile(_ image: CGImage) -> [Double] {
        let width = profileWidth, height = profileHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        let cropped = image.cropping(to: CGRect(x: 0, y: Double(image.height) * 0.15,
                                                width: Double(image.width), height: Double(image.height) * 0.7)) ?? image
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (0..<height).map { y in
            Double(pixels[(y * width)..<((y + 1) * width)].reduce(0) { $0 + Int($1) }) / Double(width * 255)
        }
    }

    /// На сколько строк профиля сдвинулось содержимое вверх (листаем вниз) и насколько хорошо совпало.
    private static func shift(from a: [Double], to b: [Double]) -> (Int, Double) {
        let n = a.count
        var best = 0
        var bestError = Double.infinity
        for s in 0..<(n * 3 / 4) {
            var error = 0.0
            let count = n - s
            for y in 0..<count { error += abs(b[y] - a[y + s]) }
            error /= Double(count)
            if error < bestError - 0.0005 {
                bestError = error
                best = s
            }
        }
        return (best, bestError)
    }
}

/// Видео из «Фото» — во временный файл.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).\(received.file.pathExtension)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
