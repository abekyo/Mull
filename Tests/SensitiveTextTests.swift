import XCTest
@testable import mull

/// Locks the privacy filter: these must never pass through to an LLM prompt.
///
/// `SensitiveText.isSensitive` is the single gate on every egress path in the app
/// — MullEngine, MCPServer (`search`, `get_relevant`, `read_file`),
/// KnowledgeExtractor, Selection, CurrentState, LiveContextGenerator,
/// NarrativeEngine, ReportWriter, ColdReadService, DeliberationEngine. There is no
/// second net behind it. A rule that quietly stops matching does not fail anywhere
/// visible; it just starts shipping the user's credentials to a third party. Hence
/// one test per rule, named after the rule, rather than a handful of grab-bags.
///
/// The final section pins the KNOWN GAPS. Those tests assert today's *leaky*
/// behaviour on purpose, in the same spirit as RedactorTests:202 — so that
/// tightening the filter breaks a test with a comment explaining what the old
/// boundary was, instead of passing silently and leaving nobody any wiser about
/// what changed.
final class SensitiveTextTests: XCTestCase {

    // MARK: - isSensitive rules, one at a time (SensitiveText.swift:32-54)

    func testFlagsEmailAddresses() {
        XCTAssertTrue(SensitiveText.isSensitive("contact me at jane@example.com"))
        XCTAssertTrue(SensitiveText.isSensitive("jane.doe+tag@sub.example.co.jp"))
    }

    func testDoesNotFlagAnAtSignThatIsNotAnAddress() {
        // Handles and decorators are everywhere in real captured text; treating
        // every "@" as an address would blank most of the vault.
        XCTAssertFalse(SensitiveText.isSensitive("cc @jane about the release"))
        XCTAssertFalse(SensitiveText.isSensitive("@MainActor final class AppState"))
    }

    func testFlagsHTTPURLs() {
        // URLs carry tokens in query strings, and a bare URL is itself a
        // behavioural disclosure (which wishlist, which patient portal).
        XCTAssertTrue(SensitiveText.isSensitive("https://example.com/secret?token=xyz"))
        XCTAssertTrue(SensitiveText.isSensitive("see http://internal.corp/wiki"))
        XCTAssertTrue(SensitiveText.isSensitive("HTTPS://EXAMPLE.COM"), "the check is case-insensitive")
    }

    func testFlagsZoomJoinLinks() {
        XCTAssertTrue(SensitiveText.isSensitive("zoom.us/j/1234567890"))
    }

    func testFlagsMeetingIDWithPasscode() {
        // Both halves are required — see the ID-only case in the gaps section.
        XCTAssertTrue(SensitiveText.isSensitive("Meeting ID: 123 456 7890\nPasscode: 9021"))
    }

    func testFlagsJoinZoomMeetingBoilerplate() {
        XCTAssertTrue(SensitiveText.isSensitive("Join Zoom Meeting"))
    }

    func testFlagsPasswordAndPasscodeLabels() {
        XCTAssertTrue(SensitiveText.isSensitive("password: hunter2"))
        XCTAssertTrue(SensitiveText.isSensitive("Passcode: 4821"))
    }

    func testFlagsAPIKeyLabels() {
        XCTAssertTrue(SensitiveText.isSensitive("api_key = abc"))
        XCTAssertTrue(SensitiveText.isSensitive("APIKEY=abc"))
        XCTAssertTrue(SensitiveText.isSensitive("secret_key: abc"))
    }

    func testFlagsBearerAndTokenLabels() {
        // Note the trailing space in the "bearer " rule: it is what keeps the word
        // "bearer" in ordinary prose from tripping the filter on its own.
        XCTAssertTrue(SensitiveText.isSensitive("Authorization: bearer abc"))
        XCTAssertTrue(SensitiveText.isSensitive("token: abc123"))
    }

    func testFlagsPEMBlockHeaders() {
        XCTAssertTrue(SensitiveText.isSensitive("-----BEGIN PRIVATE KEY-----"))
        XCTAssertTrue(SensitiveText.isSensitive("-----BEGIN CERTIFICATE-----"))
    }

    func testPEMHeaderIsCaseSensitiveUnlikeTheLabelRules() {
        // `text.contains("-----BEGIN")` runs against the raw string, not `lower`.
        // Real PEM is always uppercase, so this is fine — recorded here so the
        // asymmetry with the rules above is deliberate rather than a surprise.
        XCTAssertFalse(SensitiveText.isSensitive("-----begin private key-----"))
    }

