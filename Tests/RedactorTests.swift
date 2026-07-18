import XCTest
@testable import mull

/// Locks the credential masker. mull records the clipboard, and people copy API keys —
/// so `Redactor` is the last gate before a secret reaches a surface that *displays* it
/// (Home project cards, calendar popovers) or an LLM prompt that *learns* from it
/// (voice samples). A regression here is not a cosmetic bug: it leaks a live credential
/// into a screenshot or an outbound request. These tests pin down (a) that every pattern
/// shape is actually recognised, (b) that `mask` terminates and masks *every* secret in a
/// string rather than just the first, and (c) exactly where Redactor's coverage STOPS —
/// the boundary with `SensitiveText`, which is why ReportWriter was moved off Redactor.
final class RedactorTests: XCTestCase {

    // MARK: - Pattern coverage
    //
    // One assertion per regex in Redactor.patterns. If a pattern is ever removed or
    // its length bound is loosened, exactly one of these fails and names the shape.

    func testDetectsOpenAIStyleKey() {
        // sk- followed by 16+ key chars. Anthropic keys share this prefix.
        XCTAssertTrue(Redactor.containsSecret("sk-abcdef1234567890ABCDEF"))
    }

    func testDetectsGitHubPersonalAccessTokens() {
        // Both the classic `ghp_` and the OAuth `gho_` prefixes, 20+ alphanumerics.
        XCTAssertTrue(Redactor.containsSecret("ghp_A1b2C3d4E5f6G7h8I9j0K1L2"))
        XCTAssertTrue(Redactor.containsSecret("gho_A1b2C3d4E5f6G7h8I9j0K1L2"))
    }

    func testDetectsSlackTokens() {
        // xox[baprs]- — the bot/app/user/refresh/… variants all share the shape.
        XCTAssertTrue(Redactor.containsSecret("xoxb-123456789012-abcdefghijkl"))
        XCTAssertTrue(Redactor.containsSecret("xoxp-123456789012-abcdefghijkl"))
    }

    func testDetectsAWSAccessKeyID() {
        // AKIA + exactly 16 uppercase alphanumerics.
        XCTAssertTrue(Redactor.containsSecret("AKIAIOSFODNN7EXAMPLE"))
    }

    func testDetectsBearerToken() {
        // `Bearer` + whitespace + 20 or more token characters. Case-sensitive by design.
        XCTAssertTrue(Redactor.containsSecret("Authorization: Bearer abcdefghij0123456789xyz"))
    }

    func testDetectsJWT() {
        // eyJ (base64 of `{"`) + 40 or more JWT-legal characters.
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0"
        XCTAssertTrue(Redactor.containsSecret(jwt))
    }

    func testDetectsLongHexRun() {
        // 40+ hex characters on a word boundary — session tokens, sha-like secrets.
        XCTAssertTrue(Redactor.containsSecret(String(repeating: "a1b2", count: 12)))
    }

    // MARK: - mask() shape

    func testMaskPreservesFirstSixCharactersOnly() {
        let masked = Redactor.mask("sk-abcdef1234567890ABCDEF")
        // The 6-char prefix is deliberately kept so a human can still tell *which*
        // key was involved without the key being usable.
        XCTAssertEqual(masked, "sk-abc…(hidden)")
    }

    func testMaskLeavesSurroundingProseIntact() {
        let masked = Redactor.mask("My key is sk-abcdef1234567890ABCDEF and it expires Friday")
        XCTAssertTrue(masked.hasPrefix("My key is "))
        XCTAssertTrue(masked.hasSuffix(" and it expires Friday"))
        // The tail of the secret is gone.
        XCTAssertFalse(masked.contains("1234567890ABCDEF"))
    }

    func testMaskedOutputContainsNoSecret() {
        // The whole point: whatever comes out of mask() must itself be clean.
        let masked = Redactor.mask("ghp_A1b2C3d4E5f6G7h8I9j0K1L2")
        XCTAssertFalse(Redactor.containsSecret(masked))
    }

