import AVFoundation
import Speech

/// Системное распознавание речи (STT) с живым текстом и автостопом после паузы.
@MainActor
@Observable
final class SpeechRecognizer {
    private(set) var transcript = ""
    private(set) var isRecording = false
    /// 0…1, для анимации кнопки микрофона.
    private(set) var level: Float = 0
    private(set) var error: String?

    /// Сколько тишины после последнего слова завершает запись.
    var silenceTimeout: Duration = .seconds(2)

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var finalContinuation: CheckedContinuation<Void, Never>?

    @ObservationIgnored private var isStarting = false

    func start(localeID: String) async {
        // Повторный запуск поверх идущего ставил второй tap на микрофон — AVAudioEngine падает.
        guard !isStarting, !isRecording else { return }
        isStarting = true
        defer { isStarting = false }
        error = nil
        transcript = ""

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            error = String(localized: "Разрешите распознавание речи в Настройках.")
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = String(localized: "Разрешите доступ к микрофону в Настройках.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            error = String(localized: "Распознавание для языка \(localeID) сейчас недоступно.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            self.request = request

            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            Self.installTap(on: engine.inputNode, request: request) { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
            engine.prepare()
            try engine.start()
            isRecording = true

            task = Self.recognize(recognizer, request: request) { [weak self] text, isFinal, failed in
                Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: failed) }
            }
        } catch {
            self.error = error.localizedDescription
            engine.inputNode.removeTap(onBus: 0)
            teardown()
        }
    }

    /// Останавливает запись и ждёт финальный вариант текста (не дольше секунды).
    func stop() async -> String {
        guard isRecording else { return transcript.trimmed }
        isRecording = false
        silenceTask?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { self.finalContinuation = $0 }
            }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
        resumeFinal()
        teardown()
        return transcript.trimmed
    }

    func cancel() {
        isRecording = false
        silenceTask?.cancel()
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        resumeFinal()
        teardown()
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            transcript = text
            if isRecording { scheduleSilenceStop() }
        }
        if isFinal || failed { resumeFinal() }
        if failed && isRecording {
            // Ошибка распознавания посреди записи — отдаём то, что успели услышать.
            Task { _ = await stop() }
        }
    }

    private func scheduleSilenceStop() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self, silenceTimeout] in
            try? await Task.sleep(for: silenceTimeout)
            guard !Task.isCancelled, let self, self.isRecording else { return }
            _ = await self.stop()
        }
    }

    private func resumeFinal() {
        finalContinuation?.resume()
        finalContinuation = nil
    }

    private func teardown() {
        task = nil
        request = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Колбэки AVAudioEngine и Speech приходят не на главном потоке, поэтому замыкания
    // создаются вне MainActor — иначе Swift проверит изоляцию и уронит приложение.

    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        request: SFSpeechAudioBufferRecognitionRequest,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let rms = (sum / Float(count)).squareRoot()
            onLevel(min(1, rms * 12))
        }
    }

    private nonisolated static func recognize(
        _ recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            onResult(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }
}
