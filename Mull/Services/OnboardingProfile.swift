import Foundation

/// The guided identity bootstrap — the few facts that are worth far more asked
/// once than inferred slowly from keystroke noise (role, language, goal, how you
/// want AI to answer). Each answer is a *stated prior*; passive capture stays the
/// *observed update* on top. We never replace capture with this — we seed it.
///
/// Answers are stored in UserDefaults (the editable source of truth) AND projected
/// into me.pinned.md as a delimited section. Because both markers are markdown
/// headings, Curator.filterPinned skips them as scaffold, while the `- …` fact
/// lines between them become authoritative pinned facts placed atop me.md.
///
/// This section is the one part of me.pinned.md mull *does* rewrite, and `writeSection`
/// is the writer — replacing everything between the markers and nothing outside them.
/// It runs only when the user saves their answers. The file's promise is about the lines
/// the user writes themselves, not about this delimited block (CLAUDE.md §7.4).
enum OnboardingProfile {

    struct Question: Identifiable {
        let id: String
        let prompt: String       // what the user sees
        let hint: String         // why we ask / what it changes
        let placeholder: String

        /// The label this answer carries in me.pinned.md.
        ///
        /// Computed rather than stored, and resolved through `VaultText` rather than
        /// the catalog, because it is the one part of a `Question` that is not chrome:
        /// it is written into the vault, so it follows the reader's language at the
        /// moment of the write (WRITING.md §5.2). A stored property would be resolved
        /// once, at first access, and the vault does not wait for the next launch the
        /// way the windows do. Nothing parses these back — the answers themselves live
        /// in `UserDefaults`, keyed by `id`.
        var label: String {
            switch id {
            case "role":     VaultText.t("Role", "役割")
            case "language": VaultText.t("Primary working language", "主に使う言語")
            case "building": VaultText.t("Currently working on", "いま作っているもの")
            case "goal":     VaultText.t("Goal with AI", "AI に期待すること")
            case "style":    VaultText.t("Preferred AI response style", "AI の返し方の好み")
            case "offload":  VaultText.t("Wants to offload", "手放したいこと")
            case "hours":    VaultText.t("Time zone / working hours", "タイムゾーン / 稼働時間")
            default:         id
            }
        }
    }

    /// Seven questions. Each earns its place by changing a downstream decision —
    /// no "how old are you" unless it moves something.
    ///
    /// The prompts, hints and placeholders are chrome: they are read on screen, so
    /// they go through the catalog and change with the windows.
    static let questions: [Question] = [
        .init(id: "role", prompt: String(localized: "What do you do?"),
              hint: String(localized: "Your role — the core of who mull says you are."),
              placeholder: String(localized: "e.g. Solo founder & Swift developer")),
        .init(id: "language", prompt: String(localized: "What language should AI reply in?"),
              hint: String(localized: "What the AI answers you in. Which language mull writes its own files in is set in Settings › General."),
              placeholder: String(localized: "e.g. Japanese (日本語)")),
        .init(id: "building", prompt: String(localized: "What are you working on right now?"),
              hint: String(localized: "Seeds your current projects."),
              placeholder: String(localized: "e.g. a macOS app, plus a side project")),
        .init(id: "goal", prompt: String(localized: "What do you want AI's help with?"),
              hint: String(localized: "Your aim for using mull — what to surface toward."),
              placeholder: String(localized: "e.g. Ship faster, fewer re-explanations")),
        .init(id: "style", prompt: String(localized: "How should AI respond to you?"),
              hint: String(localized: "Terse or detailed, tone, language — shapes every reply."),
              placeholder: String(localized: "e.g. Terse, in Japanese, no preamble")),
        .init(id: "offload", prompt: String(localized: "What would you like to offload?"),
              hint: String(localized: "What you'd rather not do yourself."),
              placeholder: String(localized: "e.g. Boilerplate, research, scheduling")),
        .init(id: "hours", prompt: String(localized: "Time zone & working hours?"),
              hint: String(localized: "So mull times proactive nudges well."),
              placeholder: String(localized: "e.g. JST, evenings")),
    ]

    // MARK: - Persistence (source of truth)