    // MARK: - Termination with multiple secrets
    //
    // `mask` loops `while let match = regex.firstMatch(...)` per pattern. That only
    // terminates because the replacement ("…(hidden)") cannot itself re-match the
    // pattern that produced it. If someone widens a pattern so the masked form still
    // matches, this test hangs instead of failing — which is the loudest possible
    // signal that the invariant broke.

    func testMaskHandlesMultipleSecretsOfTheSameShape() {
        let text = "first sk-aaaaaaaaaaaaaaaaaaaa then sk-bbbbbbbbbbbbbbbbbbbb done"
        let masked = Redactor.mask(text)

        XCTAssertFalse(masked.contains("aaaaaaaaaaaaaaaaaaaa"))
        XCTAssertFalse(masked.contains("bbbbbbbbbbbbbbbbbbbb"))
        // Both were replaced, not just the first match.
        XCTAssertEqual(masked.components(separatedBy: "…(hidden)").count - 1, 2)
        XCTAssertTrue(masked.hasPrefix("first "))
        XCTAssertTrue(masked.hasSuffix(" done"))
    }

    func testMaskHandlesMultipleSecretsOfDifferentShapes() {
        let text = """
        openai=sk-abcdef1234567890ABCDEF
        github=ghp_A1b2C3d4E5f6G7h8I9j0K1L2
        aws=AKIAIOSFODNN7EXAMPLE
        slack=xoxb-123456789012-abcdefghijkl
        """
        let masked = Redactor.mask(text)

        // Every distinct shape got masked in a single pass over the patterns.
        XCTAssertFalse(masked.contains("abcdef1234567890ABCDEF"))
        XCTAssertFalse(masked.contains("A1b2C3d4E5f6G7h8I9j0K1L2"))
        XCTAssertFalse(masked.contains("IOSFODNN7EXAMPLE"))
        XCTAssertFalse(masked.contains("123456789012-abcdefghijkl"))
        // And the result is fully clean — no shape survived another shape's rewrite.
        XCTAssertFalse(Redactor.containsSecret(masked))
        // The non-secret scaffolding (the `key=` labels) is untouched.
        XCTAssertTrue(masked.contains("openai="))
        XCTAssertTrue(masked.contains("slack="))
    }

    func testMaskOfAlreadyMaskedTextIsStable() {
        // Not a strict idempotence guarantee (the 6-char prefix means a second pass
        // could in principle re-trim), but masked output must survive a second pass
        // unchanged, since surfaces sometimes mask defensively more than once.
        let once = Redactor.mask("token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTYifQ")
        let twice = Redactor.mask(once)
        XCTAssertEqual(once, twice)
    }

    // MARK: - Ordinary text is untouched
    //
    // False positives are their own failure mode: an over-eager Redactor turns real
    // work notes into "…(hidden)" soup and makes the surfaces useless.

    func testLeavesEnglishProseAlone() {
        let text = "Refactored the ChartViewModel bindings and shipped the calendar month view"
        XCTAssertFalse(Redactor.containsSecret(text))
        XCTAssertEqual(Redactor.mask(text), text)
    }

    func testLeavesJapaneseProseAlone() {
        let text = "今日はカレンダーの月表示を実装して、設定画面のリファクタリングを進めた"
        XCTAssertFalse(Redactor.containsSecret(text))
        XCTAssertEqual(Redactor.mask(text), text)
    }

    func testLeavesShortGitShaAlone() {
        // A 7-char short sha is hex, but the long-hex pattern requires 40+, so
        // ordinary git output does not get shredded.
        let text = "fixed in 23df891 on the selection-layer branch"
        XCTAssertFalse(Redactor.containsSecret(text))
        XCTAssertEqual(Redactor.mask(text), text)
    }

    func testLeavesTheWordBearerAlone() {
        // The Bearer pattern needs a 20+ char token after it; the English word in a
        // sentence must not trip it.
        let text = "the bearer of bad news arrived before lunch"
        XCTAssertFalse(Redactor.containsSecret(text))
        XCTAssertEqual(Redactor.mask(text), text)
    }

