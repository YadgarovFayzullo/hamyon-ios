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

    /// Узбекского распознавания в iOS нет — речь пишется в файл и расшифровывается Gemini.
    static let cloudLocale = "uz-UZ"
    @ObservationIgnored private var cloudConfig: AIConfig?
    @ObservationIgnored private var cloudFile: AVAudioFile?
    @ObservationIgnored private var cloudURL: URL?
    @ObservationIgnored private var cloudHeard = false
    @ObservationIgnored private var cloudWriteError: String?
    @ObservationIgnored private var cloudStarted = Date()
    /// Идёт расшифровка записи в облаке.
    private(set) var isTranscribing = false

    func start(localeID: String, cloud: AIConfig? = nil) async {
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
        if localeID == Self.cloudLocale, let cloud {
            startCloud(config: cloud)
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

    /// Запись для облака: пишем речь в m4a, тишина после слов — стоп.
    private func startCloud(config: AIConfig) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let format = engine.inputNode.outputFormat(forBus: 0)
            let url = FileManager.default.temporaryDirectory.appending(path: "uz-dictation.m4a")
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 48_000 * Int(format.channelCount),
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            cloudFile = file
            cloudURL = url
            cloudConfig = config
            cloudHeard = false
            cloudWriteError = nil
            cloudStarted = Date()

            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            Self.installFileTap(on: engine.inputNode, file: file, onLevel: { [weak self] level in
                Task { @MainActor in self?.cloudLevel(level) }
            }, onFail: { [weak self] message in
                Task { @MainActor in if self?.cloudWriteError == nil { self?.cloudWriteError = message } }
            })
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            self.error = error.localizedDescription
            engine.inputNode.removeTap(onBus: 0)
            cloudFile = nil
            teardown()
        }
    }

    private func cloudLevel(_ value: Float) {
        guard isRecording, cloudConfig != nil else { return }
        level = value
        if value > 0.05 {
            cloudHeard = true
            scheduleSilenceStop()
        } else if !cloudHeard && Date().timeIntervalSince(cloudStarted) > 8 {
            // Никто не заговорил — не держим микрофон вечно.
            Task { _ = await stop() }
        }
    }

    private func transcribeCloud() async -> String {
        guard let config = cloudConfig, let url = cloudURL,
              let data = try? Data(contentsOf: url), data.count > 2000 else {
            let size = cloudURL.flatMap { try? Data(contentsOf: $0).count } ?? -1
            error = "STT: \(cloudWriteError ?? "файл пуст") (\(size) B)"
            return ""
        }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let object = try await AIClient.object(
                system: "You transcribe short voice notes about money (spending, income, debts) by a user in Uzbekistan. "
                    + "The speech is Uzbek, often mixed with Russian words. Write it in Uzbek Latin script (Russian words in Cyrillic), "
                    + "exactly as spoken, with digits for numbers. Return only the transcription; empty string if there is no speech.",
                text: "Transcribe the audio.",
                schema: { upper in
                    ["type": upper ? "OBJECT" : "object",
                     "properties": ["text": ["type": upper ? "STRING" : "string"]],
                     "required": ["text"]]
                },
                toolName: "transcribe", toolDescription: "Расшифровка речи.", config: config, timeout: 40,
                attachments: [.init(mimeType: "audio/mp4", data: data)]
            )
            return (object["text"] as? String)?.trimmed ?? ""
        } catch {
            let e = error as NSError
            self.error = "STT \(data.count) B, \(e.code): \(error.localizedDescription)"
            return ""
        }
    }

    private func finishCloud() async -> String {
        silenceTask?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // m4a дописывается только при закрытии файла — иначе Gemini отвечает 400.
        cloudFile?.close()
        cloudFile = nil
        // Отдельная задача: автостоп по тишине вызывает stop() из silenceTask, и отмена этой задачи рвала бы запрос.
        let text = await Task { await self.transcribeCloud() }.value
        transcript = text
        cloudConfig = nil
        if let cloudURL { try? FileManager.default.removeItem(at: cloudURL) }
        // Запись считается законченной только сейчас — экран ждёт текст, а не пустую строку.
        isRecording = false
        level = 0
        teardown()
        return text
    }

    /// Останавливает запись и ждёт финальный вариант текста (не дольше секунды).
    func stop() async -> String {
        guard isRecording else { return transcript.trimmed }
        if cloudConfig != nil {
            guard !isTranscribing else { return transcript.trimmed }
            return await finishCloud()
        }
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
        cloudConfig = nil
        cloudFile = nil
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

    private nonisolated static func installFileTap(
        on input: AVAudioInputNode,
        file: AVAudioFile,
        onLevel: @escaping @Sendable (Float) -> Void,
        onFail: @escaping @Sendable (String) -> Void
    ) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            do { try file.write(from: buffer) } catch { onFail("запись: \(error.localizedDescription)") }
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            onLevel(min(1, (sum / Float(count)).squareRoot() * 12))
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
