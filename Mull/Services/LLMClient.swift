import Foundation

/// Shared access to whichever LLM provider the user selected in Settings → AI.
///
/// This is the single place mull talks to an LLM. The nightly consolidation
/// (`MullEngine`), the periodic deliberation (`DeliberationEngine`), and the
/// scoped chat panel all go through here so provider selection, key handling,
/// and error semantics stay consistent.
///
/// All processing that needs an LLM is the "deliberate" tier — it is allowed to
/// be slow and cloud-backed. The always-on 60s tier stays rule-based and never
/// touches this class.
final class LLMClient {

    struct Options {
        var maxTokens: Int = 4096
        /// Per-request timeout. `nil` uses the provider's own default
        /// (longer for local Ollama, which can be slow on big models).
        var timeout: TimeInterval?

        init(maxTokens: Int = 4096, timeout: TimeInterval? = nil) {
            self.maxTokens = maxTokens
            self.timeout = timeout
        }
    }

    /// The provider id currently selected in Settings → AI.
    /// Defaults to "off" so a fresh install never sends data off-device until
    /// the user opts into a cloud provider.
    var provider: String {
        UserDefaults.standard.string(forKey: "llmProvider") ?? "off"
    }

    /// Send a single-turn completion to the selected provider.
    /// - Parameters:
    ///   - system: optional system instruction. Used to scope the chat panel
    ///     ("you re-process mull data, you are not a general chatbot") and to
    ///     constrain deliberation output formats.
    ///   - prompt: the user prompt.
    ///   - onToken: optional live-token callback. When set, providers that can stream
    ///     (Claude / OpenAI / local OpenAI / Ollama) deliver text incrementally; the
    ///     full text is still returned at the end. Gemini falls back to one emission.
    ///     Tokens arrive on a background thread — hop to MainActor before touching UI.
    func complete(system: String? = nil,
                  prompt: String,
                  options: Options = .init(),
                  onToken: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let response: String
        switch provider {
        case "off":
            // No cloud processing. Callers (nightly summary, deliberation) fall
            // back to rule-based; the chat surfaces this message.
            throw mullError.llmFailed("LLM is off. Enable a provider in Settings → AI to allow processing.")
        case "gemini":
            response = try await callGemini(system: system, prompt: prompt, options: options)
            if let onToken { onToken(response) }   // no streaming endpoint wired — emit once
        case "claude":
            response = try await callClaude(system: system, prompt: prompt, options: options, onToken: onToken)
        case "openai":
            response = try await callOpenAI(system: system, prompt: prompt, options: options, onToken: onToken)
        case "local":
            response = try await callOllama(system: system, prompt: prompt, options: options, onToken: onToken)
        case "localopenai":
            response = try await callLocalOpenAI(system: system, prompt: prompt, options: options, onToken: onToken)
        default:
            throw mullError.llmFailed("Unknown LLM provider '\(provider)'. Pick one in Settings → AI.")
        }

        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw mullError.llmFailed("LLM returned empty response. Check your API key or model.")
        }
        return response
    }

    // MARK: - HTTP transport

    /// A non-2xx reply, kept structured so each provider can translate the status
    /// into its own advice (Gemini's shared-key 429 hint, for example) instead of
    /// every path re-deriving it from a string.
    private struct HTTPFailure: Error {
        let status: Int
        let detail: String
    }

    /// Perform a non-streaming request, checking the HTTP status and retrying
    /// transient failures.
    ///
    /// Every non-streaming path used to destructure `(data, _)` and throw the
    /// URLResponse away. A 429, or a 502 whose body is an HTML gateway page, then
    /// failed the JSON parse, produced no `error.message`, returned "", and
    /// surfaced as "LLM returned empty response. Check your API key or model." —
    /// the one message guaranteed to send the user looking in the wrong place.
    ///
    /// 429 and 5xx are retried with exponential backoff (capped), honouring
    /// `Retry-After` when the server sends one. Streaming paths don't retry: the
    /// caller has already received tokens by the time most failures show up.
    private func send(_ request: URLRequest) async throws -> Data {
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            if (200...299).contains(http.statusCode) { return data }

            let transient = http.statusCode == 429 || (500...599).contains(http.statusCode)
            if transient && attempt < maxAttempts {
                // Retry-After is seconds (or an HTTP date, which we don't chase —
                // falling back to the backoff is fine and never waits longer).
                let hinted = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
                let delay = min(hinted ?? pow(2, Double(attempt - 1)), 30)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            throw HTTPFailure(status: http.statusCode, detail: Self.errorDetail(data))
        }
        throw HTTPFailure(status: 0, detail: "request failed after \(maxAttempts) attempts")
    }

    /// Pull the useful part out of an error body: providers return JSON with an
    /// `error.message`, but a gateway 502 returns HTML — show a prefix of it
    /// rather than nothing at all.
    private static func errorDetail(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let message = err["message"] as? String {
            return message
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    /// Appended when a provider stopped at the token ceiling. The silence was the
    /// bug: a report cut off mid-sentence came back looking complete, so nothing
    /// downstream — and no reader — could tell it wasn't the whole thought.
    private static let truncationNotice =
        "\n\n[mull: cut off at the token limit — this response is incomplete.]"

    // MARK: - Gemini

    /// Call Google Gemini API (free tier).
    /// Uses the user's own key if set, otherwise falls back to the bundled key.
    private func callGemini(system: String?, prompt: String, options: Options) async throws -> String {
        let userKey = KeychainService.loadKey("gemini_api_key") ?? ""
        let apiKey = userKey.isEmpty ? BundledKeys.gemini : userKey

        guard !apiKey.isEmpty else {
            throw mullError.missingAPIKey("Gemini")
        }

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)") else {
            throw mullError.llmFailed("Invalid Gemini API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.timeout ?? 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "maxOutputTokens": options.maxTokens
            ]
        ]
        if let system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            data = try await send(request)
        } catch let failure as HTTPFailure {
            // Rate limits carry different advice depending on whose key is in play.
            if failure.status == 429 {
                throw mullError.llmFailed(userKey.isEmpty
                    ? "Gemini is busy. Set your own API key in Settings for unlimited access."
                    : "Gemini rate limit reached. Try again later.")
            }
            throw mullError.llmFailed("Gemini API: HTTP \(failure.status) \(failure.detail)")
        } catch let error as URLError where error.code == .timedOut {
            throw mullError.llmFailed("Gemini API timed out after 120 seconds.")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw mullError.llmFailed("No internet connection.")
        } catch {
            throw mullError.llmFailed("Gemini API request failed: \(error.localizedDescription)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // A 200 can still carry an API-level error object.
        if let errorObj = json?["error"] as? [String: Any] {
            let message = errorObj["message"] as? String ?? "Unknown error"
            throw mullError.llmFailed("Gemini API: \(message)")
        }

        // A prompt blocked before generation returns no candidates at all.
        guard let candidate = (json?["candidates"] as? [[String: Any]])?.first else {
            let blocked = (json?["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw mullError.llmFailed(blocked.map { "Gemini blocked the prompt (\($0))." }
                ?? "Gemini returned no candidates.")
        }
        let finish = candidate["finishReason"] as? String
        let content = candidate["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        let text = parts?.compactMap { $0["text"] as? String }.joined() ?? ""

        // finishReason was never read, so the two ways Gemini legitimately returns
        // zero text — budget exhausted, or a safety stop — both arrived at the
        // generic "check your API key" in `complete`. gemini-2.5-flash thinks by
        // default and thinking tokens come out of maxOutputTokens, so a tight
        // budget really can be spent before a single text part is emitted.
        if text.isEmpty {
            switch finish {
            case "MAX_TOKENS":
                throw mullError.llmFailed(
                    "Gemini spent its entire \(options.maxTokens)-token budget before writing "
                    + "any text (thinking is on by default and shares that budget). Raise maxTokens.")
            case "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST":
                throw mullError.llmFailed("Gemini stopped for policy reasons (finishReason: \(finish ?? "")).")
            default:
                throw mullError.llmFailed(
                    "Gemini returned no text\(finish.map { " (finishReason: \($0))" } ?? "").")
            }
        }
        return finish == "MAX_TOKENS" ? text + Self.truncationNotice : text
    }

    // MARK: - Ollama

    /// Call local Ollama instance. With `onToken`, streams newline-delimited JSON.
    private func callOllama(system: String?, prompt: String, options: Options,
                            onToken: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let model = UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.2"
        guard let url = URL(string: "http://localhost:11434/api/generate") else {
            throw mullError.llmFailed("Invalid Ollama URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.timeout ?? 300 // 5 min — local models can be slow
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": onToken != nil,
            // Ollama has no top-level max-token field — the cap lives in
            // `options.num_predict`. Omitting it meant Options.maxTokens was
            // silently ignored and every generation stopped at the server default
            // (128 tokens), producing reports that just... ended, with no error.
            "options": ["num_predict": options.maxTokens],
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            if let onToken {
                // Streaming: one JSON object per line, text in "response", until "done".
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var bodyText = ""
                    for try await line in bytes.lines { bodyText += line }
                    throw mullError.llmFailed("Ollama: HTTP \(http.statusCode) \(String(bodyText.prefix(200)))")
                }
                var full = ""
                var doneReason: String?
                for try await line in bytes.lines {
                    guard let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let errorMsg = json["error"] as? String {
                        throw mullError.llmFailed("Ollama: \(errorMsg)")
                    }
                    if let piece = json["response"] as? String, !piece.isEmpty {
                        full += piece
                        onToken(piece)
                    }
                    if (json["done"] as? Bool) == true {
                        doneReason = json["done_reason"] as? String
                        break
                    }
                }
                // "length" = stopped at num_predict, not at the end of the thought.
                if doneReason == "length" {
                    onToken(Self.truncationNotice)
                    full += Self.truncationNotice
                }
                return full
            }
            let data = try await send(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let errorMsg = json?["error"] as? String {
                throw mullError.llmFailed("Ollama: \(errorMsg)")
            }
            let text = json?["response"] as? String ?? ""
            return (json?["done_reason"] as? String) == "length" ? text + Self.truncationNotice : text
        } catch let failure as HTTPFailure {
            throw mullError.llmFailed("Ollama: HTTP \(failure.status) \(failure.detail)")
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw mullError.llmFailed("Ollama is not running. Start it with: ollama serve")
        } catch let error as URLError where error.code == .timedOut {
            throw mullError.llmFailed("Ollama timed out. The model may be too large for your hardware.")
        } catch let error as mullError {
            throw error
        } catch {
            throw mullError.llmFailed("Cannot connect to Ollama at localhost:11434. Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Claude

    /// Call Anthropic Claude API. With `onToken`, streams via SSE.
    private func callClaude(system: String?, prompt: String, options: Options,
                            onToken: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let apiKey = KeychainService.loadKey("claude_api_key") else {
            throw mullError.missingAPIKey("Claude")
        }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw mullError.llmFailed("Invalid Claude API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.timeout ?? 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": options.maxTokens,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
        if onToken != nil { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            if let onToken {
                // SSE: text arrives as content_block_delta events with a text_delta.
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var bodyText = ""
                    for try await line in bytes.lines { bodyText += line }
                    throw mullError.llmFailed("Claude API: HTTP \(http.statusCode) \(String(bodyText.prefix(200)))")
                }
                var full = ""
                var stopReason: String?
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: "),
                          let data = line.dropFirst(6).data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if (json["type"] as? String) == "content_block_delta",
                       let delta = json["delta"] as? [String: Any],
                       let piece = delta["text"] as? String, !piece.isEmpty {
                        full += piece
                        onToken(piece)
                    }
                    // The final message_delta carries how generation ended.
                    if (json["type"] as? String) == "message_delta",
                       let delta = json["delta"] as? [String: Any],
                       let stop = delta["stop_reason"] as? String {
                        stopReason = stop
                    }
                    if (json["type"] as? String) == "error",
                       let err = json["error"] as? [String: Any],
                       let message = err["message"] as? String {
                        throw mullError.llmFailed("Claude API: \(message)")
                    }
                }
                if stopReason == "max_tokens" {
                    onToken(Self.truncationNotice)
                    full += Self.truncationNotice
                }
                return full
            }
            let data = try await send(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let errorObj = json?["error"] as? [String: Any], let message = errorObj["message"] as? String {
                throw mullError.llmFailed("Claude API: \(message)")
            }
            // Join every text block rather than taking the first: with extended
            // thinking the first block may not be text at all.
            let blocks = json?["content"] as? [[String: Any]]
            let text = blocks?.compactMap { $0["text"] as? String }.joined() ?? ""
            let stop = json?["stop_reason"] as? String
            if text.isEmpty {
                throw mullError.llmFailed(stop == "max_tokens"
                    ? "Claude spent its entire \(options.maxTokens)-token budget before writing any text. Raise maxTokens."
                    : "Claude returned no text\(stop.map { " (stop_reason: \($0))" } ?? "").")
            }
            return stop == "max_tokens" ? text + Self.truncationNotice : text
        } catch let failure as HTTPFailure {
            throw mullError.llmFailed("Claude API: HTTP \(failure.status) \(failure.detail)")
        } catch let error as URLError where error.code == .timedOut {
            throw mullError.llmFailed("Claude API timed out after 120 seconds.")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw mullError.llmFailed("No internet connection.")
        } catch let error as mullError {
            throw error
        } catch {
            throw mullError.llmFailed("Claude API request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Local (OpenAI-compatible)

    /// Call any local OpenAI-compatible server — LM Studio (default, :1234), Jan,
    /// llama.cpp `server`, vLLM, LocalAI. Same wire format as OpenAI, just a
    /// different base URL and (usually) no real key. Stays on-device.
    private func callLocalOpenAI(system: String?, prompt: String, options: Options,
                                 onToken: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let base = (UserDefaults.standard.string(forKey: "localBaseURL") ?? "http://localhost:1234/v1")
            .trimmingCharacters(in: .whitespaces)
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let model = UserDefaults.standard.string(forKey: "localModel") ?? ""
        guard let url = URL(string: "\(trimmedBase)/chat/completions") else {
            throw mullError.llmFailed("Invalid local server URL: \(trimmedBase)")
        }
        // Most local servers ignore the key; send a harmless dummy unless the user set one.
        let key = KeychainService.loadKey("local_api_key")
        return try await chatCompletions(
            url: url,
            apiKey: (key?.isEmpty == false ? key : "local-no-key"),
            model: model.isEmpty ? "local-model" : model,
            system: system, prompt: prompt, options: options,
            providerLabel: "Local server",
            timeout: options.timeout ?? 300,            // local models can be slow
            connectHint: "No local server at \(trimmedBase). Start LM Studio (Local Server) or your runtime, then load a model.",
            onToken: onToken)
    }

    // MARK: - OpenAI

    /// Call OpenAI API.
    private func callOpenAI(system: String?, prompt: String, options: Options,
                            onToken: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let apiKey = KeychainService.loadKey("openai_api_key") else {
            throw mullError.missingAPIKey("OpenAI")
        }
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw mullError.llmFailed("Invalid OpenAI API URL")
        }
        // gpt-5-mini: best cost/quality for mull's drafting work. The GPT-5 family
        // rejects `max_tokens` (verified) — it requires `max_completion_tokens`, and
        // part of that budget goes to reasoning before any text comes out.
        return try await chatCompletions(
            url: url, apiKey: apiKey, model: "gpt-5-mini",
            system: system, prompt: prompt, options: options,
            providerLabel: "OpenAI API", timeout: options.timeout ?? 120,
            connectHint: "No internet connection.",
            useCompletionTokensParam: true, onToken: onToken)
    }

    /// Shared OpenAI chat-completions transport, used by both the OpenAI cloud API
    /// and any local OpenAI-compatible server (LM Studio et al.).
    /// With `onToken`, requests SSE streaming and emits `choices[].delta.content`.
    private func chatCompletions(url: URL, apiKey: String?, model: String,
                                 system: String?, prompt: String, options: Options,
                                 providerLabel: String, timeout: TimeInterval,
                                 connectHint: String,
                                 useCompletionTokensParam: Bool = false,
                                 onToken: (@Sendable (String) -> Void)? = nil) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [[String: Any]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]
        body[useCompletionTokensParam ? "max_completion_tokens" : "max_tokens"] = options.maxTokens
        if onToken != nil { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            if let onToken {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var bodyText = ""
                    for try await line in bytes.lines { bodyText += line }
                    throw mullError.llmFailed("\(providerLabel): HTTP \(http.statusCode) \(String(bodyText.prefix(200)))")
                }
                var full = ""
                var finishReason: String?
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = line.dropFirst(6)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if let errorObj = json["error"] as? [String: Any], let message = errorObj["message"] as? String {
                        throw mullError.llmFailed("\(providerLabel): \(message)")
                    }
                    let choice = (json["choices"] as? [[String: Any]])?.first
                    if let delta = choice?["delta"] as? [String: Any],
                       let piece = delta["content"] as? String, !piece.isEmpty {
                        full += piece
                        onToken(piece)
                    }
                    // The last chunk for a choice carries finish_reason.
                    if let reason = choice?["finish_reason"] as? String { finishReason = reason }
                }
                if finishReason == "length" {
                    onToken(Self.truncationNotice)
                    full += Self.truncationNotice
                }
                return full
            }
            let data = try await send(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let errorObj = json?["error"] as? [String: Any], let message = errorObj["message"] as? String {
                throw mullError.llmFailed("\(providerLabel): \(message)")
            }
            let choice = (json?["choices"] as? [[String: Any]])?.first
            let finish = choice?["finish_reason"] as? String
            let text = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""

            // gpt-5-mini spends part of max_completion_tokens on reasoning BEFORE
            // any text is emitted, so a tight budget legitimately returns an empty
            // content string with finish_reason "length". That used to fall through
            // to "check your API key" — which is never the actual problem.
            if text.isEmpty {
                switch finish {
                case "length":
                    throw mullError.llmFailed(
                        "\(providerLabel) spent its entire \(options.maxTokens)-token budget before "
                        + "writing any text (reasoning models consume it first). Raise maxTokens.")
                case "content_filter":
                    throw mullError.llmFailed("\(providerLabel) stopped: content filtered.")
                default:
                    throw mullError.llmFailed(
                        "\(providerLabel) returned no text\(finish.map { " (finish_reason: \($0))" } ?? "").")
                }
            }
            return finish == "length" ? text + Self.truncationNotice : text
        } catch let failure as HTTPFailure {
            throw mullError.llmFailed("\(providerLabel): HTTP \(failure.status) \(failure.detail)")
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw mullError.llmFailed(connectHint)
        } catch let error as URLError where error.code == .timedOut {
            throw mullError.llmFailed("\(providerLabel) timed out. The model may be too large for your hardware.")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw mullError.llmFailed("No internet connection.")
        } catch let error as mullError {
            throw error
        } catch {
            throw mullError.llmFailed("\(providerLabel) request failed: \(error.localizedDescription)")
        }
    }
}
