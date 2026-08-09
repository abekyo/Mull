import Foundation

/// One place that turns a provider error into a sentence a person can act on.
///
/// `LLMClient` funnels everything into `mullError.llmFailed(detail)`, where the
/// detail is whatever the provider said — a status line, a JSON blob, or advice
/// aimed at a developer editing `Options.maxTokens`. Printing that raw is how the
/// Home card came to show `"LLM call failed: Claude API: HTTP 401 {\"type\":…"`
/// to someone whose key had expired.
///
/// This lived inside the chat view, where it was written, and only chat could
/// reach it — so every other surface that can fail (the understudy's draft, the
/// nightly summary) fell back to `localizedDescription`. The translation belongs
/// beside the client that produces the errors, not beside one of its callers.
enum LLMFailure {

    /// Human name for a provider id — used in errors and in the "what leaves this
    /// Mac" line, which must never be vaguer than the setting it reports.
    static func providerName(_ id: String) -> String {
        switch id {
        case "off": "No provider"
        case "gemini": "Google Gemini"
        case "claude": "Anthropic Claude"
        case "openai": "OpenAI"
        case "local": "Ollama"
        case "localopenai": "Local server"
        default: id
        }
    }

    /// Turn a provider error into one human sentence, plus whether the fix is to
    /// go and set a provider up.
    ///
    /// Classification is on the message text rather than on typed cases because
    /// most of these originate as strings from the provider's own API. Where a
    /// typed error is available it is matched first.
    static func explain(_ error: Error) -> (text: String, needsProvider: Bool) {
        let raw = error.localizedDescription
        let d = raw.lowercased()
        let provider = providerName(UserDefaults.standard.string(forKey: "llmProvider") ?? "off")

        // Configuration — no provider, no key, or a provider id nothing answers to.
        if d.contains("llm is off") || d.contains("unknown llm provider") {
            return ("No AI provider is switched on. Ollama and LM Studio run on this Mac.", true)
        }
        if d.contains("no api key") || d.contains("missing api key") {
            return ("\(provider) needs an API key before it can answer.", true)
        }
        // The keychain refused to hand over a key that may well be there. Distinct
        // from "no key": telling this user to enter one sends them in a circle.
        if d.contains("keychain") {
            return (raw, false)
        }
        // Authentication — the key is there and the provider rejected it.
        if d.contains("http 401") || d.contains("http 403") || d.contains("invalid_api_key")
            || d.contains("authentication") || d.contains("unauthorized") {
            return ("\(provider) rejected the API key — keys expire and get revoked.", true)
        }
        // Rate limit / capacity.
        if d.contains("http 429") || d.contains("rate limit") || d.contains("quota")
            || d.contains("is busy") || d.contains("overloaded") {
            return ("\(provider) is rate-limiting this account right now. Wait a minute, or "
                    + "use a different provider.", false)
        }
        // Reachability — offline, or a local server that isn't up.
        if d.contains("no internet") || d.contains("not running") || d.contains("cannot connect")
            || d.contains("no local server") || d.contains("cannot find host") {
            return ("Couldn't reach \(provider). \(raw.hasSuffix(".") ? raw : raw + ".")", false)
        }
        // Timeout.
        if d.contains("timed out") || d.contains("timeout") {
            return ("\(provider) didn't answer in time. Ask something narrower — a week of "
                    + "activity rides along with every question.", false)
        }
        // Budget exhaustion, phrased for someone who cannot edit maxTokens.
        if d.contains("token budget") || d.contains("maxtokens") || d.contains("max_tokens")
            || d.contains("token limit") {
            return ("\(provider) used up the reply budget before writing anything. Ask for one "
                    + "thing at a time — a narrower question leaves room for the answer.", false)
        }
        // Content policy.
        if d.contains("policy") || d.contains("content filter") || d.contains("blocked")
            || d.contains("safety") {
            return ("\(provider) declined to answer this one on content-policy grounds.", false)
        }
        // Server-side trouble — 5xx and the empty/no-text shapes.
        if d.contains("http 5") || d.contains("returned no text") || d.contains("empty response") {
            return ("\(provider) had trouble on its end and sent nothing back.", false)
        }
        return ("\(provider) couldn't answer that. Another provider may do better.", false)
    }
}
