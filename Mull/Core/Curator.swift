import Foundation

/// The Curator — incremental, provenance-aware writer for durable context files
/// (me.md, MEMORY.md). It NEVER rewrites a file wholesale. Instead it:
///   1. preserves blocks the user pinned (me.pinned.md) or edited directly,
///   2. updates the agent's own blocks in place,
///   3. appends genuinely new facts.
///
/// This is the ACE "Curator" pattern (DIRECTION.md §6): the only
/// sanctioned way to write a curated file. Both the 60s rule-based pass
/// (LiveContextGenerator) and the nightly LLM pass (MullEngine) go through here, so
/// neither can clobber the other — or the human.
enum Curator {

    // MARK: - Pinned facts (me.pinned.md)

    /// User-owned pinned facts file. mull scaffolds it, then only ever reads it —
    /// except that a file still containing nothing but the scaffold may be
    /// re-scaffolded (see `readPinned`), since no user writing exists in it yet.
    static let pinnedFileName = "me.pinned.md"

    /// The scaffold, in the reader's language. Plain words, no house vocabulary:
    /// the shipped English version spoke of "authoritative" facts and "disabling
    /// the layer" — to a Japanese-speaking user it read as a wall of foreign
    /// jargon at the top of a file mull was asking them to own.
    ///
    /// It is written as real markdown — a title and a blockquote — because the
    /// file is a `.md`. The previous scaffold used shell-style `#` comments, which
    /// markdown does not have: every explanation line rendered as a full-size H1,
    /// and the bare `#` spacer lines rendered as a lone `#` with nothing after it.
    /// mull's own preview, Obsidian, VS Code and GitHub all showed the same thing —
    /// a hash mark floating on an empty line — in the one file mull most wants the
    /// user to open and edit.
    static func pinnedTemplate(japanese: Bool = UserLanguage.isJapanese) -> String {
        japanese
            ? """
            # 自分について、AI に必ず正しく伝えたいこと

            > ここに**あなたが書いた行**を mull が書き換えることはありません。
            > （mull がこのファイルに書くのは2つだけ。この説明文を最初に置くときと、
            > 設定画面で保存した回答を、印で囲んだ区画に入れるときです。）
            > ここに書いた行がそのまま me.md の先頭に載り、mull の自動推測より優先されます。
            > 自動では間違うこと・知りようがないことを、ここで確定できます。
            >
            > 例:
            > - 平日の午後はレビューに使う。午前は割り込みを入れない。
            > - 仕事は日本語。AI の返答も日本語で。
            >
            > 見出し（`#`）と引用（`>`）の行は読み飛ばされるので、この説明は消しても残しても構いません。
            > 空のままなら me.md には何も追加されません。


            """
            : """
            # Facts AI should always get right about you

            > No line **you** write here is ever rewritten by mull.
            > (mull writes to this file in exactly two ways: laying down this note in the
            > first place, and replacing the marked-off section holding the profile
            > answers you saved in Settings.)
            > Lines you write here go straight to the top of me.md, above anything mull
            > guesses on its own — use it for what auto-detection gets wrong or cannot know.
            >
            > For example:
            > - Afternoons are for review; mornings are not to be interrupted.
            > - I work in Japanese; AI should reply in Japanese.
            >
            > Heading (`#`) and quote (`>`) lines are skipped, so keep or delete this note
            > as you like. Leave the file empty and nothing is added.


            """
    }

    /// Read the user's pinned facts (scaffold + blank lines stripped). Scaffolds the
    /// file once if missing; never overwrites the user's writing. Empty if none.
    static func pinnedFacts() -> String { readPinned().text }