    func testLeavesEmptyStringAlone() {
        XCTAssertFalse(Redactor.containsSecret(""))
        XCTAssertEqual(Redactor.mask(""), "")
    }

    // MARK: - KNOWN LIMITATION: the Redactor / SensitiveText boundary
    //
    // Redactor knows ONE thing: credential-*shaped* strings (prefixed keys, bearer
    // tokens, JWTs, long hex). It deliberately does NOT know about personal data —
    // emails, credit card numbers, `password:` labels, PEM blocks. `SensitiveText`
    // is the gate for those, and it happens to call Redactor as one of its checks
    // (SensitiveText.swift:50), so the relationship is one-directional:
    //
    //     SensitiveText.isSensitive  ⊃  Redactor.containsSecret
    //
    // This is exactly why ReportWriter was switched OFF Redactor: masking a report
    // with Redactor alone would have let an email address or a card number through.
    //
    // The tests below assert BOTH halves of each case on purpose. If someone
    // "improves" Redactor to catch emails, the `XCTAssertFalse` here fails loudly and
    // they must consciously decide to move the boundary — rather than silently
    // changing what callers of `containsSecret` are guaranteed. Do not relax one of
    // these assertions without re-reading which callers depend on which gate.

    func testRedactorDoesNotDetectEmailAddressesButSensitiveTextDoes() {
        let text = "contact me at jane@example.com"
        XCTAssertFalse(Redactor.containsSecret(text),
                       "Redactor is credential-shape only — emails are SensitiveText's job")
        XCTAssertEqual(Redactor.mask(text), text, "…and mask() therefore leaves the email visible")
        XCTAssertTrue(SensitiveText.isSensitive(text))
    }

    func testRedactorDoesNotDetectCreditCardNumbersButSensitiveTextDoes() {
        let text = "card 4242 4242 4242 4242"
        XCTAssertFalse(Redactor.containsSecret(text))
        XCTAssertEqual(Redactor.mask(text), text)
        XCTAssertTrue(SensitiveText.isSensitive(text))
    }

    func testRedactorDoesNotDetectPasswordLabelsButSensitiveTextDoes() {
        // A labelled password has no distinctive *shape* — "hunter2" is just a word.
        let text = "password: hunter2"
        XCTAssertFalse(Redactor.containsSecret(text))
        XCTAssertEqual(Redactor.mask(text), text)
        XCTAssertTrue(SensitiveText.isSensitive(text))
    }

    func testRedactorDoesNotDetectPEMHeaderButSensitiveTextDoes() {
        // The header line itself contains no key material, so no pattern fires.
        // (The base64 body that follows would trip the long-hex/JWT patterns only
        // by coincidence — the header is the reliable marker, and SensitiveText owns it.)
        let text = "-----BEGIN PRIVATE KEY-----"
        XCTAssertFalse(Redactor.containsSecret(text))
        XCTAssertEqual(Redactor.mask(text), text)
        XCTAssertTrue(SensitiveText.isSensitive(text))
    }

    func testEverythingRedactorCatchesSensitiveTextAlsoCatches() {
        // The containment direction that callers rely on: SensitiveText is strictly
        // the wider gate. If this ever fails, some path that trusted isSensitive as
        // the superset is now letting a raw credential through.
        let credentials = [
            "sk-abcdef1234567890ABCDEF",
            "ghp_A1b2C3d4E5f6G7h8I9j0K1L2",
            "gho_A1b2C3d4E5f6G7h8I9j0K1L2",
            "xoxb-123456789012-abcdefghijkl",
            "AKIAIOSFODNN7EXAMPLE",
            "Bearer abcdefghij0123456789xyz",
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0",
            String(repeating: "a1b2", count: 12),
        ]
        for credential in credentials {
            XCTAssertTrue(Redactor.containsSecret(credential), "Redactor missed: \(credential)")
            XCTAssertTrue(SensitiveText.isSensitive(credential), "SensitiveText missed: \(credential)")
        }
    }
}
