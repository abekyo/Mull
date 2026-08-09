import XCTest
@testable import mull

/// Locks the retrieval core of the selection layer (SELECTION-LAYER.md §4).
///
/// `Selection.rank` is the single funnel every agent-facing answer flows through:
/// MCP's `search` / `get_relevant` tools and ProactiveLoop all end up here. It is
/// pure given an event array, so it is cheap to test — and it *must* be tested,
/// because every one of its gates fails silently. A broken filter doesn't crash;
/// it returns fewer rows, and mull answers "No relevant activity" for something
/// you did ten minutes ago. The Japanese bigram tests at the bottom guard exactly
/// that failure, which shipped once already.
///
/// Fixture discipline: a fixed `now` anchors every timestamp so scores are
/// deterministic, and fixture text deliberately avoids `TestInput` filler
/// ("the quick brown fox", "lorem ipsum", "asdf", adjacent single-letter words) —
/// `rank` correctly discards those, so using them as ordinary fixtures would make
/// other assertions pass against an empty array.
final class SelectionTests: XCTestCase {

    /// Fixed anchor. Never `Date()` — recency is a scoring component.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Wide enough that fixture ages stay well inside the recency window.
    private let window: TimeInterval = 7200

    private func event(
        _ text: String,
        ago: TimeInterval = 60,
        eventType: RecordingEvent.EventType = .keystroke,
        app: String? = nil,
        title: String? = nil,
        id: Int64? = nil,
        entity: String? = nil,
        contentType: String? = nil,
        salience: Double? = nil
    ) -> RecordingEvent {
        RecordingEvent(
            id: id,
            timestamp: now.addingTimeInterval(-ago),
            eventType: eventType,
            appName: app,
            windowTitle: title,
            textContent: text,
            entity: entity,
            contentType: contentType,
            salience: salience
        )
    }

    private func rank(
        _ events: [RecordingEvent],
        query: String = "",
        entity: String? = nil,
        anchor: String? = nil,
        type: String? = nil,
        limit: Int = 8
    ) -> [Selection.Result] {
        Selection.rank(events: events, query: query, entity: entity, anchor: anchor,
                       type: type, now: now, since: window, limit: limit)
    }

    private func slice(
        _ events: [RecordingEvent],
        query: String = "",
        entity: String? = nil,
        anchor: String? = nil,
        type: String? = nil,
        limit: Int = 8
    ) -> Selection.Slice {
        Selection.slice(events: events, query: query, entity: entity, anchor: anchor,
                        type: type, now: now, since: window, limit: limit)
    }

    // MARK: - Explicit scope vs implicit anchor
    //
    // The distinction the ranker got wrong for its whole life: `entity` is a
    // request and filters; `anchor` is a guess about what is on screen and only
    // ranks. Collapsing them made the default `search` — the one an agent issues
    // when it has no reason to name a project — blind to every project but the
    // current one, which is the opposite of what "how did I solve this before?"
    // needs. These five tests are the contract.

    func testAnchorRanksButNeverExcludesOtherProjects() {
        let elsewhere = event("fixed the stripe webhook signature by using the raw body",
                              ago: 3600, eventType: .clipboard, title: "Webhook.swift — PaymentsApp")
        let here = event("chart placeholder", eventType: .clipboard, title: "Dash.swift — PantryApp")

        let results = rank([elsewhere, here], query: "stripe webhook", anchor: "PantryApp")

        XCTAssertEqual(results.map(\.text), [elsewhere.textContent],
                       "the anchor is a prior, not a WHERE clause — the answer lives in another project")
    }

    func testExplicitEntityStillExcludesOtherProjects() {
        let mine = event("retry logic rewritten", eventType: .clipboard, title: "Net.swift — Mull")
        let theirs = event("retry logic with exponential backoff", eventType: .clipboard,
                           title: "Net.swift — OtherApp")

        let results = rank([mine, theirs], query: "retry", entity: "Mull")

        XCTAssertEqual(results.map(\.text), [mine.textContent],
                       "naming a project is a request to be confined to it")
    }

    func testAnchorBreaksTiesTowardTheCurrentProject() {
        // The other project's event is NEWER, so recency alone would pick it.
        let other = event("cache layer redesign for the other app", ago: 30,
                          eventType: .clipboard, title: "Cache.swift — OtherApp")
        let anchored = event("cache layer redesign in mull", ago: 90,
                             eventType: .clipboard, title: "Cache.swift — Mull")

        let results = rank([other, anchored], query: "cache redesign", anchor: "Mull", limit: 1)

        XCTAssertEqual(results.map(\.text), [anchored.textContent])
    }

