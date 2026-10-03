import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case gemini, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .claude: "Claude"
        }
    }
}

struct AIConfig {
    let provider: AIProvider
    let apiKey: String
    let model: String
}

enum AIError: LocalizedError {
    case http(AIProvider, Int, String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .http(let provider, 401, _), .http(let provider, 403, _):
            String(localized: "Неверный API-ключ \(provider.title). Проверьте его в настройках.")
        case .http(let provider, 429, _):
            String(localized: "Превышен лимит \(provider.title) (бесплатный тариф). Подождите минуту и попробуйте снова.")
        case .http(let provider, let code, let message):
            String(localized: "Ошибка \(provider.title) (\(code)): \(message)")
        case .noResult:
            String(localized: "ИИ не вернул ответ.")
        }
    }
}


/// Один запрос к Gemini или Claude, который возвращает JSON-объект по схеме.
/// Gemini — structured output, Claude — принудительный вызов инструмента.
enum AIClient {
    /// Бесплатные модели Gemini часто отвечают 503 «high demand» или 404 — тогда пробуем следующую.
    private static let geminiFallbacks = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.8-flash"]

    /// `schema(true)` — типы заглавными буквами для Gemini, `schema(false)` — JSON Schema для Claude.
    static func object(
        system: String,
        text: String,
        schema: (_ upper: Bool) -> [String: Any],
        toolName: String,
        toolDescription: String,
        config: AIConfig,
        maxTokens: Int = 1024,
        timeout: TimeInterval = 25,
        attachments: [Attachment] = []
    ) async throws -> [String: Any] {
        switch config.provider {
        case .gemini:
            try await gemini(system: system, text: text, schema: schema(true), config: config, timeout: timeout,
                             attachments: attachments)
        case .claude:
            try await claude(system: system, text: text, schema: schema(false), toolName: toolName,
                             toolDescription: toolDescription, config: config, maxTokens: maxTokens, timeout: timeout,
                             attachments: attachments)
        }
    }

    /// Картинка или PDF, которые ИИ читает вместе с текстом (скриншоты и выписки банка).
    struct Attachment {
        let mimeType: String
        let data: Data
    }

    private static func gemini(system: String, text: String, schema: [String: Any], config: AIConfig, timeout: TimeInterval,
                               attachments: [Attachment]) async throws -> [String: Any] {
        let files: [[String: Any]] = attachments.map {
            ["inline_data": ["mime_type": $0.mimeType, "data": $0.data.base64EncodedString()]]
        }
        // Без "role": с ним бесплатный API иногда отвечает пустым 404.
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": files + [["text": text]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": schema,
                "temperature": 0.2,
            ],
        ]
        var models = [config.model.trimmed]
        models += geminiFallbacks.filter { !models.contains($0) }

        var lastError: Error = AIError.noResult
        // Два круга по всем моделям: сбои бесплатного API обычно проходят за секунду.
        for round in 0..<2 {
            if round > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            for model in models where !model.isEmpty {
                let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
                do {
                    let json = try await post(url, body: body, headers: ["x-goog-api-key": config.apiKey.trimmed],
                                              provider: .gemini, timeout: timeout)
                    let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                    let output = parts.compactMap { $0["text"] as? String }.joined()
                    if let data = output.data(using: .utf8),
                       let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        return parsed
                    }
                    lastError = AIError.noResult
                } catch AIError.http(_, let code, let message) where code == 404 || code == 429 || code >= 500 {
                    lastError = AIError.http(.gemini, code, message)
                } catch let error as URLError {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    private static func claude(
        system: String, text: String, schema: [String: Any], toolName: String, toolDescription: String,
        config: AIConfig, maxTokens: Int, timeout: TimeInterval, attachments: [Attachment]
    ) async throws -> [String: Any] {
        let files: [[String: Any]] = attachments.map { file in
            let source: [String: Any] = ["type": "base64", "media_type": file.mimeType, "data": file.data.base64EncodedString()]
            return ["type": file.mimeType == "application/pdf" ? "document" : "image", "source": source]
        }
        let message: Any = files.isEmpty ? text : files + [["type": "text", "text": text]]
        let tool: [String: Any] = ["name": toolName, "description": toolDescription, "input_schema": schema]
        // Haiku поддерживает принудительный вызов инструмента; новые модели требуют "auto".
        let toolChoice: [String: Any] = config.model.contains("haiku")
            ? ["type": "tool", "name": toolName]
            : ["type": "auto"]
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "system": system + "\nAlways answer by calling \(toolName).",
            "tools": [tool],
            "tool_choice": toolChoice,
            "messages": [["role": "user", "content": message]],
        ]
        let json = try await post(
            URL(string: "https://api.anthropic.com/v1/messages")!,
            body: body,
            headers: ["x-api-key": config.apiKey.trimmed, "anthropic-version": "2023-06-01"],
            provider: .claude,
            timeout: timeout
        )
        let content = json["content"] as? [[String: Any]] ?? []
        guard let call = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == toolName }),
              let input = call["input"] as? [String: Any] else {
            throw AIError.noResult
        }
        return input
    }

    private static func post(_ url: URL, body: [String: Any], headers: [String: String], provider: AIProvider, timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? String(localized: "сервис не ответил")
            // Gemini отвечает 400 на неверный ключ — приводим к понятной ошибке.
            let code = provider == .gemini && message.localizedCaseInsensitiveContains("API key") ? 401 : status
            throw AIError.http(provider, code, message)
        }
        return json
    }
}