    func testFlagsCreditCardNumbers() {
        XCTAssertTrue(SensitiveText.isSensitive("card 4242 4242 4242 4242"))
        XCTAssertTrue(SensitiveText.isSensitive("4242-4242-4242-4242"))
        XCTAssertTrue(SensitiveText.isSensitive("4242424242424242"))
    }

    func testDoesNotFlagShortDigitRuns() {
        XCTAssertFalse(SensitiveText.isSensitive("build 4242 finished in 128s"))
    }

    // MARK: - Credential shapes inherited from Redactor.patterns

    func testFlagsBareOpenAIAnthropicStyleKey() {
        XCTAssertTrue(SensitiveText.isSensitive("sk-ant-api03-AbCdEfGhIjKlMnOpQrSt"))
    }

    func testFlagsGitHubPersonalAccessTokens() {
        XCTAssertTrue(SensitiveText.isSensitive("ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123"))
        XCTAssertTrue(SensitiveText.isSensitive("gho_AbCdEfGhIjKlMnOpQrStUvWxYz0123"))
    }

    func testFlagsSlackTokens() {
        XCTAssertTrue(SensitiveText.isSensitive("xoxb-123456789012-abcdefghijkl"))
        XCTAssertTrue(SensitiveText.isSensitive("xoxp-123456789012-abcdefghijkl"))
    }

    func testFlagsAWSAccessKeyIDs() {
        XCTAssertTrue(SensitiveText.isSensitive("AKIAIOSFODNN7EXAMPLE"))
    }

    func testFlagsBearerTokensByShape() {
        XCTAssertTrue(SensitiveText.isSensitive("Bearer AbCdEfGhIjKlMnOpQrStUvWx"))
    }