    func testSubstitutesAnchoredSalientActivityWhenNothingMatchesLiterally() {
        // "auth broken" appears nowhere; the event that answers it says "401".
        let answer = event("login returns 401 after the session expires",
                           eventType: .clipboard, title: "Session.swift — PaymentsApp")
        let chatter = event("groceries and dry cleaning", eventType: .clipboard, title: "Errands — Personal")

        let result = slice([answer, chatter], query: "auth broken", anchor: "PaymentsApp")

        XCTAssertEqual(result.results.map(\.text), [answer.textContent])
        XCTAssertTrue(result.substituted,
                      "the caller has to be able to tell the agent these did not match its words")
    }

    func testNoSubstitutionWhenALiteralHitExists() {
        let hit = event("the export csv job times out", eventType: .clipboard, title: "Export.swift — PantryApp")
        let salientNeighbour = event("remember to renew the domain",
                                     eventType: .clipboard, title: "Notes — PantryApp")

        let result = slice([hit, salientNeighbour], query: "export csv", anchor: "PantryApp")

        XCTAssertEqual(result.results.map(\.text), [hit.textContent],
                       "a good match is never padded out with merely-salient neighbours")
        XCTAssertFalse(result.substituted)
    }

    func testNoSubstitutionWithoutAnAnchor() {
        let a = event("URGENT decided to drop the feature", eventType: .clipboard)
        let b = event("quarterly planning notes", eventType: .clipboard)

        let result = slice([a, b], query: "graphql")

        XCTAssertTrue(result.results.isEmpty, "returning nothing is the correct answer here")
        XCTAssertFalse(result.substituted)
    }

    // MARK: - MODE axis

    func testModeOrdersAuthoredWorkAboveConsumption() {
        // Same text, same age, same entity, same salience — only the MODE axis
        // differs (Xcode → produce, Safari → consume). MAP-ARCHITECTURE says mode
        // is used for 「重み付け・選別」, but nothing in this file read it until
        // 2026-08-09.
        let consumed = event("caching strategy", eventType: .clipboard,
                             app: "Safari", entity: "Mull")
        let authored = event("caching approach", eventType: .clipboard,
                             app: "Xcode", entity: "Mull")

        let results = rank([consumed, authored], query: "caching", anchor: "Mull")

        XCTAssertEqual(results.count, 2, "mode orders, it never filters (Law 5)")
        XCTAssertEqual(results.first?.app, "Xcode",
                       "authored work outranks consumption when everything else ties")
    }

    // MARK: - Ranking components