    static let answersKey = "onboardingProfileAnswers"   // mirrored by UserLanguage.onboardingAnswersKey

    /// Section markers follow the reader's language — they are the one part of
    /// this user-owned file mull writes visibly. Removal must recognize EVERY
    /// variant ever shipped, not just the current locale's: the file may hold a
    /// section written under another system language.
    private static var startMarker: String {
        UserLanguage.isJapanese
            ? "# ── mull プロフィール（セットアップでの回答 · 設定で編集） ──"
            : "# ── mull profile (from onboarding · edit in Settings) ──"
    }
    private static var endMarker: String {
        UserLanguage.isJapanese ? "# ── mull プロフィール ここまで ──" : "# ── end mull profile ──"
    }
    static let allStartMarkers: Set<String> = [
        "# ── mull profile (from onboarding · edit in Settings) ──",
        "# ── mull プロフィール（セットアップでの回答 · 設定で編集） ──",
        // Shipped before the Japanese wording settled on the words Settings uses
        // ("セットアップでの回答", and 設定 rather than the English "Settings").
        // Vaults written under it are still out there; dropping it from this set
        // would leave that section behind and stack a new one beneath it.
        "# ── mull プロフィール（オンボーディングの回答 · Settings で編集） ──",
    ]
    static let allEndMarkers: Set<String> = [
        "# ── end mull profile ──",
        "# ── mull プロフィール ここまで ──",
    ]

    static var answers: [String: String] {
        (UserDefaults.standard.dictionary(forKey: answersKey) as? [String: String]) ?? [:]
    }

    static var hasAnswers: Bool {
        answers.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Persist answers and (re)project them into me.pinned.md, preserving the rest
    /// of that user-owned file exactly.
    static func save(_ newAnswers: [String: String]) {
        UserDefaults.standard.set(newAnswers, forKey: answersKey)
        writeSection(lines: factLines(from: newAnswers))
    }

    /// Clear stored answers and remove the projected section from me.pinned.md.
    /// Anything the user added to me.pinned.md by hand is left untouched.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: answersKey)
        writeSection(lines: [])
    }

    /// Re-write the managed section from the answers already stored, changing
    /// none of them. The markers are the one visible thing in this file that
    /// follows the reader's language, so after a language change they would
    /// otherwise sit in the old one until the user next edited their answers.
    /// This replaces the marked block and nothing outside it — the whole of what
    /// CLAUDE.md §7.4 permits mull to write here.
    static func reprojectSection() {
        writeSection(lines: factLines(from: answers))
    }

    // MARK: - Projection into me.pinned.md

    private static func factLines(from a: [String: String]) -> [String] {
        questions.compactMap { q in
            let v = (a[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : "- \(q.label): \(v)"
        }
    }

    private static func writeSection(lines: [String]) {
        _ = Curator.pinnedFacts()                      // scaffold me.pinned.md if missing
        var text = removeSection(from: MullDirectory.read(Curator.pinnedFileName) ?? "")
        if !lines.isEmpty {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "\n\(startMarker)\n" + lines.joined(separator: "\n") + "\n\(endMarker)\n"
        }
        MullDirectory.write(text, to: Curator.pinnedFileName)
    }

    /// Strip any existing managed section (idempotent), leaving all other lines.
    /// Matches marker variants from every locale, so switching the system
    /// language replaces the old section instead of stacking a second one.
    static func removeSection(from text: String) -> String {
        var out: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if allStartMarkers.contains(line) {
                inside = true
                // Collapse the blank line `writeSection` puts in front of the
                // marker — the separator is re-created on every save, so leaving
                // the old one behind meant every save added another. Onboarding's
                // Save & Continue and Settings › General both land here, so the
                // gap in a file mull has promised to preserve grew by a line each
                // time the user so much as revisited the form. Removing the whole
                // run rather than a single line also heals the files that already
                // accumulated one.
                while out.last?.isEmpty == true { out.removeLast() }
                continue
            }
            if allEndMarkers.contains(line) { inside = false; continue }
            if !inside { out.append(line) }
        }
        return out.joined(separator: "\n")
    }
}
