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
///
/// **This is also the layer that speaks the reader's language.** What `LLMClient`
/// throws stays English on purpose: `explain` classifies it by matching on that
/// text, so translating the throw sites would leave every failure falling through
/// to the last line here. Those strings are parsed, not read — the same rule that
/// keeps `MarkdownDoc`'s front-matter keys English. The sentence a person actually
/// sees is built below, and that one is in the catalog.
enum LLMFailure {

    /// Human name for a provider id — used in errors and in the "what leaves this
    /// Mac" line, which must never be vaguer than the setting it reports.
    static func providerName(_ id: String) -> String {
        switch id {
        case "off": String(localized: "No provider")
        case "gemini": "Google Gemini"
        case "claude": "Anthropic Claude"
        case "openai": "OpenAI"
        case "local": "Ollama"
        case "localopenai": "Local server"
        default: id
        }
    }

    /// What went wrong, as a value rather than as a sentence.
    ///
    /// `LLMClient` knows this at each `throw` — it is the difference between the
    /// branch it took and the one beside it — and it used to throw the knowledge
    /// away and leave `explain` to recover it by matching English words in the
    /// message. That worked for exactly as long as the messages were English. The
    /// moment they went through the catalog, every Japanese failure fell past all
    /// ten checks and out of the bottom as "couldn't answer that", which is the
    /// least useful sentence here and the only one that says nothing to act on.
    ///
    /// `http` carries the status because one status is several answers: 401 is a
    /// key, 429 is capacity, 5xx is their end.
    enum Kind: Equatable {
        case noProvider, keychain, rateLimit, unreachable, timeout
        case budget, policy, emptyAnswer, unknown
        case http(Int)
    }

    /// Turn a provider error into one human sentence, plus whether the fix is to
    /// go and set a provider up.
    ///
    /// Typed errors first. The text matching below still runs for everything that
    /// reaches here from outside `LLMClient` — `DraftError`, `URLError`, whatever a
    /// future caller throws — and those are still English, so it still works.
    static func explain(_ error: Error) -> (text: String, needsProvider: Bool) {
        let raw = error.localizedDescription
        let d = raw.lowercased()
        let provider = providerName(UserDefaults.standard.string(forKey: "llmProvider") ?? "off")

        if case let mullError.llmFailed(kind, detail) = error {
            return sentence(for: kind, provider: provider, detail: detail)
        }
        if case let mullError.missingAPIKey(name) = error {
            return (String(localized: "\(providerName(name)) needs an API key before it can answer."), true)
        }

        // Configuration — no provider, no key, or a provider id nothing answers to.
        if d.contains("llm is off") || d.contains("unknown llm provider") {
            return (String(localized: "No AI provider is switched on. Ollama and LM Studio run on this Mac."), true)
        }
        if d.contains("no api key") || d.contains("missing api key") {
            return (String(localized: "\(provider) needs an API key before it can answer."), true)
        }
        // The keychain refused to hand over a key that may well be there. Distinct
        // from "no key": telling this user to enter one sends them in a circle.
        if d.contains("keychain") {
            return (raw, false)
        }
        // Authentication — the key is there and the provider rejected it.
        if d.contains("http 401") || d.contains("http 403") || d.contains("invalid_api_key")
            || d.contains("authentication") || d.contains("unauthorized") {
            return (String(localized: "\(provider) rejected the API key — keys expire and get revoked."), true)
        }
        // Rate limit / capacity.
        if d.contains("http 429") || d.contains("rate limit") || d.contains("quota")
            || d.contains("is busy") || d.contains("overloaded") {
            return (String(localized: "\(provider) is rate-limiting this account right now. Wait a minute, or use a different provider."), false)
        }
        // Reachability — offline, or a local server that isn't up.
        if d.contains("no internet") || d.contains("not running") || d.contains("cannot connect")
            || d.contains("no local server") || d.contains("cannot find host") {
            return (String(localized: "Couldn't reach \(provider). \(raw.hasSuffix(".") ? raw : raw + ".")"), false)
        }
        // Timeout.
        if d.contains("timed out") || d.contains("timeout") {
            return (String(localized: "\(provider) didn't answer in time. Ask something narrower — a week of activity rides along with every question."), false)
        }
        // Budget exhaustion, phrased for someone who cannot edit maxTokens.
        if d.contains("token budget") || d.contains("maxtokens") || d.contains("max_tokens")
            || d.contains("token limit") {
            return (String(localized: "\(provider) used up the reply budget before writing anything. Ask for one thing at a time — a narrower question leaves room for the answer."), false)
        }
        // Content policy.
        if d.contains("policy") || d.contains("content filter") || d.contains("blocked")
            || d.contains("safety") {
            return (String(localized: "\(provider) declined to answer this one on content-policy grounds."), false)
        }
        // Server-side trouble — 5xx and the empty/no-text shapes.
        if d.contains("http 5") || d.contains("returned no text") || d.contains("empty response") {
            return (String(localized: "\(provider) had trouble on its end and sent nothing back."), false)
        }
        return (String(localized: "\(provider) couldn't answer that. Another provider may do better."), false)
    }

    /// The same sentences as below, chosen by what happened rather than by what it
    /// was called. `detail` is the client's own message: it is passed through only
    /// where it says something the sentence cannot — a keychain status, the address
    /// of a local server that is not answering.
    private static func sentence(for kind: Kind, provider: String,
                                 detail: String) -> (text: String, needsProvider: Bool) {
        switch kind {
        case .noProvider:
            return (String(localized: "No AI provider is switched on. Ollama and LM Studio run on this Mac."), true)
        case .keychain:
            // Already a full explanation, and telling this person to enter a key
            // they have already entered sends them in a circle.
            return (detail, false)
        case .rateLimit:
            return (String(localized: "\(provider) is rate-limiting this account right now. Wait a minute, or use a different provider."), false)
        case .unreachable:
            return (String(localized: "Couldn't reach \(provider). \(detail.hasSuffix(".") ? detail : detail + ".")"), false)
        case .timeout:
            return (String(localized: "\(provider) didn't answer in time. Ask something narrower — a week of activity rides along with every question."), false)
        case .budget:
            return (String(localized: "\(provider) used up the reply budget before writing anything. Ask for one thing at a time — a narrower question leaves room for the answer."), false)
        case .policy:
            return (String(localized: "\(provider) declined to answer this one on content-policy grounds."), false)
        case .emptyAnswer:
            return (String(localized: "\(provider) had trouble on its end and sent nothing back."), false)
        case .http(let status):
            switch status {
            case 401, 403:
                return (String(localized: "\(provider) rejected the API key — keys expire and get revoked."), true)
            case 429:
                return (String(localized: "\(provider) is rate-limiting this account right now. Wait a minute, or use a different provider."), false)
            case 500...599:
                return (String(localized: "\(provider) had trouble on its end and sent nothing back."), false)
            default:
                return (String(localized: "\(provider) couldn't answer that. Another provider may do better."), false)
            }
        case .unknown:
            return (String(localized: "\(provider) couldn't answer that. Another provider may do better."), false)
        }
    }
}