    func testFlagsJWTs() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertTrue(SensitiveText.isSensitive(jwt))
    }

    func testFlagsLongHexRuns() {
        // 40 hex chars — a git SHA, a session token, an HMAC. Indistinguishable
        // from each other, so all of them are withheld.
        XCTAssertTrue(SensitiveText.isSensitive("a94a8fe5ccb19ba61c4c0873d391e987982fbbd3"))
    }

    func testShapeRulesAreDelegatedToRedactorNotDuplicated() {
        // The relationship the comment at SensitiveText.swift:48-50 describes:
        // anything Redactor calls credential-shaped is sensitive, by construction.
        // If these ever diverge, one of the two files has grown its own copy of the
        // patterns and they will drift.
        for sample in ["sk-ant-api03-AbCdEfGhIjKlMnOpQrSt",
                       "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123",
                       "AKIAIOSFODNN7EXAMPLE"] {
            XCTAssertTrue(Redactor.containsSecret(sample))
            XCTAssertTrue(SensitiveText.isSensitive(sample))
        }
    }

    // MARK: - Ordinary text must survive

    func testAllowsOrdinaryEnglishWorkNotes() {
        XCTAssertFalse(SensitiveText.isSensitive("Refactored the ChartViewModel bindings"))
        XCTAssertFalse(SensitiveText.isSensitive("Met with the design team about onboarding"))
    }

    func testAllowsOrdinaryJapaneseText() {
        XCTAssertFalse(SensitiveText.isSensitive("買い物リストを作った"))
        XCTAssertFalse(SensitiveText.isSensitive("15時からFX事業のCSミーティング"))
    }

    func testAllowsCodeThatMerelyMentionsAuth() {
        // "authToken" has no colon and no credential shape. Over-matching here
        // would drop most of a developer's captured text, which is the whole
        // corpus mull exists to summarise.
        XCTAssertFalse(SensitiveText.isSensitive("guard let authToken else { return }"))
    }

    func testAllowsEmptyString() {
        // The MCP filters call this with `textContent ?? ""` on every row.
        XCTAssertFalse(SensitiveText.isSensitive(""))
    }

    // MARK: - Japanese text carrying a secret

    func testFlagsJapaneseTextContainingASecret() {
        // Mixed-script capture is the common case for this user, and the rules are
        // substring/regex based rather than word based — confirm no tokenisation
        // assumption sneaks in that would let a key hide between kana.
        XCTAssertTrue(SensitiveText.isSensitive("APIキーは sk-ant-api03-AbCdEfGhIjKlMnOpQrSt です"))
        XCTAssertTrue(SensitiveText.isSensitive("パスワードは password: hunter2 だった"))
        XCTAssertTrue(SensitiveText.isSensitive("請求先は tanaka@example.co.jp に送った"))
        XCTAssertTrue(SensitiveText.isSensitive("資料は https://example.com/内部資料 にあります"))
    }

    // MARK: - Fail-safe

    func testCompiledPatternsAreLiveSoTheFailSafeIsNotSilentlyEngaged() {
        // `matches()` returns TRUE when its NSRegularExpression is nil — a
        // deliberate fail-safe (SensitiveText.swift:26-29): a filter that cannot
        // run must refuse everything rather than wave everything through.
        //
        // The patterns are `private static let`s built from constant literals, so
        // there is no seam to inject a broken one. What IS observable is the
        // fail-safe's shadow: if either regex had failed to compile, the email and
        // credit-card rules would return true for EVERY input and this plain
        // sentence would come back sensitive. A green assertion here therefore
        // proves both patterns compiled and the fail-safe is dormant — which is
        // exactly the fact the rest of this file's negative tests depend on.
        XCTAssertFalse(SensitiveText.isSensitive("plain text with no secret in it"),
                       "either a rule over-matches, or a pattern failed to compile and the "
                       + "fail-safe is now flagging everything")
    }

    // MARK: - KNOWN GAPS
    //
    // Everything below asserts what the filter does TODAY, and today it leaks.
    // These are not desired properties. They are pinned so that (a) nobody
    // rediscovers them by finding the data in an LLM transcript, and (b) whoever
    // closes one gets a failing test pointing at the note explaining the old
    // behaviour, instead of a silent pass. Flip the assertion when you fix it.

    func testGapUnlabelledPasswordIsNotDetected() {
        // GAP, not a property. "password:" with a colon is caught; the same secret
        // written the way people actually write it is not, because "hunter2" has no
        // distinctive shape — there is nothing to match on. Closing this needs a
        // proximity rule ("password/pw/パスワード within N chars of a short token"),
        // which will cost false positives.
        XCTAssertFalse(SensitiveText.isSensitive("my password is hunter2"))
        XCTAssertFalse(SensitiveText.isSensitive("pw hunter2"))
        XCTAssertFalse(SensitiveText.isSensitive("hunter2"))
    }

    func testGapGoogleAPIKeyIsNotDetected() {
        // GAP, not a property. AIza-prefixed Google API keys are a well-known,
        // easily-matched shape (`AIza[0-9A-Za-z_-]{35}`) that Redactor.patterns
        // simply does not list. A key pasted from the Cloud console goes to the LLM.
        XCTAssertFalse(SensitiveText.isSensitive("AIzaSyD-1234567890abcdefghijklmnopqrstuvw"))
    }

    func testGapStripeKeysAreNotDetected() {
        // GAP, not a property. The `sk-` pattern requires a HYPHEN; Stripe uses an
        // underscore, so sk_live_/rk_live_/pk_live_ all slip past. A live Stripe
        // secret key is about as bad as this gets.
        XCTAssertFalse(SensitiveText.isSensitive("rk_live_51AbCdEfGhIjKlMnOpQrStUvWx"))
        XCTAssertFalse(SensitiveText.isSensitive("sk_live_51AbCdEfGhIjKlMnOpQrStUvWx"))
    }

    func testGapHexBelowFortyCharsIsNotDetected() {
        // GAP, not a property. The long-hex rule starts at 40 to avoid eating git
        // short SHAs and colour codes, so a 32-char MD5-shaped secret — the exact
        // length of many legacy API keys and session IDs — passes.
        XCTAssertFalse(SensitiveText.isSensitive("9e107d9d372bb6826bd81d3542a419d6"))
        XCTAssertFalse(SensitiveText.isSensitive("deadbeefdeadbeefdeadbeefdeadbeef"))
    }

    func testGapMeetingIDWithoutThePasscodeWordIsNotDetected() {
        // GAP, not a property. The rule requires "meeting id:" AND "passcode"
        // together, so a meeting ID quoted on its own — enough to join many
        // waiting-room-less meetings — is not withheld.
        XCTAssertFalse(SensitiveText.isSensitive("Meeting ID: 123 456 7890"))
    }

    func testGapAppNameAndWindowTitleAreNeverFilteredAtAll() {
        // GAP, not a property, and the widest one here: every caller passes only
        // `event.textContent` through this filter (MCPServer:470, MCPServer:849,
        // Selection.swift:46-48, MullEngine:451). The OTHER columns are emitted
        // beside it unexamined — Selection.Result.line renders "[app] {entity}"
        // straight into the MCP reply, and `entity` is derived from windowTitle.
        //
        // So a window title is a live egress channel with no gate on it, and
        // window titles routinely contain exactly the strings this file exists to
        // withhold: the recipient of a mail draft, a shared-doc URL, a password
        // manager entry name. The strings themselves are detectable — the filter is
        // simply never asked.
        let title = "Compose: contract renewal — jane@example.com — Mail"
        XCTAssertTrue(SensitiveText.isSensitive(title),
                      "the string IS detectable; nothing in the app ever asks about it")
    }
}
