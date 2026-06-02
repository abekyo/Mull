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
    func complete(system: String? = nil,
                  prompt: String,
                  options: Options = .init()) async throws -> String {
        let response: String
        switch provider {
        case "off":
            // No cloud processing. Callers (nightly summary, deliberation) fall
            // back to rule-based; the chat surfaces this message.
            throw mullError.llmFailed("LLM is off. Enable a provider in Settings → AI to allow processing.")
        case "gemini":
            response = try await callGemini(system: system, prompt: prompt, options: options)
        case "claude":
            response = try await callClaude(system: system, prompt: prompt, options: options)
        case "openai":
            response = try await callOpenAI(system: system, prompt: prompt, options: options)
        case "local":
            response = try await callOllama(system: system, prompt: prompt, options: options)
        default:
            throw mullError.llmFailed("Unknown LLM provider '\(provider)'. Pick one in Settings → AI.")
        }

        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw mullError.llmFailed("LLM returned empty response. Check your API key or model.")
        }
        return response
    }

    // MARK: - Gemini

    /// Call Google Gemini API (free tier).
    /// Uses the user's own key if set, otherwise falls back to the bundled key.
    private func callGemini(system: String?, prompt: String, options: Options) async throws -> String {
        let userKey = KeychainService.load(key: "gemini_api_key") ?? ""
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
            (data, _) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw mullError.llmFailed("Gemini API timed out after 120 seconds.")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw mullError.llmFailed("No internet connection.")
        } catch {
            throw mullError.llmFailed("Gemini API request failed: \(error.localizedDescription)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Check for API-level errors (rate limit = 429)
        if let errorObj = json?["error"] as? [String: Any] {
            let code = errorObj["code"] as? Int ?? 0
            let message = errorObj["message"] as? String ?? "Unknown error"
            if code == 429 && !userKey.isEmpty {
                throw mullError.llmFailed("Gemini rate limit reached. Try again later.")
            } else if code == 429 {
                throw mullError.llmFailed("Gemini is busy. Set your own API key in Settings for unlimited access.")
            }
            throw mullError.llmFailed("Gemini API: \(message)")
        }

        let candidates = json?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return parts?.first?["text"] as? String ?? ""
    }

    // MARK: - Ollama

    /// Call local Ollama instance.
    private func callOllama(system: String?, prompt: String, options: Options) async throws -> String {
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
            "stream": false,
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw mullError.llmFailed("Ollama is not running. Start it with: ollama serve")
        } catch let error as URLError where error.code == .timedOut {
            throw mullError.llmFailed("Ollama timed out. The model may be too large for your hardware.")
        } catch {
            throw mullError.llmFailed("Cannot connect to Ollama at localhost:11434. Error: \(error.localizedDescription)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let errorMsg = json?["error"] as? String {
            throw mullError.llmFailed("Ollama: \(errorMsg)")
        }
        return json?["response"] as? String ?? ""
    }

    // MARK: - Claude

    /// Call Anthropic Claude API.
    private func callClaude(system: String?, prompt: String, options: Options) async throws -> String {
        guard let apiKey = KeychainService.load(key: "claude_api_key"), !apiKey.isEmpty else {
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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw mullError.llmFailed("Claude API timed out after 120 seconds.")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw mullError.llmFailed("No internet connection.")
        } catch {
            throw mullError.llmFailed("Claude API request failed: \(error.localizedDescription)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let errorObj = json?["error"] as? [String: Any], let message = errorObj["message"] as? String {
            throw mullError.llmFailed("Claude API: \(message)")
        }

        let content = (json?["content"] as? [[String: Any]])?.first
        return content?["text"] as? String ?? ""
    }

    // MARK: - OpenAI

    /// Call OpenAI API.
    private func callOpenAI(system: String?, prompt: String, options: Options) async throws -> String {
        guard let apiKey = KeychainService.load(key: "openai_api_key"), !apiKey.isEmpty else {
            throw mullError.missingAPIKey("OpenAI")
        }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw mullError.llmFailed("Invalid OpenAI API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.timeout ?? 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: Any]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw mullError.llmFailed("OpenAI API timed out after 120 seconds.")
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw mullError.llmFailed("No internet connection.")
        } catch {
            throw mullError.llmFailed("OpenAI API request failed: \(error.localizedDescription)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let errorObj = json?["error"] as? [String: Any], let message = errorObj["message"] as? String {
            throw mullError.llmFailed("OpenAI API: \(message)")
        }

        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }
}
