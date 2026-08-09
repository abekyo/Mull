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
        let label: String        // the me.pinned.md fact label
    }

    /// Seven questions. Each earns its place by changing a downstream decision —
    /// no "how old are you" unless it moves something.
    static let questions: [Question] = [
        .init(id: "role", prompt: "What do you do?",
              hint: "Your role — the core of who mull says you are.",
              placeholder: "e.g. Solo founder & Swift developer", label: "Role"),
        .init(id: "language", prompt: "What language should AI reply in?",
              hint: "What the AI answers you in. Which language mull writes its own files in is set in Settings › General.",
              placeholder: "e.g. Japanese (日本語)", label: "Primary working language"),
        .init(id: "building", prompt: "What are you working on right now?",
              hint: "Seeds your current projects.",
              placeholder: "e.g. a macOS app, plus a side project", label: "Currently working on"),
        .init(id: "goal", prompt: "What do you want AI's help with?",
              hint: "Your aim for using mull — what to surface toward.",
              placeholder: "e.g. Ship faster, fewer re-explanations", label: "Goal with AI"),
        .init(id: "style", prompt: "How should AI respond to you?",
              hint: "Terse or detailed, tone, language — shapes every reply.",
              placeholder: "e.g. Terse, in Japanese, no preamble", label: "Preferred AI response style"),
        .init(id: "offload", prompt: "What would you like to offload?",
              hint: "What you'd rather not do yourself.",
              placeholder: "e.g. Boilerplate, research, scheduling", label: "Wants to offload"),
        .init(id: "hours", prompt: "Time zone & working hours?",
              hint: "So mull times proactive nudges well.",
              placeholder: "e.g. JST, evenings", label: "Time zone / working hours"),
    ]

    // MARK: - Persistence (source of truth)

    static let answersKey = "onboardingProfileAnswers"   // mirrored by UserLanguage.onboardingAnswersKey

    /// Section markers follow the reader's language — they are the one part of
    /// this user-owned file mull writes visibly. Removal must recognize EVERY
    /// variant ever shipped, not just the current locale's: the file may hold a
    /// section written under another system language.
    private static var startMarker: String {
        UserLanguage.isJapanese
            ? "# ── mull プロフィール（オンボーディングの回答 · Settings で編集） ──"
            : "# ── mull profile (from onboarding · edit in Settings) ──"
    }
    private static var endMarker: String {
        UserLanguage.isJapanese ? "# ── mull プロフィール ここまで ──" : "# ── end mull profile ──"
    }
    static let allStartMarkers: Set<String> = [
        "# ── mull profile (from onboarding · edit in Settings) ──",
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