    /// Pinned content, split into what was used and what was withheld.
    ///
    /// Nothing validated this layer, and it is the most load-bearing text mull
    /// has: pinned facts are declared authoritative and placed above everything
    /// else in me.md, which is the first thing any AI reads about the user. The
    /// shipped vault's `me.pinned.md` contained `ああ / あああ / あああ` —
    /// keyboard mash, presumably typed once while checking that the file worked —
    /// and mull had been handing it to every assistant as the user's identity for
    /// over a month.
    ///
    /// Two constraints shape the fix. mull must not keep publishing content that
    /// says nothing; and mull must not edit a line the user wrote in a file whose
    /// own header promises exactly that (CLAUDE.md §7.4). So the filtering happens at
    /// *read* time — the file on disk is untouched — and the withheld lines are
    /// returned rather than dropped silently, so a surface can tell the user what
    /// is being ignored and why. Deleting someone's writing without telling them
    /// is the one thing a custode may not do.
    static func readPinned() -> (text: String, withheld: [String]) {
        let template = pinnedTemplate()
        if !MullDirectory.exists(pinnedFileName) {
            MullDirectory.write(template, to: pinnedFileName)
        } else if let raw = MullDirectory.read(pinnedFileName),
                  raw != template, isPristineScaffold(raw) {
            // The file still contains nothing but scaffold lines — mull's own
            // scaffold, possibly an outdated or wrong-language version of it.
            // Refreshing it keeps the header's promise: the promise protects the
            // user's writing, and there is none here to protect.
            MullDirectory.write(template, to: pinnedFileName)
        }
        guard let raw = MullDirectory.read(pinnedFileName) else { return ("", []) }
        return filterPinned(raw)
    }