    func testMoreRecentEventOutranksAnEquivalentOlderOne() {
        // Equivalent in every scoring dimension except age, so recency alone
        // decides. The two texts used to be byte-identical, which is the cheapest
        // way to tie every other term; `Selection` now collapses a repeated
        // result before taking the top N (one screen polled every 5 seconds used
        // to fill all eight slots), so the tie is built from two different
        // sentences that score the same instead.
        let older = event("reviewing the payment reconciliation report", ago: 3600, title: "PantryApp")
        let newer = event("reviewing the payment reconciliation ledger", ago: 60, title: "PantryApp")

        let results = rank([older, newer])

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.timestamp, now.addingTimeInterval(-60))
    }

    func testHigherSalienceTypeOutranksLowerOne() {
        // Same timestamp, same entity, no query — only Signal's salience differs
        // (error 0.95 vs activity 0.20). A copied stack trace must beat ambient typing.
        let ambient = event("opened the meal entry screen again", title: "PantryApp")
        let failure = event("Fatal error while saving the meal entry", title: "PantryApp")

        let results = rank([ambient, failure])

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.type, "error")
        XCTAssertEqual(results.last?.type, "activity")
    }

    func testMoreQueryTermsMatchedOutranksFewer() {
        // lexical is a *ratio* of matched terms, and it carries the heaviest
        // weight (0.45), so a 3/3 match must beat a 1/3 match at equal recency.
        let partial = event("the payment dashboard loaded fine", title: "PantryApp")
        let full = event("the payment refund latency spiked this morning", title: "PantryApp")

        let results = rank([partial, full], query: "payment refund latency")

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.text, "the payment refund latency spiked this morning")
    }

    func testEventsOlderThanTheWindowAreKeptWithFlooredRecency() {
        // `since` sizes the recency ramp; it is NOT a time filter. `rank` clamps
        // recency at 0 rather than dropping the row — the caller does the time
        // scoping when it fetches. Locking this stops a future "optimisation"
        // from silently truncating results a caller deliberately asked for.
        let ancient = event("reviewing the payment reconciliation report", ago: window * 5)

        let results = rank([ancient])

        XCTAssertEqual(results.count, 1, "an out-of-window event is still ranked, just with zero recency")
    }

    // MARK: - The lexical gate

    func testNonMatchingEventIsDroppedWhenAQueryIsGiven() {
        // Without this gate, recent-but-unrelated events pad every answer.
        let unrelated = event("grocery shopping list for dinner tonight")

        XCTAssertTrue(rank([unrelated], query: "payment").isEmpty)
    }

    func testNonMatchingEventSurvivesWhenATypeFacetIsScoping() {
        // Deliberate asymmetry, commented at Selection.swift:62-67: with a `type`
        // facet the query is often the category itself ("crash" for type=error),
        // so zero literal overlap must NOT discard recent items of that type.
        let failure = event("Fatal error connecting to the database", title: "PantryApp")

        let scoped = rank([failure], query: "crash", type: "error")
        let unscoped = rank([failure], query: "crash")

        XCTAssertEqual(scoped.count, 1, "type facet suspends the lexical gate")
        XCTAssertTrue(unscoped.isEmpty, "the same event with no facet is gated out")
    }

    func testEntityFacetDoesNotSuspendTheLexicalGate() {
        // Only `type` is exempted. An entity anchor is applied on nearly every
        // call (MCPServer passes the current-state entity), so exempting it too
        // would effectively disable the gate everywhere.
        let unrelated = event("grocery shopping list for dinner tonight", title: "PantryApp")

        XCTAssertTrue(rank([unrelated], query: "payment", entity: "PantryApp").isEmpty)
    }

    // MARK: - Entity facet

    func testEntityScopeExcludesOtherEntities() {
        let mine = event("adjusted the summary layout", title: "PantryApp — main.swift")
        let other = event("adjusted the summary layout", title: "FXDashboard — main.swift")

        let results = rank([mine, other], entity: "PantryApp")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.entity, "PantryApp")
    }

    func testEntityScopeIsCaseInsensitive() {
        let mine = event("adjusted the summary layout", title: "PantryApp — main.swift")

        XCTAssertEqual(rank([mine], entity: "pantryapp").count, 1)
    }

    func testUnscopedSearchPrefersEventsThatHaveAnEntity() {
        // With no anchor, having an identifiable project earns the 0.03
        // `attributable` tiebreak. Both texts are >40 chars and separator-free, so
        // the title-less event genuinely resolves to a nil entity.
        //
        // (Comment corrected, assertions untouched: the weight used to be written
        // as "0.10-weighted 0.3 bonus" on an expression that also silently required
        // the anchor to be nil. Splitting anchor-match from attributability made
        // that description wrong; without the tiebreak these two events tie on
        // every component and this test would pass on input order alone.)
        // Two different sentences that tie on lexical, recency and salience.
        // They were one string until `Selection` began collapsing repeats.
        let anchored = event("reviewing the payment reconciliation report today", title: "PantryApp")
        let floating = event("reviewing the payment reconciliation ledger today", title: nil)

        // Floating first on purpose. These two tie on lexical, recency and
        // salience, so with the entity-less event already in front, only a real
        // score difference can reorder them — passing on input order is no longer
        // available to this test.
        let results = rank([floating, anchored])

        XCTAssertEqual(results.count, 2, "the entity-less event is bonused down, never dropped")
        XCTAssertEqual(results.first?.entity, "PantryApp")
        XCTAssertNil(results.last?.entity)
    }

    // MARK: - Type facet

    func testTypeScopeExcludesOtherTypes() {
        let failure = event("Fatal error while saving", contentType: "error")
        let note = event("remember to bump the version", contentType: "note")

        let results = rank([failure, note], type: "error")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "error")
    }

    func testTypeMatchesTheStoredColumnRatherThanRecomputing() {
        // The stored column wins: this text would recompute to "activity", but the
        // row was classified "decision" at capture. Trusting the column is what
        // lets capture-time enrichment (and any future backfill) actually take effect.
        let decided = event("we are going with GRDB over Core Data", contentType: "decision")

        XCTAssertEqual(rank([decided], type: "decision").count, 1)
        XCTAssertTrue(rank([decided], type: "activity").isEmpty)
    }

    func testTypeIsRecomputedForPreMigrationRowsWithNilColumns() {
        // Rows recorded before #4's backfill have contentType == nil. They must
        // still be reachable by facet, otherwise a type-scoped search silently
        // sees only recent history.
        let legacy = event("Fatal error: unexpectedly found nil", contentType: nil)
        XCTAssertNil(legacy.contentType)

        let results = rank([legacy], type: "error")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.type, "error", "Signal.kind fills in for the missing column")
    }

    func testStoredSalienceColumnIsUsedWhenPresent() {
        // Same as above for the ranking input: an explicitly stored salience
        // overrides the type default, so a row promoted at capture stays promoted.
        let promoted = event("opened the meal entry screen again", contentType: "activity", salience: 0.99)
        let failure = event("Fatal error while saving the meal entry", contentType: "error")

        let results = rank([promoted, failure])

        XCTAssertEqual(results.first?.text, "opened the meal entry screen again",
                       "0.99 stored salience beats error's default 0.95")
    }

    // MARK: - Privacy (hard guarantee)

    func testSensitiveTextIsNeverReturnedNoMatterHowWellItScores() {
        // This is not a ranking preference — it is absolute. The secret below is
        // the newest event and matches the query perfectly; it must still be
        // unreachable through `rank`, because `rank` is what MCP hands to an
        // external LLM.
        let secret = event("password: correct-horse for the staging box", ago: 1)
        let benign = event("deployed to the staging box this morning", ago: 1800)

        let results = rank([secret, benign], query: "staging")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "deployed to the staging box this morning")
        XCTAssertFalse(results.contains { $0.text.contains("password") })
    }

    func testSensitiveTextIsSuppressedEvenUnderAMatchingFacet() {
        // The facet paths bypass the lexical gate; they must not bypass privacy.
        let secret = event("api_key for the staging box", ago: 1, contentType: "note")

        XCTAssertTrue(rank([secret], query: "staging", type: "note").isEmpty)
        XCTAssertTrue(rank([secret]).isEmpty)
    }

    // MARK: - Synthetic input and shape guards

    func testSyntheticTestInputIsDropped() {
        let filler = event("the quick brown fox jumps over the fence")
        let real = event("spotted the fox near the office window")

        let results = rank([filler, real], query: "fox")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "spotted the fox near the office window")
    }

    func testEventsWithoutUsableTextAreDropped() {
        let empty = event("")
        let whitespace = event("   \n  ")
        let tooShort = event("x")
        var nilText = event("placeholder")
        nilText.textContent = nil

        XCTAssertTrue(rank([empty, whitespace, tooShort, nilText]).isEmpty)
    }

    func testTextIsTruncatedToTwoHundredCharacters() {
        // Results are one-liners for an MCP response; the back-pointer (eventID)
        // is how a reader returns to the full original.
        let long = String(repeating: "context ", count: 40)   // 320 chars
        XCTAssertGreaterThan(long.count, 200)

        let results = rank([event(long, id: 7)], query: "context")

        XCTAssertEqual(results.first?.text.count, 200)
        XCTAssertEqual(results.first?.eventID, 7)
    }

    // MARK: - Repeats

    /// One screen, polled every five seconds, used to fill every slot.
    ///
    /// A real `search` for `訂正ループ` came back with eight results that were all
    /// the same window title. Every copy scored the same, so the ranker had no
    /// reason to prefer one, and the answer was one fact repeated eight times.
    func testARepeatedWindowTitleDoesNotFillTheSlots() {
        var events = (0..<6).map { i in
            event("open source feasibility check", ago: TimeInterval(i) * 5, title: "Mull")
        }
        events.append(event("open source licence blockers", ago: 40, title: "Mull"))

        let results = rank(events, query: "open source", limit: 8)

        XCTAssertEqual(results.count, 2, "six copies are one result:\n\(results.map(\.text))")
        XCTAssertTrue(results.contains { $0.text.contains("licence blockers") },
                      "collapsing the flood must let the other match through")
    }

    /// Deduplicating after the cut would return fewer than `limit` results while
    /// better ones sat just below it. It happens before.
    func testCollapsingRepeatsDoesNotShrinkTheAnswer() {
        var events = (0..<5).map { i in
            event("payment reconciliation report", ago: TimeInterval(i) * 5, title: "PantryApp")
        }
        events += (1...3).map { i in
            event("payment reconciliation blocker \(i)", ago: TimeInterval(100 + i), title: "PantryApp")
        }

        let results = rank(events, query: "payment", limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    /// Two things that overlap by almost everything are still two things. This is
    /// why `Selection` asks for full containment rather than the partial overlap
    /// the composer uses on a dictation buffer.
    func testNearlyIdenticalButDistinctResultsBothSurvive() {
        let a = event("payment reconciliation step 1", ago: 60, title: "PantryApp")
        let b = event("payment reconciliation step 2", ago: 120, title: "PantryApp")

        XCTAssertEqual(rank([a, b], query: "payment").count, 2)
    }

    // MARK: - limit and ordering

    func testLimitIsRespectedAndResultsAreBestFirst() {
        // All five match the query identically, so recency is the tiebreak and
        // the surviving three must be the three newest, newest first.
        let events = (1...5).map { i in
            event("payment reconciliation step \(i)", ago: TimeInterval(i) * 300)
        }

        let results = rank(events.shuffled(), query: "payment", limit: 3)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.text), [
            "payment reconciliation step 1",
            "payment reconciliation step 2",
            "payment reconciliation step 3",
        ])
    }

    func testEmptyEventArrayYieldsNoResults() {
        XCTAssertTrue(rank([], query: "payment").isEmpty)
    }

    func testEmptyQueryRanksByRecencyAndSalienceAlone() {
        // No terms → the lexical gate is inert and everything survives, ordered
        // by "what matters now". This is the `recent_work` / anchor code path.
        let ambient = event("opened the meal entry screen again", ago: 30)
        let failure = event("Fatal error while saving the meal entry", ago: 1800)

        let results = rank([ambient, failure], query: "")

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.type, "error", "salience outweighs a 30-minute recency edge")
    }

    func testWhitespaceOnlyQueryBehavesLikeAnEmptyOne() {
        let ambient = event("opened the meal entry screen again")

        XCTAssertEqual(rank([ambient], query: "   ").count, 1)
    }

    // MARK: - Japanese (regression guard for the CJK bigram fix)

    func testJapaneseSubstringQueryMatches() {
        // THE regression this file exists for. `unicode61` tokenizes a whole CJK
        // run as one token, so before the bigram fix `lexical` demanded verbatim
        // containment of the entire query, `lexical == 0` gated everything out,
        // and `search` answered "No relevant activity" for any Japanese query.
        let meeting = event("今日の会議のメモ")
        let walk = event("散歩に行った記録")

        let results = rank([meeting, walk], query: "会議")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "今日の会議のメモ")
    }

    func testJapaneseQueryMatchesEvenWhenItIsNotAContiguousSubstring() {
        // The sharpest form of the same bug. "会議メモ" appears nowhere in
        // "今日の会議のメモ" verbatim, but its bigrams 会議 and メモ both do, so the
        // bigram scheme recovers the match a whole-token comparison could not.
        let meeting = event("今日の会議のメモを整理した")

        XCTAssertEqual(rank([meeting], query: "会議メモ").count, 1)
    }

    func testSingleKanjiQueryIsKeptWhole() {
        // A one-character CJK run has no bigram; the source keeps it as-is so
        // one-kanji queries ("本", "鬱") still match.
        let book = event("読んだ本のリストを更新")

        XCTAssertEqual(rank([book], query: "本").count, 1)
        XCTAssertTrue(rank([book], query: "犬").isEmpty)
    }

    func testMixedScriptQueryIsSegmentedPerScript() {
        // "swift開発" must become ["swift", "開発"] — latin stays a whole word,
        // only the CJK stretch becomes bigrams. Splitting the latin run into
        // bigrams too would match almost anything.
        let hit = event("swiftの開発を進めた")
        let miss = event("swiftのビルド設定を変更")

        let results = rank([hit, miss], query: "swift開発")

        XCTAssertEqual(results.count, 2, "the miss still matches the 'swift' term, so it is not gated out")
        XCTAssertEqual(results.first?.text, "swiftの開発を進めた", "2/2 terms outranks 1/2")
    }

    func testUnrelatedJapaneseEventIsGatedOut() {
        let walk = event("散歩に行った記録")

        XCTAssertTrue(rank([walk], query: "会議").isEmpty)
    }

    // MARK: - Result.line

    func testLineFormatsWithTimeAppEntityAndType() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"

        let result = Selection.Result(timestamp: now, app: "Xcode", type: "note",
                                      entity: "PantryApp", text: "bump the version", eventID: 3)

        XCTAssertEqual(result.line(formatter), "- 22:13 [Xcode] {PantryApp} note: bump the version")
    }

    func testLineOmitsMissingAppAndEntity() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"

        let result = Selection.Result(timestamp: now, app: nil, type: "activity",
                                      entity: nil, text: "typing", eventID: nil)

        XCTAssertEqual(result.line(formatter), "- 22:13 activity: typing")
    }

    func testEventIDPointsBackAtTheSourceEvent() {
        // MAP-ARCHITECTURE.md: the map node points INTO _raw, never replaces it.
        let source = event("the payment refund latency spiked", app: "Xcode", id: 512)

        let results = rank([source], query: "payment")

        XCTAssertEqual(results.first?.eventID, 512)
        XCTAssertEqual(results.first?.app, "Xcode")
        XCTAssertEqual(results.first?.timestamp, source.timestamp)
    }
}