    /// Markdown's two chrome constructs — headings and blockquotes — are how the
    /// scaffold speaks, so they are what a reader skips. This is also what keeps
    /// the change backward-compatible: every line of the old `#`-comment scaffold,
    /// and both of onboarding's `# ── … ──` section markers, are headings, so
    /// files written by earlier versions still parse to exactly the same facts.
    ///
    /// A pinned fact is a plain statement about the user; nobody writes one as a
    /// heading or a pull-quote. Everything else in the file is theirs.
    static func isScaffoldLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("#") || trimmed.hasPrefix(">")
    }

    /// True when the file holds only scaffold and blank lines — i.e. no user
    /// content the never-overwrite promise applies to. Onboarding's projected fact
    /// lines ("- Role: …") are not scaffold, so their presence blocks a refresh.
    static func isPristineScaffold(_ raw: String) -> Bool {
        raw.components(separatedBy: "\n").allSatisfy { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || isScaffoldLine(t)
        }
    }

    /// The filtering half of `readPinned`, split out so it can be tested without
    /// touching the real `~/mull/me.pinned.md` — the test suite runs against the
    /// user's actual vault directory, and this file is the one thing in it mull
    /// has promised never to write.
    static func filterPinned(_ raw: String) -> (text: String, withheld: [String]) {
        var kept: [String] = []
        var withheld: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isScaffoldLine(trimmed) { continue }
            if trimmed.isEmpty { kept.append(line); continue }
            // A pinned fact is a statement about the user. Strip list markers
            // before judging, so "- ああ" is caught as readily as "ああ".
            let body = trimmed.drop(while: { $0 == "-" || $0 == "*" || $0 == " " })
            if TestInput.isLikelyTestInput(String(body)) {
                withheld.append(trimmed)
            } else {
                kept.append(line)
            }
        }

        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                withheld)
    }

    // MARK: - Shared headers for the multi-writer layers

    // now.md and full.md are written by TWO passes (the 60s LiveContextGenerator and
    // the nightly MullEngine), each owning its own block prefix. The header is a
    // whole-file property, so both must agree on its wording — otherwise every pass
    // would rewrite the header the other just wrote. Only the timestamp differs.

    /// The one timestamp format for generated-file headers: ISO 8601 with the local
    /// UTC offset ("2026-08-02T04:12+09:00"). The previous locale `.short` format
    /// ("11/06/2026, 12:26 AM") is unreadable to the files' primary audience — an
    /// AI cannot tell June 11 from November 6, and these headers are how a reader
    /// judges whether the context is current or stale.
    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // fixed format; never localized
        f.timeZone = .current                          // local time, offset explicit
        f.dateFormat = "yyyy-MM-dd'T'HH:mmZZZZZ"
        return f.string(from: date)
    }

    /// The day a line in me.md was last observed, for the reader to judge it by.
    ///
    /// Unambiguous and short: `2026-06-10`, not `10/06/2026`, for the same reason
    /// `timestamp` above is ISO — the primary audience is a model, and half the
    /// world's readers would take the other one to mean October 6th.
    ///
    /// Built per call, like every other formatter here: `DateFormatter` is a
    /// reference type with mutable state, and both writers of me.md are on
    /// different queues.
    static var observationDayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// The three contract files' headers, built to the one house style
    /// (MarkdownDoc): front matter for the housekeeping, a single H1, and one
    /// line of orientation only where a reader needs it to edit safely.
    ///
    /// What moved out of the body: the update time, the token budget, and which
    /// block prefix refreshes on which cadence. Those are properties OF the
    /// document, and they were occupying its first three lines — so the answer to
    /// "what am I working on" began two screens of italics later than it needed to.

    // The front-matter *keys* stay English on purpose (`VaultText`): they are YAML
    // identifiers, `generator` is matched byte-for-byte by `isGeneratedByMull`, and
    // a key is not a sentence. Titles, values and notes are prose, and prose
    // follows the reader.

    /// The blocks that make up "Who I am" — one rule, for both writers of me.md.
    ///
    /// Two passes write this file (the 60s one in `LiveContextGenerator`, the
    /// nightly one in `MullEngine`) and each prunes stale `mem:` blocks the other
    /// left behind, so anything they disagree about flickers: one writes a block and
    /// the other deletes it a minute later. They disagreed about two things — how
    /// many feedback memories to print (5 or 3) and whether an implausible
    /// "Working on:" project is skipped — so the rule lives here now, once.
    ///
    /// **`user` memories only.** A `feedback` memory is "how they work", which
    /// sounds like it belongs under "Who I am" and does not. It is a rule, and
    /// CLAUDE.md §0.1 is explicit that rules do not come out of observation: the
    /// nightly pass derives these by watching one day, so what stood in the identity
    /// layer was a rule mull made up about the user. Real rules arrive by the other
    /// road — a correction, a Card, `RuleBook`, rules.md — and `get_user_context`
    /// sends that file at every level anyway. Feedback memories are still written,
    /// still searchable, and still printed in full.md under "Working style &
    /// feedback"; they are only barred from standing as who somebody is.
    ///
    /// `pref:` stays in both callers' managed prefixes so the ones earlier versions
    /// wrote are swept out of the file rather than left behind unowned.
    static func identityBlocks(from memories: [MemoryEntry], now: Date = Date()) -> [ContextBlock] {
        let day = observationDayFormatter
        return memories.compactMap { mem -> ContextBlock? in
            guard mem.memoryType == .user, mem.isIdentity(asOf: now) else { return nil }
            // Skip stale/invalid project references. Same shape gate as everywhere
            // else — this was a fourth, shorter, differently-worded blocklist.
            if mem.description.hasPrefix("Working on:") {
                let project = mem.description.replacingOccurrences(of: "Working on: ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !ProjectNames.isPlausible(project) { return nil }
            }
            return ContextBlock(id: memoryBlockID(name: mem.name, description: mem.description),
                                source: .agent,
                                content: mem.identityLine(dateFormatter: day),
                                agentHash: nil)
        }
    }

    /// `isEmpty`: mull has nothing to say about this person and neither has the
    /// person. "Rewrite a block and mull stops touching it" is addressed to somebody
    /// looking at blocks, and under an empty heading it is advice about nothing —
    /// while the one thing that would actually fill the file goes unmentioned. The
    /// answers pane is the high-precision half of this file and it is opt-in, so a
    /// vault can sit for months with an identity layer built entirely out of guesses
    /// because nobody was told where to state a fact. Say it in the empty state,
    /// where there is room.
    static func meHeader(timestamp: String, isEmpty: Bool = false) -> String {
        MarkdownDoc.header(
            title: VaultText.t("Who I am", "私について"),
            meta: [("updated", timestamp)],
            // "Correct anything here in place" was addressed to whoever opens the raw
            // file in an editor, where it is true — every block below carries a
            // provenance marker, and one you rewrite is promoted to `human` and never
            // touched again. Read in mull's own Files tab it was a lie: that surface
            // strips the markers to display them, so it refuses to write the file back
            // and shows a lock instead. Say which is which, and name the place mull
            // does take corrections.
            note: isEmpty
                // The pane's own names, as this reader sees them in the app: an
                // instruction that says "Your answers" to somebody whose Settings
                // window says セットアップでの回答 is an instruction to go looking.
                ? VaultText.t("Nothing has been confirmed about you yet. Settings › General › Your answers is where you say what mull cannot work out on its own.",
                              "まだ確認できたことがありません。mull に分からないことは、設定 › 一般 › セットアップでの回答 に書けます。")
                : VaultText.t("Rewrite a block and mull stops touching it.",
                              "ブロックを書き換えれば、mull はそこに触れません。"))
    }

    static func nowHeader(timestamp: String) -> String {
        MarkdownDoc.header(
            title: VaultText.t("What I'm working on", "いま取り組んでいること"),
            meta: [("updated", timestamp)],
            note: VaultText.t("Your edits survive the next update.",
                              "編集しても、次の更新で消えません。"))
    }

    static func fullHeader(timestamp: String) -> String {
        MarkdownDoc.header(
            title: VaultText.t("Full context", "すべての文脈"),
            meta: [("updated", timestamp)],
            note: VaultText.t("Assembled from me.md and now.md. Edit those, not this.",
                              "me.md と now.md から組み立てています。直すならそちらを。"))
    }

    // MARK: - Curate (chokepoint)

    /// Merge agent blocks into `relativePath`, preserving pinned/human content, and
    /// write the result. The ONLY sanctioned writer for curated files.
    ///
    /// `managedPrefixes`: id-prefixes this caller exclusively owns (e.g. the 60s
    /// me.md pass owns `["fact:", "mem:", "pref:"]`). For those prefixes, an
    /// existing agent block that is NOT in `agentBlocks` is stale — mull stopped
    /// emitting it — and is pruned, so a re-classified fact (e.g. "Bilingual" →
    /// "Primary language") never leaves a contradicting leftover. Pass `[]` to
    /// keep the old never-prune behaviour (MEMORY.md and others).
    @discardableResult
    static func curate(relativePath: String, header: String, pinnedContent: String?, agentBlocks: [ContextBlock], managedPrefixes: [String] = []) -> Bool {
        let existing = MullDirectory.read(relativePath) ?? ""
        // Before the merge promotes edited blocks to `.human` and the evidence is
        // gone: record what was corrected. This is the chokepoint every writer
        // goes through, which is why the capture belongs here and not at the 16
        // call sites.
        recordCorrections(existing: existing, agentBlocks: agentBlocks, path: relativePath)
        let merged = merge(existing: existing, header: header, pinnedContent: pinnedContent, agentBlocks: agentBlocks, managedPrefixes: managedPrefixes)
        return MullDirectory.write(merged, to: relativePath)
    }

    // MARK: - Correction capture (the learning signal)

    /// Supplies "what were you doing when this correction happened" for the card's
    /// section 1. Set once at startup by the layer that owns the database; left
    /// nil in the MCP binary and in tests, where the card records the correction
    /// without it rather than inventing one.
    ///
    /// Section 1 is the part **only mull can fill** — Copilot Memory and ChatGPT
    /// let you delete a remembered item, but neither knows what you were doing
    /// when you deleted it (HARNESS.md 第II部 §6).
    static var contextSnapshotProvider: (() -> String?)?

    /// Pure detection (no I/O, so it is unit-testable): which agent blocks in
    /// `existing` no longer match the hash mull wrote — i.e. which ones a human
    /// edited since the last pass.
    ///
    /// This is the same check `merge` step 1 makes. `merge` uses it to *protect*
    /// the block; this uses it to *learn* from it. Until 2026-08-09 only the first
    /// existed: mull knew it had been corrected and kept no record of about what.
    static func detectCorrections(existing: String,
                                  agentBlocks: [ContextBlock],
                                  path: String,
                                  context: String? = nil,
                                  now: Date = Date()) -> [CorrectionCard] {
        let (_, blocks) = ContextBlockFile.parse(existing)
        var candidateByID: [String: String] = [:]
        for b in agentBlocks where candidateByID[b.id] == nil {
            candidateByID[b.id] = ContextBlock.normalized(b.content)
        }
        return blocks.compactMap { b in
            guard b.source == .agent,
                  let stored = b.agentHash,
                  stored != ContextBlock.hash(b.content) else { return nil }
            return CorrectionCard(path: path, blockID: b.id, date: now,
                                  kept: b.content, wouldWrite: candidateByID[b.id],
                                  context: context)
        }
    }

    /// Write the cards and fold their verdicts into the ledger the selection layer
    /// reads. Additive: an existing ledger the user has hand-edited is parsed and
    /// merged, never replaced (Invariant Contract 契約2).
    private static func recordCorrections(existing: String, agentBlocks: [ContextBlock], path: String) {
        let cards = detectCorrections(existing: existing, agentBlocks: agentBlocks,
                                      path: path, context: contextSnapshotProvider?())
        guard !cards.isEmpty else { return }
        for card in cards {
            _ = MullDirectory.write(card.render(), to: "\(CorrectionIndex.directory)/\(card.id).md")
        }
        let onDisk = CorrectionIndex.parseLedger(MullDirectory.read(CorrectionIndex.ledgerPath) ?? "")
        let merged = CorrectionIndex.merge(onDisk, CorrectionIndex.fold(cards))
        _ = MullDirectory.write(merged.renderLedger(), to: CorrectionIndex.ledgerPath)
    }

    /// Pure merge (no I/O) so it can be unit-tested.
    static func merge(existing: String, header: String, pinnedContent: String?, agentBlocks: [ContextBlock], managedPrefixes: [String] = [], now: Date = Date()) -> String {
        let pinnedID = "pinned-facts"
        var (_, existingBlocks) = ContextBlockFile.parse(existing)

        // 1. Detect human edits: an agent block whose content no longer matches the
        //    hash mull last wrote → the human touched it → promote to .human (protected).
        for i in existingBlocks.indices where existingBlocks[i].source == .agent {
            if let stored = existingBlocks[i].agentHash,
               stored != ContextBlock.hash(existingBlocks[i].content) {
                existingBlocks[i].source = .human
                existingBlocks[i].agentHash = nil
            }
        }

        // 2. The pinned block is sourced from me.pinned.md, not from agent output.
        //    Drop the old one and re-seat it from the file (its authority).
        existingBlocks.removeAll { $0.id == pinnedID }

        var result: [ContextBlock] = []
        if let pinned = pinnedContent, !pinned.isEmpty {
            result.append(ContextBlock(id: pinnedID, source: .pinned, content: pinned, agentHash: nil))
        }
        result.append(contentsOf: existingBlocks)

        // 3. Apply agent candidates: update the agent's own blocks in place, append new
        //    ones, never touch human/pinned blocks.
        var indexByID: [String: Int] = [:]
        for (i, b) in result.enumerated() { indexByID[b.id] = i }

        for var cand in agentBlocks {
            cand.source = .agent
            // Normalise BEFORE hashing: the hash has to describe the content as it
            // will read back off disk, or the next merge mistakes the round trip
            // for a human edit (see `ContextBlock.normalized`).
            cand.content = ContextBlock.normalized(cand.content)
            cand.agentHash = ContextBlock.hash(cand.content)
            cand.writtenAt = now
            if let idx = indexByID[cand.id] {
                if result[idx].source == .agent {
                    result[idx].content = cand.content
                    result[idx].agentHash = cand.agentHash
                    result[idx].writtenAt = cand.writtenAt
                }
                // human / pinned → leave untouched
            } else {
                result.append(cand)
                indexByID[cand.id] = result.count - 1
            }
        }

        // 4. Within the prefixes this caller manages, prune mull's own stale
        //    blocks (no longer emitted) and drop a bare block subsumed by a
        //    richer one. Human/pinned blocks are never touched.
        if !managedPrefixes.isEmpty {
            let candidateIDs = Set(agentBlocks.map(\.id))
            result.removeAll { b in
                b.source == .agent
                    && managedPrefixes.contains(where: { b.id.hasPrefix($0) })
                    && !candidateIDs.contains(b.id)
            }
            result = dropSubsumedAgentBlocks(result)
        }

        return ContextBlockFile.serialize(header: header, blocks: result)
    }

    // MARK: - Retract (the forget path)

    /// Withdraw mull's own blocks under `idPrefixes` from a curated file, and
    /// report the ones it refused to touch.
    ///
    /// `curate` already prunes stale agent blocks — but only for the prefixes the
    /// *calling pass* manages, and only when that pass next runs. That is enough
    /// for a fact that quietly stopped being true; it is not enough for a forget.
    /// The nightly blocks in now.md/full.md refresh once a day, so between a
    /// forget at 15:00 and the next consolidation, a block sourced from the
    /// erased window would keep describing it. Retraction is the pull, where
    /// curate is the push.
    ///
    /// Returns the ids mull left in place because they are the user's — a block
    /// they edited (which `merge` promotes to `.human`) or pinned content. mull
    /// deletes its own writing, never theirs; the caller is expected to SAY so.
    /// A forget that silently leaves the sentence you were trying to erase is
    /// worse than one that admits it.
    /// What a retraction left behind.
    struct Retraction {
        /// Ids mull kept because they are the user's.
        var retained: [String] = []
        /// False when the pruned file could not be written back — every block this
        /// call meant to pull is still sitting in the file. A forget that reports
        /// success on top of this is describing something that did not happen.
        var written: Bool = true
    }

    @discardableResult
    static func retract(relativePath: String, idPrefixes: [String]) -> Retraction {
        guard let existing = MullDirectory.read(relativePath), !existing.isEmpty else { return Retraction() }
        let (text, retained) = withdraw(existing: existing, idPrefixes: idPrefixes)
        guard text != existing else { return Retraction(retained: retained) }
        return Retraction(retained: retained,
                          written: MullDirectory.write(text, to: relativePath))
    }

    /// Pure half of `retract` (no I/O) so it can be unit-tested.
    static func withdraw(existing: String, idPrefixes: [String]) -> (text: String, retained: [String]) {
        let (header, parsed) = ContextBlockFile.parse(existing)

        var kept: [ContextBlock] = []
        var retained: [String] = []
        for var block in parsed {
            guard idPrefixes.contains(where: { block.id.hasPrefix($0) }) else {
                kept.append(block)
                continue
            }

            // Same human-edit detection `merge` does, and for the same reason —
            // a block still marked `src=agent` whose content no longer matches
            // the hash mull wrote is the user's text. Retracting on the marker
            // alone would delete an edit they made, which is the one thing a
            // custode may not do.
            if block.source == .agent,
               let stored = block.agentHash,
               stored != ContextBlock.hash(block.content) {
                block.source = .human
                block.agentHash = nil
            }

            if block.source == .agent {
                continue                     // mull's own — withdraw it
            }
            retained.append(block.id)        // the user's — keep, and report
            kept.append(block)
        }

        return (ContextBlockFile.serialize(header: header, blocks: kept), retained)
    }

    // MARK: - Expire (the staleness path)

    /// Withdraw mull's own blocks under `idPrefixes` that it can no longer vouch
    /// for the age of. Returns true when something was removed.
    ///
    /// `curate` prunes a block the moment its own pass stops emitting it, and
    /// `retract` pulls one on demand. Neither helps when the pass itself stops
    /// running: the `nightly:` blocks in now.md and full.md are written by the LLM
    /// consolidation, the LLM is off by default, and a block nothing rewrites is a
    /// block nothing corrects. The shipped vault still headed both files with "From
    /// last night's consolidation" over content from two months earlier, formatted
    /// by a markdown generation since replaced — the wrong date, the wrong shape,
    /// and no way for either to heal, because healing was the job of the pass that
    /// had stopped.
    ///
    /// A block with no `ts` is expired rather than kept. It was written before the
    /// stamp existed, which makes its age unknowable, and "last night's" is a claim
    /// about age. The next consolidation writes a stamped one; until then the
    /// section is absent, and absence is the honest state.
    @discardableResult
    static func expire(relativePath: String, idPrefixes: [String],
                       maxAge: TimeInterval, now: Date = Date()) -> Bool {
        guard let existing = MullDirectory.read(relativePath), !existing.isEmpty else { return false }
        let text = sweep(existing: existing, idPrefixes: idPrefixes, maxAge: maxAge, now: now)
        guard text != existing else { return false }
        return MullDirectory.write(text, to: relativePath)
    }

    /// Pure half of `expire` (no I/O) so it can be unit-tested.
    static func sweep(existing: String, idPrefixes: [String],
                      maxAge: TimeInterval, now: Date) -> String {
        let (header, parsed) = ContextBlockFile.parse(existing)
        let kept = parsed.filter { block in
            // Only mull's own writing is ever swept. A human or pinned block has
            // no `ts` by design — mull did not write it and has no claim on when
            // it should stop being true.
            guard block.source == .agent,
                  idPrefixes.contains(where: { block.id.hasPrefix($0) }) else { return true }
            guard let written = block.writtenAt else { return false }
            return now.timeIntervalSince(written) <= maxAge
        }
        return ContextBlockFile.serialize(header: header, blocks: kept)
    }

    /// Drop an agent block whose text is a word-boundary prefix of another
    /// block's text — keep the richer one (e.g. "- Software developer" is
    /// removed in favour of "- Software developer (primary tools: …)"). Never
    /// drops a human/pinned block.
    private static func dropSubsumedAgentBlocks(_ blocks: [ContextBlock]) -> [ContextBlock] {
        func body(_ s: String) -> String {
            var t = s
            if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }
            return t.trimmingCharacters(in: .whitespaces)
        }
        let bodies = blocks.map { body($0.content) }
        var keep: [ContextBlock] = []
        for (i, block) in blocks.enumerated() {
            if block.source == .agent, !bodies[i].isEmpty {
                let a = bodies[i]
                var subsumed = false
                for (j, b) in bodies.enumerated() where j != i {
                    if b.count > a.count, b.hasPrefix(a) {
                        let next = b[b.index(b.startIndex, offsetBy: a.count)]
                        if next == " " || next == "(" { subsumed = true; break }
                    }
                }
                if subsumed { continue }
            }
            keep.append(block)
        }
        return keep
    }

    // MARK: - Agent block builders (shared id conventions)

    /// Stable id for a memory-derived block. Both the 60s and nightly passes use this,
    /// so they update the same block instead of duplicating it.
    static func memoryBlockID(name: String, description: String) -> String {
        let key = name.isEmpty ? description : name
        return "mem:" + ContextBlockFile.slug(key)
    }

    // `feedbackBlockID` ("pref:") is gone: nothing writes a feedback memory into
    // me.md any more (see `identityBlocks`). The prefix itself lives on in both
    // passes' `managedPrefixes` so the blocks earlier versions wrote are pruned.

    /// Stable id for a FactExtractor fact. Key-only for attributes whose value changes
    /// (tech stack, language ratios → updates replace), full-line for container facts
    /// whose value is the identity ("Working on: X" → each project distinct).
    static func factBlockID(category: String, text: String) -> String {
        var t = text
        if t.hasPrefix("- ") { t = String(t.dropFirst(2)) }

        // First colon at paren-depth 0.
        var depth = 0
        var colon: String.Index?
        var i = t.startIndex
        while i < t.endIndex {
            switch t[i] {
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case ":" where depth == 0: colon = i
            default: break
            }
            if colon != nil { break }
            i = t.index(after: i)
        }

        let keyPart: String
        if let c = colon {
            let key = String(t[..<c]).trimmingCharacters(in: .whitespaces)
            let containerKeys: Set<String> = ["working on", "project", "projects"]
            keyPart = containerKeys.contains(key.lowercased()) ? t : key
        } else {
            // No colon: strip parentheticals so e.g. "Software developer (tools: …)" is stable.
            keyPart = t.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        }
        return "fact:\(category):\(ContextBlockFile.slug(keyPart))"
    }
}
