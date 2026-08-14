import SwiftUI
import ServiceManagement
import EventKit

/// Settings window — 3 tabs, no redundancy.
///
///   General:  Language, your setup answers, schedule, startup, output size
///   AI:       Which AI tools read mull, then LLM provider, API keys, tests
///   Data:     Permissions, data sources, storage, the notes mull keeps,
///             retention, cleanup
///
/// There was a fourth tab, "Profile". Ten sections, of which seven were
/// read-only statistics: facts, rhythm, attention, language, words, today, and
/// today's summary. None of them answered a question the reader could act on,
/// and five restated what Home and me.md already carry, at a different window
/// length — Language was 7-day there and 14-day in me.md. The three sections
/// that were load-bearing are now sections here: the setup answers and the
/// withheld me.pinned.md lines in General (`AnswersSection`), the correctable
/// notes in Data (`NotesSection`).
/// `@MainActor` because it holds `SettingsRouter.shared`, which is main-actor
/// isolated — the annotation keeps that read legal from the view's initialiser.
@MainActor
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    /// Which page Settings is showing.
    ///
    /// Deep links from elsewhere in the app ("Open Settings" next to a message
    /// about AI providers) need to land on the page they point at, so the
    /// selection is not private state here — it lives in `SettingsRouter`
    /// (MullApp.swift) and any call site can set it via
    /// `AppDelegate.showSettings(tab:)` before the window opens. Passing no tab
    /// leaves the user on whatever page they were last on.
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        TabView(selection: $router.selected) {
            GeneralTab()
                .environmentObject(appState)
                .tabItem { Label("General", systemImage: DS.Glyph.settings) }
                .tag(SettingsTab.general)

            AITab()
                .environmentObject(appState)
                // "cpu", not "brain": the tab configures which engine runs the
                // summaries. A brain glyph is the stock AI-product shorthand and
                // overclaims besides — nothing here thinks.
                .tabItem { Label("AI", systemImage: "cpu") }
                .tag(SettingsTab.ai)

            DataTab()
                .environmentObject(appState)
                .tabItem { Label("Data", systemImage: "externaldrive") }
                .tag(SettingsTab.data)
        }
        .frame(width: 520, height: 520)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("summaryTime") private var summaryTimeHour = 23
    @AppStorage("summaryTimeMinute") private var summaryTimeMinute = 0
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("outputMaxChars") private var outputMaxChars = 50000
    @AppStorage("proactiveBriefs") private var proactiveBriefs = false
    @AppStorage("meetingReminders") private var meetingReminders = true
    @AppStorage("aiAutoCopy") private var aiAutoCopy = true
    @AppStorage("summaryNotifications") private var summaryNotifications = true
    @AppStorage(Preferences.resumeGapKey) private var resumeGap = Int(BlockSegmenter.defaultResumeGap)
    @AppStorage(Preferences.mirrorEnabledKey) private var mirrorEnabled = false
    @AppStorage(Preferences.mirrorCalendarKey) private var mirrorCalendarID = ""
    @AppStorage(Preferences.mirrorIntervalKey) private var mirrorInterval = Int(Preferences.defaultMirrorInterval)
    /// The explicit language choice. Stored as the raw value so `@AppStorage`
    /// keeps working; `UserLanguage.Preference` is the meaning.
    @AppStorage(UserLanguage.preferenceKey)
    private var vaultLanguage = UserLanguage.Preference.system.rawValue
    // `autoExport`, `exportPath` and `obsidianVault` used to live here, behind an
    // "Export Destinations" section and an "Auto-export after each mull" toggle.
    // Nothing in the app ever read any of the three: the user typed a vault path,
    // switched auto-export on, and nothing happened — no export, no error, no
    // trace. A control that does nothing is worse than an absent one, because it
    // spends the user's trust. The vault is already plain markdown on disk, and
    // FullWindowView has a working export, so the honest fix is removal.
    //
    // The Language picker came out of the Profile tab's "What you told mull"
    // section. It sat there because the vault language used to be inferred from a
    // setup answer, but it stopped being a fact about you the moment it became an
    // explicit choice: it sets the language of every file mull writes *and* of
    // mull's own windows. That is an application preference, and General is where
    // macOS has trained people to look for one.
    //
    // The setup answers followed it (`AnswersSection`), when the Profile tab was
    // retired. They were a section here once, also called "Profile", and moved to
    // the tab because two things with one name in one window sent people to the
    // wrong one. With the tab gone the collision is gone with it.

    /// What macOS actually says about the login item, as opposed to what the
    /// checkbox claims. Empty when the two agree.
    @State private var loginItemNote: String?
    @State private var loginItemIsProblem = false

    /// The picker moved the app's chrome to a language this launch is not running
    /// in. Session state: it is true from the change until the app is quit, which
    /// is exactly how long the discrepancy lasts.
    @State private var languageNeedsRelaunch = false

    /// Seconds, matching `Preferences.resumeGap`. "Off" is a real option rather than
    /// a hidden floor: someone who wants every interruption drawn separately should
    /// be able to say so, not be told the smallest break mull believes in.
    private let resumeGapOptions = [
        (0, "Off — every break starts a new block"),
        (300, "5 minutes"),
        (600, "10 minutes"),
        (900, "15 minutes"),
        (1800, "30 minutes"),
    ]

    /// Seconds. This picks how soon a finished stretch of work reaches the calendar,
    /// not how much is written: only settled blocks are mirrored and each is written
    /// once, so a shorter interval costs latency, not volume.
    private let mirrorIntervalOptions = [
        (900, "Every 15 minutes"),
        (1800, "Every 30 minutes"),
        (3600, "Every hour"),
        (7200, "Every 2 hours"),
        (14400, "Every 4 hours"),
        (86400, "Once a day"),
    ]

    private let charOptions = [
        (5000, "Minimal (5K)"),
        (10000, "Light (10K)"),
        (50000, "Default (50K)"),
        (100000, "Large (100K)"),
        (200000, "Full day (200K)"),
        (0, "Unlimited"),
    ]

    var body: some View {
        Form {
            // One language, everywhere. Defaults to whatever macOS is set to, and
            // this is the way to say otherwise. It used to default to a substring
            // match against the free-prose setup answer — see `UserLanguage`.
            Section("Language") {
                Picker("Write and display in", selection: $vaultLanguage) {
                    ForEach(UserLanguage.Preference.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                .onChange(of: vaultLanguage) { old, new in
                    let was = UserLanguage.isJapanese(
                        preference: UserLanguage.Preference(rawValue: old) ?? .system)
                    // Only on a real flip: every picker change fires this, including
                    // one that resolves to the same language.
                    guard UserLanguage.isJapanese != was else { return }
                    applyToAppChrome(UserLanguage.Preference(rawValue: new) ?? .system)
                    OnboardingProfile.reprojectSection()
                    appState.regenerateContextNow()
                }

                // Where the line falls. The vault turns over on the next write —
                // seconds — while the windows are a real macOS localization and are
                // resolved once, at launch, from the bundle. Saying so is the whole
                // job of this line: a setting that visibly changes half of what it
                // named and silently defers the other half reads as a bug.
                Text("Everything mull writes, and mull's own windows. The files in ~/mull change on the next write; the windows change when mull next opens.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                if languageNeedsRelaunch {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: "info.circle")
                            .font(DS.miniFont)
                        Text("Quit and reopen mull to see the windows in this language.")
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Quit mull") { NSApp.terminate(nil) }
                            .font(DS.captionFont)
                            .controlSize(.small)
                    }
                    .foregroundStyle(DS.moon)
                }
            }

            // Directly under Language, because both are about what mull writes
            // down about you before any capture has happened.
            AnswersSection()

            Section("mull") {
                HStack {
                    Text("Nightly summary at")
                    Spacer()
                    Picker("", selection: $summaryTimeHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .frame(width: 60)
                    .labelsHidden()
                    .accessibilityLabel("Nightly summary hour")
                    Text(":")
                    Picker("", selection: $summaryTimeMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .frame(width: 60)
                    .labelsHidden()
                    .accessibilityLabel("Nightly summary minute")
                }

                // Bound through a proxy rather than `.onChange`, because the setter
                // writes `launchAtLogin` itself once it knows what the system did.
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))

                if let loginItemNote {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: loginItemIsProblem ? DS.Glyph.problem : "info.circle")
                            .font(DS.miniFont)
                        Text(loginItemNote)
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                        if loginItemIsProblem {
                            Button("Open Login Items") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                            .font(DS.captionFont)
                            .controlSize(.small)
                        }
                    }
                    .foregroundStyle(loginItemIsProblem ? DS.error : DS.inkDim)
                }
            }

            Section("Activity") {
                Picker("Treat a return within", selection: $resumeGap) {
                    ForEach(resumeGapOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                Text(resumeGap > 0
                     ? "Coming back to the same project inside this window continues the session instead of starting a second one. The break is not counted as working time."
                     : "Every break of more than three minutes begins a new block, even when you come straight back to the same file.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }

            Section("Mirror to Calendar") {
                mirrorControls
            }

            Section("Notifications") {
                // One toggle per source. Deliberately absent: "mull stopped
                // recording", because losing capture without a word is the one
                // failure the app must not allow.
                //
                // Nothing else needs a toggle, because a banner is only sent for
                // what happens while you are not looking. ⌘⇧C, ⌘⇧W and a summary
                // you start yourself report back in the window instead — you were
                // there, and you had just asked.

                // Default off: the trigger is "the active window's project
                // changed", which announces ordinary window-hopping, not
                // genuine resumption (see ProactiveLoop.tick).
                Toggle("Resume briefs on project switch", isOn: $proactiveBriefs)
                Text("When you return to a project, mull surfaces its recent threads as a notification and keeps them in proactive.md.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                Toggle("Meeting reminders", isOn: $meetingReminders)
                Text("15 minutes before a calendar event.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                // This one governs the feature, not just its banner: the banner
                // is how the user learns their clipboard was replaced, so a
                // banner-less copy would be a silent overwrite.
                Toggle("Auto-copy context for AI sites", isOn: $aiAutoCopy)
                Text("Opening claude.ai or chatgpt.com puts your context on the clipboard and notifies you. Turning this off stops the copying itself, not just the banner.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                Toggle("Summary notifications", isOn: $summaryNotifications)
                Text("The banner when the nightly summary finishes or fails. A run you start yourself is silent. The summary itself still appears in the window and the menu bar's unread mark.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }

            Section("Output") {
                Picker("Max size when copying to AI", selection: $outputMaxChars) {
                    ForEach(charOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }

                if outputMaxChars > 0 {
                    Text("\(outputMaxChars.formatted()) chars ≈ \((outputMaxChars / 4).formatted()) tokens")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .onAppear { reconcileLaunchAtLogin() }
        .onChange(of: summaryTimeHour) { _, h in
            appState.mullEngine.scheduleSummary(at: h, minute: summaryTimeMinute)
        }
        .onChange(of: summaryTimeMinute) { _, m in
            appState.mullEngine.scheduleSummary(at: summaryTimeHour, minute: m)
        }
        .onChange(of: mirrorEnabled) { _, _ in appState.calendarMirror.reschedule() }
        .onChange(of: mirrorInterval) { _, _ in appState.calendarMirror.reschedule() }
        .onChange(of: mirrorCalendarID) { _, _ in
            // Which events mull wrote is a fact about one calendar. Carried into a
            // different one, every absent event would read as a deletion by the user
            // and the whole range would be tombstoned unwritten.
            appState.calendarMirror.forgetLedger()
            appState.calendarMirror.reschedule()
        }
    }

    // MARK: - Mirror to Calendar

    @ViewBuilder
    private var mirrorControls: some View {
        let calendars = appState.calendar.writableCalendars
        let chosen = calendars.first { $0.id == mirrorCalendarID }

        Toggle("Write finished work to a calendar", isOn: $mirrorEnabled)
        Text("Blocks are copied once they can no longer change. Work still in progress is never written, so nothing mull puts in your calendar moves afterwards, and anything you delete there stays deleted.")
            .font(DS.captionFont)
            .foregroundStyle(DS.inkFaint)

        if mirrorEnabled {
            if calendars.isEmpty {
                Text("No calendar on this Mac accepts new events. Make one in Calendar.app first — mull never creates one.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.error)
            } else {
                Picker("Calendar", selection: $mirrorCalendarID) {
                    Text("Choose…").tag("")
                    ForEach(calendars) { cal in
                        Text("\(cal.title) — \(cal.accountName)").tag(cal.id)
                    }
                }
                // Make one in Calendar.app and point mull at it. Sharing a calendar
                // with real appointments is allowed — the mirror only ever touches
                // events carrying its own marker — but it is nobody's idea of tidy.
                Text("A calendar of its own is worth making: File ▸ New Calendar in Calendar.app.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                Picker("Check for finished work", selection: $mirrorInterval) {
                    ForEach(mirrorIntervalOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                Text("How soon finished work appears, not how much is written — each block is written once.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                if let chosen, !chosen.isLocal {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: "exclamationmark.triangle.fill").font(DS.miniFont)
                        Text("“\(chosen.title)” syncs with \(chosen.accountName). What mull writes are the names of the things you worked on, taken from your window titles, and they will leave this Mac for that account. A calendar under “On My Mac” stays here.")
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(DS.error)
                }

                Divider()
                mirrorReport
            }
        }
    }

    /// What the mirror has actually done, under the switches that ask for it.
    ///
    /// A pane of switches describes intent. This describes what happened, which is a
    /// different thing and the one that was missing: on 2026-08-14 the mirror had never
    /// run on this Mac and every screen in the app looked exactly as it would have if
    /// it were running perfectly.
    @ViewBuilder
    private var mirrorReport: some View {
        let status = appState.calendarMirror.status
        VStack(alignment: .leading, spacing: DS.xs) {
            if !status.hasRun {
                Label("No pass has finished yet.", systemImage: "clock")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
            } else {
                if let run = status.lastRun {
                    Label {
                        Text("Last checked \(CalendarWeekView.sinceLabel(run))")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                }
                Text("\(status.created) written · \(status.updated) brought up to date · \(status.deleted) removed · \(status.tombstoned) you deleted and mull won't rewrite")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)

                // The quality reading, in the same words the write sheet uses.
                if let fraction = status.quality.namedFraction {
                    Text("\(Int((fraction * 100).rounded()))% of the last pass was named from what you had open; the rest just say the app's name.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if status.failures > 0, let error = status.lastError {
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").font(DS.miniFont)
                    Text("\(pluralized(status.failures, "write")) failed. Last reason: \(error)")
                        .font(DS.captionFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.error)
            }
        }
    }

    // MARK: - Launch at login

    /// Make the checkbox and the system agree.
    ///
    /// `@AppStorage("launchAtLogin")` defaults to `true`, but registration only
    /// ever happened inside `.onChange` — so a fresh install showed a ticked box
    /// while the login item had never been registered, and mull did not launch at
    /// login until the user toggled it off and on again. For a background recorder
    /// that is whole days of missing capture with nothing anywhere saying so.
    private func reconcileLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            clearLoginItemNote()
        case .requiresApproval:
            // Registered, but macOS is holding it in Login Items until the user
            // says yes. Reporting this as plain "on" would be the same lie again.
            launchAtLogin = true
            loginItemNote = String(localized: "macOS is waiting for you to approve mull in System Settings › General › Login Items.")
            loginItemIsProblem = true
        default:
            // .notRegistered / .notFound — honour the stored preference by
            // actually performing the registration it has been claiming.
            if launchAtLogin { setLaunchAtLogin(true) } else { clearLoginItemNote() }
        }
    }

    /// Register or unregister, then report what really happened. The old code used
    /// `try?`, so a refusal from macOS left the checkbox ticked over a login item
    /// that does not exist.
    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
            clearLoginItemNote()
            if on, SMAppService.mainApp.status == .requiresApproval {
                loginItemNote = String(localized: "Almost there — approve mull in System Settings › General › Login Items.")
                loginItemIsProblem = true
            }
        } catch {
            // Show the state the system is actually in, not the one just asked for.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemNote = String(localized: "macOS refused: \(error.localizedDescription)")
            loginItemIsProblem = true
        }
    }

    private func clearLoginItemNote() {
        loginItemNote = nil
        loginItemIsProblem = false
    }

    /// Point the *bundle* at the chosen language, so mull's windows follow the same
    /// setting its files do.
    ///
    /// The two halves of "language" are resolved by different machinery and there is
    /// no honest way to make them switch together. The vault is written by mull, so
    /// `VaultText` reads the preference at every write and the next 60-second pass
    /// picks it up. The windows are a real macOS localization: `Text("…")` resolves
    /// against the bundle's `.lproj`, which CoreFoundation binds **once, at process
    /// start**, from `AppleLanguages`. Writing it here is what makes the next launch
    /// come up in the chosen language; nothing can make this one.
    ///
    /// `.system` removes the override rather than writing a value, so mull goes back
    /// to following System Settings › General › Language & Region — including its
    /// per-app entry for mull, which exists because the bundle now ships two
    /// localizations. Pinning `en`/`ja` there would make that per-app picker a
    /// control that silently does nothing.
    private func applyToAppChrome(_ preference: UserLanguage.Preference) {
        let key = "AppleLanguages"
        switch preference {
        case .system:   UserDefaults.standard.removeObject(forKey: key)
        case .english:  UserDefaults.standard.set(["en"], forKey: key)
        case .japanese: UserDefaults.standard.set(["ja"], forKey: key)
        }
        // Compare against what this process actually launched with, not against the
        // preference: switching to `.japanese` on a Mac already running mull in
        // Japanese changes nothing on screen, and offering to relaunch for it would
        // be asking the user to fix a problem they do not have.
        let running = Bundle.main.preferredLocalizations.first ?? "en"
        let wanted = UserLanguage.isJapanese(preference: preference) ? "ja" : "en"
        languageNeedsRelaunch = !running.hasPrefix(wanted)
    }
}

// MARK: - AI Tab

/// Connection status as a value, not as a glyph baked into a string.
/// (Status used to live inside the message — `"✓ Connected"` — and every
/// consumer parsed it back out with `contains("✓")`.)
private enum TestOutcome: Equatable {
    case idle
    case testing
    case ok(String)
    case failed(String)

    var message: String? {
        switch self {
        case .idle: nil
        case .testing: "Testing…"
        case .ok(let m), .failed(let m): m
        }
    }

    var isFailure: Bool { if case .failed = self { true } else { false } }

    var symbol: String? {
        switch self {
        case .idle, .testing: nil
        case .ok: DS.Glyph.success
        case .failed: DS.Glyph.problem
        }
    }

    var tint: Color {
        switch self {
        case .idle, .testing: DS.inkDim
        case .ok: DS.recording
        case .failed: DS.error
        }
    }
}

/// The one connection-test control on this tab.
///
/// There used to be two hand-rolled ones: the provider test had a spinner, a
/// result line, Retry and Dismiss, while the MCP test — labelled identically —
/// had a bare button and a result line you could never clear. Same states, same
/// affordances, one implementation; only the label says which link is being
/// tested.
private struct ConnectionTest: View {
    let label: String
    var systemImage: String? = nil
    @Binding var outcome: TestOutcome
    let run: () -> Void

    private var testing: Bool { outcome == .testing }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                Button(action: run) {
                    HStack(spacing: DS.xs) {
                        if testing {
                            ProgressView().controlSize(.mini)
                        } else if let systemImage {
                            Image(systemName: systemImage)
                        }
                        Text(testing ? "Testing…" : label)
                    }
                }
                .controlSize(.small)
                .disabled(testing)

                // While testing, the button already says so — don't say it twice.
                if !testing, let message = outcome.message {
                    HStack(spacing: DS.xs) {
                        if let symbol = outcome.symbol {
                            Image(systemName: symbol)
                        }
                        Text(message)
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(outcome.tint)
                    .transition(.opacity)
                }
            }

            if outcome.isFailure {
                HStack(spacing: DS.xs) {
                    Button("Retry", action: run)
                        .font(DS.captionFont)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("Dismiss") {
                        withAnimation { outcome = .idle }
                    }
                    .font(DS.captionFont)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.inkFaint)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: outcome)
    }
}

/// A result line with a Dismiss and no Retry.
///
/// Connect and Disconnect used to report through the `ConnectionTest` control at
/// the foot of the section, which had two consequences. "Claude Code connected"
/// appeared beside a button labelled "Test mull's MCP server", reading as that
/// button's answer to a question nobody had asked it. And the Retry offered on a
/// failure ran the test rather than the write that had just failed — the one thing
/// the user wanted retried was the one thing it would not do. The row that
/// produced this message is a few pixels above it, so retrying is pressing it
/// again; what this line owes the user is the message, kept until they are done
/// with it.
private struct OutcomeLine: View {
    @Binding var outcome: TestOutcome

    var body: some View {
        if let message = outcome.message {
            HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                if let symbol = outcome.symbol {
                    Image(systemName: symbol)
                        .font(DS.miniFont)
                }
                Text(message)
                    .font(DS.captionFont)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: DS.sm)

                Button("Dismiss") {
                    withAnimation { outcome = .idle }
                }
                .font(DS.captionFont)
                .buttonStyle(.plain)
                .foregroundStyle(DS.inkFaint)
            }
            .foregroundStyle(outcome.tint)
            .transition(.opacity)
        }
    }
}

/// A connect request waiting on the user, carrying the JSON they are approving.
///
/// Not private: onboarding's final step offers the same connect, and a second
/// hand-rolled sheet there would be a second chance to describe a config edit
/// wrongly. One sheet, one description, both callers.
struct PendingConnect: Identifiable {
    let tool: AIToolSetup.AITool
    let fragment: String
    var id: String { tool.id }
}

/// Copy to the clipboard, with the confirmation in the label rather than a toast.
private struct CopyButton: View {
    let text: String
    /// A `LocalizedStringKey`, not a `String`: the label is written here as a
    /// literal at every call site, and that is what puts it in the catalogue.
    var label: LocalizedStringKey = "Copy"

    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: DS.xs) {
                Image(systemName: copied ? DS.Glyph.confirm : DS.Glyph.copy)
                Text(copied ? LocalizedStringKey("Copied") : label)
            }
        }
        .font(DS.captionFont)
        .controlSize(.small)
    }
}

/// The consent step in front of "Connect".
///
/// Connecting rewrites a file mull did not author — ~/.claude.json holds every
/// other MCP server the user has registered, plus Claude Code's per-project
/// state. It used to happen on a single unlabelled click: no preview, no path, no
/// mention that a timestamped backup gets written. The backup was already good
/// engineering; the user was simply never told about it. This sheet shows the
/// exact fragment, the exact destination, and the safety net, and then asks.
struct MCPConnectSheet: View {
    let tool: AIToolSetup.AITool
    let fragment: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            VStack(alignment: .leading, spacing: DS.xs) {
                Text("Add mull to \(tool.name)?")
                    .font(DS.titleFont)
                    .foregroundStyle(DS.ink)
                Text("mull will merge this entry into \(tool.name)'s MCP configuration so it can read your context. Everything already in that file is kept.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DS.hair) {
                Text("Into this file").sectionLabel()
                Text(tool.configPath)
                    .font(DS.microFont)
                    .foregroundStyle(DS.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DS.hair) {
                HStack {
                    Text("Exactly this").sectionLabel()
                    Spacer()
                    // Selectable text in a 150pt scroll box was the only way to get
                    // this out of the app, which is not a way.
                    CopyButton(text: fragment)
                }
                ScrollView {
                    Text(fragment)
                        .font(DS.microFont)
                        .foregroundStyle(DS.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.sm)
                }
                .frame(height: 120)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusInset).fill(DS.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusInset)
                        .strokeBorder(DS.hairline, lineWidth: 0.75)
                )
            }

            // Claude Code owns this file while it runs — it writes per-project state
            // back into it — so an edit made underneath a live session can be lost.
            // The success message asks for a restart, which quietly invites exactly
            // that order. `claude mcp add` hands the edit to the process instead.
            if tool.id == "claude-code", let command = AIToolSetup.cliCommand() {
                VStack(alignment: .leading, spacing: DS.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: DS.Glyph.problem)
                            .font(DS.miniFont)
                        Text("If Claude Code is open, quit it first. It writes this file itself while it runs, and can overwrite an edit made underneath it.")
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(DS.paused)

                    CopyButton(text: command, label: "Copy the CLI command instead")
                }
            }

            // A footnote is type, not an icon row — the sentence carries itself.
            Text("A timestamped copy of the current file is saved beside it first, as \(AIToolSetup.backupDescription(for: tool)) — the \(AIToolSetup.backupsKept) most recent are kept and older ones are deleted. You can undo this at any time with Disconnect.")
                .font(DS.captionFont)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(DS.inkDim)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Write it") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.xl)
        .frame(width: 460, height: 540)
        .background(DS.canvas)
    }
}

struct AITab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("llmProvider") private var provider = "off"
    @AppStorage("ollamaModel") private var ollamaModel = "llama3.2"
    @AppStorage("localBaseURL") private var localBaseURL = "http://localhost:1234/v1"
    @AppStorage("localModel") private var localModel = ""
    @State private var geminiKey = ""
    @State private var claudeKey = ""
    @State private var openaiKey = ""
    /// Set when the Keychain refused to hand a saved key back, so the empty
    /// fields above are explained rather than read as "you never entered one".
    @State private var keyReadProblem: String?
    @State private var testOutcome: TestOutcome = .idle
    @State private var aiTools: [AIToolSetup.AITool] = []
    /// The MCP server handshake. Only the test writes here.
    @State private var setupOutcome: TestOutcome = .idle
    /// What the last Connect or Disconnect did. Kept apart from `setupOutcome` so
    /// neither answer is ever mistaken for the other's (see `OutcomeLine`).
    @State private var configOutcome: TestOutcome = .idle
    /// The tool awaiting the user's yes, and the JSON they are being asked to
    /// approve. Held together so the sheet can never show a stale fragment.
    @State private var pendingConnect: PendingConnect?
    @State private var pendingDisconnect: AIToolSetup.AITool?

    var body: some View {
        Form {
            // First, not last.
            //
            // This is the section that makes mull the thing it says it is: an agent
            // pointed at mull's MCP server. It used to sit at the foot of the tab,
            // underneath a provider picker and two API-key fields that are optional
            // and default to Off — so the default reading order put the product's
            // premise last, below settings most users never touch.
            //
            // The title says which way the arrow points. The Data tab has a section
            // called "Servers mull pulls from (MCP)", which is the opposite
            // direction, and both of them used to say only "connected".
            Section("AI tools that read mull") {
                ForEach(aiTools) { tool in
                    toolRow(tool)
                }

                otherToolsRow

                // Connect and Disconnect answer here, next to the rows that caused
                // them, and stay until dismissed.
                OutcomeLine(outcome: $configOutcome)

                // Real handshake — spawns the bundled binary and runs MCP initialize.
                // Same control as the provider test below, so both tests behave
                // identically (spinner, result, retry, dismiss); only the label
                // differs, because they test two different things.
                //
                // It proves the binary runs. It does not prove any client points at
                // it — that is what each row's own state says now.
                ConnectionTest(
                    label: String(localized: "Test mull's MCP server"),
                    systemImage: "bolt.horizontal.circle",
                    outcome: $setupOutcome,
                    run: testMCPServer
                )
            }

            Section("Provider") {
                Picker("", selection: $provider) {
                    Text("Off — local rule-based only").tag("off")
                    Text("Gemini Flash").tag("gemini")
                    Text("Local (Ollama)").tag("local")
                    Text("Local (OpenAI-compatible — LM Studio, Jan, …)").tag("localopenai")
                    Text("Claude API").tag("claude")
                    Text("OpenAI API").tag("openai")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel("AI provider")

                if provider == "off" {
                    Text("Rule-based me.md/now.md/full.md keep updating, and nothing is sent anywhere. Pick a provider to enable nightly LLM summaries, per-project deliberation, and Chat — those send data to the chosen service.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                } else if LLMProvider(rawValue: provider)?.isCloud == true {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: DS.Glyph.problem)
                            .font(DS.miniFont)
                        Text("This provider sends your activity data off-device to process it.")
                            .font(DS.captionFont)
                    }
                    .foregroundStyle(DS.paused)
                }
            }

            Section(providerDetailTitle) {
                switch provider {
                case "gemini":
                    APIKeyField(placeholder: String(localized: "API Key (AIza…)"), keychainKey: "gemini_api_key",
                                text: $geminiKey, onSaved: { testConnection() })
                    // Where to get a key is the only thing this row knows that the
                    // other two don't. It used to say two more things, both written
                    // against a bundled key that no longer exists: that the key is
                    // kept in the Keychain (keyNote, directly below, says that for
                    // every provider) and that requests run under your own account
                    // (the Provider section above already says the data leaves).
                    Text("Enter your key from Google AI Studio.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                    keyNote
                case "claude":
                    APIKeyField(placeholder: String(localized: "API Key (sk-ant-…)"), keychainKey: "claude_api_key",
                                text: $claudeKey, onSaved: { testConnection() })
                    keyNote
                case "openai":
                    APIKeyField(placeholder: String(localized: "API Key (sk-…)"), keychainKey: "openai_api_key",
                                text: $openaiKey, onSaved: { testConnection() })
                    keyNote
                case "local":
                    TextField("Model", text: $ollamaModel)
                    Text("Expects `ollama serve` on http://localhost:11434. Stays on-device.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                case "localopenai":
                    TextField("Base URL", text: $localBaseURL)
                    TextField("Model (blank = server's loaded model)", text: $localModel)
                    Text("Any OpenAI-compatible local server. LM Studio: start its Local Server (default http://localhost:1234/v1) and load a model. Also works with Jan, llama.cpp server, vLLM, LocalAI. Stays on-device.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                default:
                    EmptyView()
                }

                // Not applicable when LLM is off. The section it sits in is titled
                // with the provider name, so the button doesn't repeat it; the tab's
                // other test button says "Test mull's MCP server", which is already
                // distinct enough to tell the two failures apart.
                if provider != "off" {
                    ConnectionTest(
                        label: String(localized: "Test connection"),
                        outcome: $testOutcome,
                        run: testConnection
                    )
                }

                if let keyReadProblem {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: DS.Glyph.problem)
                            .font(DS.miniFont)
                        Text(keyReadProblem)
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(DS.error)
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $pendingConnect) { pending in
            MCPConnectSheet(tool: pending.tool, fragment: pending.fragment) {
                confirmConnect(pending.tool)
            }
        }
        .confirmationDialog(
            "Remove mull from \(pendingDisconnect?.name ?? "this tool")?",
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { if !$0 { pendingDisconnect = nil } }
            )
        ) {
            Button("Remove mull", role: .destructive) {
                guard let tool = pendingDisconnect else { return }
                pendingDisconnect = nil
                apply(AIToolSetup.disconnect(tool: tool))
            }
            Button("Cancel", role: .cancel) { pendingDisconnect = nil }
        } message: {
            Text("mull's entry is removed from \(pendingDisconnect?.configPath ?? "the config file"). Every other MCP server in that file is left exactly as it is, and a timestamped backup is written beside it first. Your recordings are untouched — \(pendingDisconnect?.name ?? "the tool") just stops being able to read them.")
        }
        .onAppear {
            // A refused keychain read is not an empty field. Drawing one over a
            // key that is really there invites the user to type it again, which
            // fails the same way — so the reason is kept and shown instead.
            geminiKey = readStoredKey("gemini_api_key")
            claudeKey = readStoredKey("claude_api_key")
            openaiKey = readStoredKey("openai_api_key")
            aiTools = AIToolSetup.detectTools()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // Detection ran once, when the tab appeared. Everything it reads can
            // change from outside: `claude mcp add` in a terminal, an app moved to
            // /Applications, a hand-edited config. Coming back to this window is
            // exactly the moment the badges have to be true, and re-reading three
            // small files is cheap.
            aiTools = AIToolSetup.detectTools()
        }
        .onChange(of: provider) { _, v in
            appState.llmProvider = LLMProvider(rawValue: v) ?? .off
        }
    }

    // MARK: - One AI tool's row

    /// Name and config path, whatever state the file is in underneath, and the
    /// controls that state allows.
    private func toolRow(_ tool: AIToolSetup.AITool) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack {
                VStack(alignment: .leading, spacing: DS.hair) {
                    Text(tool.name)
                        .font(DS.bodyMedium)
                    Text(tool.configPath)
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkGhost)
                        .lineLimit(1)
                        // A path's tail is the part that identifies it — lose the
                        // middle, not the file name, and keep the whole of it on
                        // hover.
                        .truncationMode(.middle)
                        .help(tool.configPath)
                }

                Spacer()

                statusControls(tool)
            }

            // What the file says, when what it says is the problem. The command is
            // shown for the same reason the Data tab shows the command of a server
            // mull pulls from: a path is the only thing that makes "this is broken"
            // checkable by the person reading it.
            if let problem = tool.registration.problem {
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    Image(systemName: DS.Glyph.problem)
                        .font(DS.miniFont)
                    VStack(alignment: .leading, spacing: DS.hair) {
                        Text(problem)
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                        if let command = tool.registration.command {
                            Text(command)
                                .font(DS.microFont)
                                .foregroundStyle(DS.inkGhost)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(command)
                        }
                    }
                }
                .foregroundStyle(DS.paused)
            }
        }
    }

    /// The buttons a registration allows. Registration decides first and detection
    /// second: what the config file says is a fact, and where the app happens to be
    /// installed is a guess.
    @ViewBuilder
    private func statusControls(_ tool: AIToolSetup.AITool) -> some View {
        switch tool.registration {
        case .current:
            HStack(spacing: DS.sm) {
                HStack(spacing: DS.xs) {
                    Image(systemName: DS.Glyph.success)
                        .foregroundStyle(DS.recording)
                    Text("Connected")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.recording)
                }
                // mull can put itself into someone's AI tooling, so it must be able
                // to take itself back out — without that, "Connect" is a one-way
                // door out of the app.
                Button("Disconnect") { pendingDisconnect = tool }
                    .font(DS.captionFont)
                    .controlSize(.small)
            }

        case .missingBinary, .otherBinary:
            // Registered at a path that will not work. The repair is the same write
            // Connect performs, so it goes through the same consent sheet.
            HStack(spacing: DS.sm) {
                Button("Reconnect") { beginConnect(tool) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Rewrites mull's entry in \(tool.configPath) to point at this app's copy of MullMCP")
                Button("Disconnect") { pendingDisconnect = tool }
                    .font(DS.captionFont)
                    .controlSize(.small)
            }

        case .unreadable:
            // No buttons: every write refuses on an unparseable config, so offering
            // one here would only produce the same error twice.
            Text("Can't read this file")
                .font(DS.captionFont)
                .foregroundStyle(DS.paused)

        case .absent:
            if tool.detected {
                // Not a direct write: this edits a file mull did not author
                // (~/.claude.json holds every other MCP server the user has), so it
                // goes through a sheet that shows the exact fragment and the exact
                // path first.
                Button("Connect") { beginConnect(tool) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Shows the exact change first, then writes mull into \(tool.configPath)")
            } else {
                // Detection is a guess from known install locations, so it must not
                // be the last word: "Not found" with a way through, rather than
                // "Not installed" and a dead row for someone who has the app
                // somewhere unusual.
                HStack(spacing: DS.sm) {
                    Text("Not found")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                    Button("Connect anyway") { beginConnect(tool) }
                        .font(DS.captionFont)
                        .controlSize(.small)
                        .help("Shows the exact change first, then writes mull into \(tool.configPath), creating it if needed")
                }
            }
        }
    }

    /// Every MCP client mull has no row for.
    ///
    /// There are three rows above and a dozen clients in the world — Windsurf, Zed,
    /// VS Code, Codex, Cline, Continue — and for all of them this app was a dead
    /// end: the only copy of the path lived inside a consent sheet you could reach
    /// only by pressing another tool's Connect button, in a 150-point box with no
    /// copy button. The entry is identical for every client, so it is here to take.
    @ViewBuilder
    private var otherToolsRow: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            Text("Any other MCP client")
                .font(DS.bodyMedium)

            if let command = AIToolSetup.cliCommand() {
                Text("Point it at mull's server yourself. This is the same entry the buttons above write, and the command Claude Code's own CLI takes.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text(command)
                    .font(DS.microFont)
                    .foregroundStyle(DS.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.sm) {
                    CopyButton(text: command, label: "Copy the command")
                    if let binary = AIToolSetup.mullMCPPath() {
                        CopyButton(text: binary, label: "Copy the path")
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    Image(systemName: DS.Glyph.problem)
                        .font(DS.miniFont)
                    Text("MullMCP isn't built or installed yet, so there is no path to hand out. Build it, or install it to /usr/local/bin.")
                        .font(DS.captionFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.paused)
            }
        }
    }

    /// Read a saved key for display. A `.denied` answer leaves the field empty —
    /// there is nothing to show — but records why, so the UI can say so.
    private func readStoredKey(_ keychainKey: String) -> String {
        do {
            return try KeychainService.read(key: keychainKey)
        } catch {
            if case .denied = error { keyReadProblem = error.message }
            return ""
        }
    }

    private var providerDetailTitle: String {
        switch provider {
        case "off": "On-device"
        case "gemini": "Gemini"
        case "claude": "Claude API"
        case "openai": "OpenAI API"
        case "local": "Ollama"
        case "localopenai": String(localized: "Local (OpenAI-compatible)")
        default: ""
        }
    }

    private var keyNote: some View {
        HStack(spacing: DS.xs) {
            Image(systemName: DS.Glyph.locked)
                .font(DS.iconMini)
            Text("Stored in macOS Keychain")
                .font(DS.captionFont)
        }
        .foregroundStyle(DS.inkFaint)
    }

    // MARK: - MCP client config

    /// Build the preview and open the consent sheet. If the MullMCP binary can't
    /// be found there is nothing honest to show, so it fails here rather than
    /// writing a config pointing at nothing.
    private func beginConnect(_ tool: AIToolSetup.AITool) {
        switch AIToolSetup.configFragment() {
        case .success(let fragment):
            pendingConnect = PendingConnect(tool: tool, fragment: fragment)
        case .failure(let error):
            configOutcome = .failed(error.localizedDescription)
        }
    }

    private func confirmConnect(_ tool: AIToolSetup.AITool) {
        pendingConnect = nil
        apply(AIToolSetup.setup(tool: tool))
    }

    /// Both config edits report the same way and both re-detect afterwards, so the
    /// row's badge reflects the file rather than what the button assumed.
    ///
    /// `configOutcome`, never `setupOutcome`: a write's answer belongs beside the
    /// rows, not beside a test button that was never pressed.
    private func apply(_ result: Result<String, Error>) {
        switch result {
        case .success(let message):
            configOutcome = .ok(message)
        case .failure(let error):
            configOutcome = .failed(error.localizedDescription)
        }
        aiTools = AIToolSetup.detectTools()
    }

    private func testConnection() {
        // One value drives the whole control: .testing IS the spinner, so there is
        // no separate `isTesting` flag left to get out of step with the outcome.
        testOutcome = .testing
        Task {
            do {
                switch provider {
                case "gemini":
                    guard let key = KeychainService.loadKey("gemini_api_key") else {
                        testOutcome = .failed(String(localized: "No API key entered"))
                        return
                    }
                    // The key goes in a header, not in `?key=`, for the reason
                    // LLMClient.callGemini gives: a URL is the part of a request
                    // that gets written down. The test used the query form, so the
                    // same key was handled two different ways depending on which
                    // button you pressed. It also takes the key out of a string
                    // interpolation, where a reserved character made URL(string:)
                    // return nil and the failure read as a malformed URL.
                    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
                        testOutcome = .failed(String(localized: "Could not build the request URL"))
                        return
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 {
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                        let hasFlash = models.contains { $0.contains("flash") }
                        testOutcome = .ok(hasFlash ? String(localized: "Gemini Flash available") : String(localized: "Connected (\(models.count) models)"))
                    } else {
                        testOutcome = .failed(Self.httpFailureMessage(code))
                    }

                case "claude":
                    guard let key = KeychainService.loadKey("claude_api_key") else {
                        testOutcome = .failed(String(localized: "No API key entered"))
                        return
                    }
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                        testOutcome = .failed(String(localized: "Could not build the request URL"))
                        return
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 15
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": "claude-sonnet-4-6", "max_tokens": 5,
                        "messages": [["role": "user", "content": "hi"]]
                    ])
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    testOutcome = code == 200 ? .ok(String(localized: "Connected")) : .failed(Self.httpFailureMessage(code))

                case "openai":
                    guard let key = KeychainService.loadKey("openai_api_key") else {
                        testOutcome = .failed(String(localized: "No API key entered"))
                        return
                    }
                    guard let url = URL(string: "https://api.openai.com/v1/models") else {
                        testOutcome = .failed(String(localized: "Could not build the request URL"))
                        return
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    testOutcome = code == 200 ? .ok(String(localized: "Connected")) : .failed(Self.httpFailureMessage(code))

                case "localopenai":
                    let base = localBaseURL.trimmingCharacters(in: .whitespaces)
                    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                    guard let url = URL(string: "\(trimmed)/models") else {
                        testOutcome = .failed(String(localized: "Invalid base URL"))
                        return
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 10
                    if let key = KeychainService.loadKey("local_api_key") {
                        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    }
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let models = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
                    if models.isEmpty {
                        testOutcome = .ok(String(localized: "Server up, but no model loaded — load one in LM Studio"))
                    } else if localModel.isEmpty || models.contains(where: { $0.hasPrefix(localModel) }) {
                        testOutcome = .ok(String(localized: "Ready (\(models.prefix(2).joined(separator: ", ")))"))
                    } else {
                        testOutcome = .failed(String(localized: "\(localModel) not loaded. Available: \(models.prefix(3).joined(separator: ", "))"))
                    }

                default:
                    guard let url = URL(string: "http://localhost:11434/api/tags") else {
                        testOutcome = .failed(String(localized: "Could not build the request URL"))
                        return
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 10
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                    if models.contains(where: { $0.hasPrefix(ollamaModel) }) {
                        testOutcome = .ok(String(localized: "\(ollamaModel) ready"))
                    } else {
                        let available = models.prefix(3).joined(separator: ", ")
                        testOutcome = .failed(String(localized: "\(ollamaModel) not found. Available: \(available)"))
                    }
                }
            } catch let error as URLError where error.code == .timedOut {
                testOutcome = .failed(String(localized: "Timed out — server not responding"))
            } catch let error as URLError where error.code == .cannotConnectToHost {
                testOutcome = .failed(String(localized: "Cannot connect — is the server running?"))
            } catch let error as URLError where error.code == .notConnectedToInternet {
                testOutcome = .failed(String(localized: "No internet connection"))
            } catch {
                let msg = error.localizedDescription
                testOutcome = .failed(msg.count > 60 ? String(msg.prefix(60)) + "…" : msg)
            }
        }
    }

    /// The other connection on this tab: mull's own MCP server, spawned and put
    /// through a real `initialize` handshake.
    private func testMCPServer() {
        setupOutcome = .testing
        Task.detached {
            let result = AIToolSetup.testConnection()
            await MainActor.run {
                switch result {
                case .success(let message): setupOutcome = .ok(message)
                case .failure(let error): setupOutcome = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Status-code-specific guidance — "HTTP 401" tells the user nothing actionable.
    private static func httpFailureMessage(_ code: Int) -> String {
        switch code {
        case 401: return String(localized: "Key rejected (401) — check the key; it may be revoked or from the wrong account")
        case 403: return String(localized: "Access denied (403) — this key lacks permission for the API")
        case 429: return String(localized: "Quota or rate limit (429) — check billing / usage caps")
        case 500...599: return String(localized: "Provider error (\(code)) — their side; retry in a moment")
        default: return "HTTP \(code)"
        }
    }
}

// MARK: - API Key Field

/// API-key input done properly:
/// - trims pasted whitespace/newlines (the invisible cause of "correct key but 401")
/// - debounces the Keychain write (per-keystroke SecItem writes made typing lag)
/// - reveal toggle, because you cannot proofread a row of dots
/// - confirms the save with a masked tail, then auto-runs the connection test via `onSaved`
struct APIKeyField: View {
    let placeholder: String
    let keychainKey: String
    @Binding var text: String
    var onSaved: () -> Void = {}

    @State private var revealed = false
    @State private var saveTask: Task<Void, Never>?
    @State private var savedTail: String?
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack(spacing: DS.sm) {
                Group {
                    if revealed {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onChange(of: text) { _, value in scheduleSave(value) }

                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(DS.captionFont)
                        .iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.inkFaint)
                .help(revealed ? "Hide key" : "Show key")
                .accessibilityLabel(revealed ? "Hide key" : "Show key")
                .accessibilityHint("Shows or conceals the API key in plain text")
            }

            if saveFailed {
                HStack(spacing: DS.xs) {
                    Image(systemName: DS.Glyph.problem)
                        .font(DS.miniFont)
                        .foregroundStyle(DS.error)
                    Text("Could not save to Keychain — the key is not stored.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.error)
                }
                .transition(.opacity)
            } else if let tail = savedTail {
                HStack(spacing: DS.xs) {
                    Image(systemName: DS.Glyph.success)
                        .font(DS.miniFont)
                        .foregroundStyle(DS.recording)
                    Text("Saved to Keychain (…\(tail))")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.recording)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: savedTail)
    }

    private func scheduleSave(_ value: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != value { text = trimmed }   // strip pasted junk *visibly*
            // Nothing to do when the field already holds what the Keychain holds.
            // The tab seeds this field from the Keychain when it appears, and to
            // `.onChange` that assignment is indistinguishable from typing: merely
            // opening Settings → AI re-saved the key, showed "Saved to Keychain"
            // for a save nobody had made, and — through `onSaved` — put a live,
            // billed request to the provider. A read that was *refused* rather than
            // absent tells us nothing to compare against, so it falls through and
            // saves as before.
            if let stored = try? KeychainService.read(key: keychainKey), stored == trimmed {
                return
            }
            // Report the real outcome: silently claiming success for a key that
            // was never stored resurfaces later as a confusing "missing API key".
            let stored = KeychainService.save(key: keychainKey, value: trimmed)
            saveFailed = !stored
            guard stored, !trimmed.isEmpty else { savedTail = nil; return }
            savedTail = String(trimmed.suffix(4))
            onSaved()
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            savedTail = nil
        }
    }
}

// MARK: - Data Tab (Permissions + Storage + Notes + Cleanup)

struct DataTab: View {
    @EnvironmentObject var appState: AppState
    // The default MUST be the same constant the pruner falls back to. It used to be
    // the literal "unlimited" while AppState.pruneToRetention defaulted to 90, so a
    // fresh install displayed "Unlimited" here and silently deleted everything older
    // than 90 days on launch. One constant, one truth.
    @AppStorage("dataRetention") private var dataRetention = AppState.defaultDataRetentionDays
    @AppStorage("emailCaptureEnabled") private var emailCaptureEnabled = false

    @State private var eventCount = 0
    /// Every event in the database, not just today's. The destructive dialogs name
    /// what they destroy, and "all events" is not today's count.
    @State private var totalEventCount = 0
    @State private var summaryCount = 0
    @State private var memoryCount = 0
    @State private var dbSize = "—"

    @State private var showClearToday = false
    @State private var showClearEvents = false
    @State private var showClearAll = false
    /// What a cleanup action failed to do. These are privacy actions: reporting
    /// the failure where the button was pressed is part of the promise — the
    /// main window's notice bar is a different window the user may never open.
    @State private var cleanupProblem: String?

    /// Live EventKit status, re-read on every appearance so a permission granted
    /// in System Settings shows up here without a relaunch.
    @State private var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    /// Held in state because EKEventStore must outlive its own request callback —
    /// a store created inside the button action would not.
    @State private var calendarStore = EKEventStore()

    @State private var showEmailConsent = false
    @State private var emailChecking = false
    @State private var emailProblem: EmailService.AccessProblem?
    /// Why browser URLs stopped arriving, if they did.
    @State private var browserProblem: RecordingService.BrowserAccessProblem?
    /// Whether macOS is refusing to show mull's notifications.
    @State private var notificationsBlocked = false

    /// The picker's own state, so a retention change can be confirmed *before* it
    /// destroys anything. Binding the picker straight to @AppStorage meant selecting
    /// "7 days" deleted months of history on the same click, with no count and no undo.
    @State private var pendingRetention: String?
    @State private var pendingRetentionCount = 0
    /// Mirrors `dataRetention`, but only moves once a change has been confirmed —
    /// this is what the picker displays, so a cancelled change snaps back.
    @State private var shownRetention = AppState.defaultDataRetentionDays

    /// Provider setting, observed so the privacy copy below tells the truth the
    /// moment it changes.
    @AppStorage("llmProvider") private var llmProvider = "off"

    var body: some View {
        Form {
            // Permissions
            Section("Permissions") {
                // "Window titles" undersold this by the larger half. The same grant
                // drives WindowTextCapture, which walks the focused window's
                // accessibility tree and reads up to 40,000 characters of whatever
                // text is on screen. This row is where a person decides whether to
                // hand that over, so it has to name the bigger thing.
                permRow("Accessibility",
                        granted: appState.permissions.accessibilityGranted,
                        detail: String(localized: "Window titles, and the text on screen in the window you're using")) {
                    appState.permissions.openAccessibilitySettings()
                }
                permRow("Input Monitoring", granted: appState.permissions.inputMonitoringGranted, detail: String(localized: "Keystrokes")) {
                    appState.permissions.openInputMonitoringSettings()
                }
                // Calendar was requested exactly once, from AppState.init, and never
                // mentioned again anywhere in the app. A user who said no — or who
                // picked "Add only", which cannot read a single event — got a
                // permanently empty week view and a now.md with no schedule in it,
                // with nothing on any screen to explain why or to ask again.
                permRow("Calendar",
                        granted: calendarGranted,
                        detail: calendarDetail,
                        actionLabel: calendarStatus == .notDetermined ? "Grant" : "Open Settings") {
                    requestCalendarAccess()
                }
                // Browser Automation had no row at all, and its denial was never
                // recorded anywhere: mull asked Safari for the address bar during
                // onboarding, a reflexive Deny answered for good, and URLs simply
                // never appeared again with nothing on any screen to say why.
                if let problem = browserProblem {
                    VStack(alignment: .leading, spacing: DS.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                            Image(systemName: DS.Glyph.problem)
                                .font(DS.miniFont)
                            Text(problem.message)
                                .font(DS.captionFont)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(DS.error)
                        if problem.isPermission {
                            Button("Open Automation settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(DS.captionFont)
                            .controlSize(.small)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Browser pages").font(DS.bodyFont)
                        Text("Asked of Safari, Chrome, Arc, Brave and Edge the first time you use one. Firefox doesn't offer its address bar to any app.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Notifications carry the one message mull cannot deliver any other
                // way when its window is closed — a revoked permission, a summary
                // that failed. Denied, that channel is simply gone, and nothing used
                // to say so anywhere.
                if notificationsBlocked {
                    VStack(alignment: .leading, spacing: DS.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                            Image(systemName: DS.Glyph.problem)
                                .font(DS.miniFont)
                            Text("Notifications are turned off for mull, so meeting reminders, recording alerts and summary banners won't reach you. mull still shows them inside its own window.")
                                .font(DS.captionFont)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(DS.error)
                        Button("Open Notification settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(DS.captionFont)
                        .controlSize(.small)
                    }
                }

                // Clipboard needs no macOS permission — it is stated, not granted,
                // so it gets no button affordance.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Clipboard").font(DS.bodyFont)
                    Text("No permission required").font(DS.captionFont).foregroundStyle(DS.inkFaint)
                }
            }

            // Named for what it holds. "Data Sources" promised the list from
            // CLAUDE.md §6 — eight of them — and contained one toggle, because
            // Mail is the only source that is off until you ask for it. The
            // always-on ones are the Permissions section above; a pointer there
            // beats a second copy of the list that can drift away from it.
            Section("Optional sources") {
                Text("Everything else mull captures is always on, and listed under Permissions above.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                // Bound through a proxy: switching this on used to fire AppleScript
                // at Mail.app immediately, which raises a macOS Automation prompt
                // the user never asked for and cannot interpret. An unexplained
                // system dialog is how people learn to press Deny.
                Toggle("Email (Mail.app)", isOn: Binding(
                    get: { emailCaptureEnabled },
                    set: { on in
                        if on {
                            showEmailConsent = true
                        } else {
                            emailCaptureEnabled = false
                            emailProblem = nil
                            appState.email.refreshState()
                        }
                    }
                ))
                .disabled(emailChecking)
                .confirmationDialog("Let mull read your inbox headers?",
                                    isPresented: $showEmailConsent) {
                    Button("Continue") { enableEmailCapture() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    // The old copy said "never the body" full stop, which is true of
                    // this channel and false of the product: Mail is not on the
                    // exclusion list, so the window-body capture reads a message you
                    // are reading like it reads any other app. Promising more than
                    // the implementation does, in the sentence a person consents to,
                    // is the one place that costs the most (CLAUDE.md §7.4, §8.3).
                    Text("macOS will ask whether mull may control Mail. This reads the subject and sender of mail received in the last 24 hours, not the body, and keeps them on this Mac. It does not change what mull reads from your screen: while you are reading mail, the text in the window is captured like any other app's. To stop that too, add Mail under \"Don't record in these apps\" below.")
                }

                if emailChecking {
                    HStack(spacing: DS.xs) {
                        ProgressView().controlSize(.mini)
                        Text("Asking Mail…")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkDim)
                    }
                } else if let problem = emailProblem {
                    // The old failure mode: the toggle stayed ON, the caption below
                    // kept promising capture, and not one email was ever recorded.
                    // Say what went wrong, and offer the only action that can fix it.
                    VStack(alignment: .leading, spacing: DS.xs) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                            Image(systemName: DS.Glyph.problem)
                                .font(DS.miniFont)
                            Text(problem.message)
                                .font(DS.captionFont)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(DS.error)

                        HStack(spacing: DS.xs) {
                            Button("Try again") { enableEmailCapture() }
                                .font(DS.captionFont)
                                .controlSize(.small)
                            if problem.isPermission {
                                Button("Open Automation settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .font(DS.captionFont)
                                .controlSize(.small)
                            }
                        }
                    }
                    .transition(.opacity)
                } else {
                    Text("Subject and sender only; this channel never reads the body. The text on screen while you're reading mail is captured like any other app's, unless you add Mail below.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Per-app exclusion — privacy control. Nothing is captured while an
            // excluded app is frontmost. The gate is on all five channels:
            // keystrokes, clipboard, window titles, window body text, browser URLs
            // (`RecordingService.isExcludedApp`), plus the app-switch rows at both
            // ends of a switch (`recordAppSession`).
            //
            // The old caption said "it covers everything" and then listed three of
            // the five, so the two it left out — the 40,000-character window body
            // and the browser URL — read as not covered. Naming them all is cheap;
            // an enumeration that follows the word "everything" is read as the
            // whole list whether or not it is one.
            Section("Don't record in these apps") {
                Text("Only while one of them is frontmost, and then nothing is recorded at all: keystrokes, clipboard, window titles, the text on screen, the browser address, and the switch itself.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)

                ForEach(appState.excludedAppList, id: \.id) { app in
                    HStack {
                        Text(app.name).font(DS.bodyFont)
                        Spacer()
                        if app.id == "com.mull.app" {
                            Text("always").font(DS.captionFont).foregroundStyle(DS.inkFaint)
                        } else {
                            Button {
                                appState.includeApp(app.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(DS.error)
                                    .iconHitTarget()
                            }
                            .buttonStyle(.plain)
                            .help("Resume recording in \(app.name)")
                            .accessibilityLabel("Stop excluding \(app.name)")
                            .accessibilityHint("mull resumes recording while \(app.name) is frontmost")
                        }
                    }
                }

                Menu("Add app…") {
                    let addable = appState.addableRunningApps
                    if addable.isEmpty {
                        Text("No other running apps")
                    } else {
                        ForEach(addable, id: \.id) { app in
                            Button(app.name) { appState.excludeApp(app.id) }
                        }
                    }
                }
                .font(DS.captionFont)
            }

            // External MCP sources (Phase B ingestion)
            MCPSourcesSection()

            // Storage overview
            Section("Storage") {
                // This row read "Events" while showing eventCountToday() — a storage
                // overview that reported one day's worth as the total.
                statRow("Events (today)", value: eventCount.formatted())
                statRow("Events (all time)", value: totalEventCount.formatted())
                statRow("Summaries", value: summaryCount.formatted())
                statRow("Memories", value: memoryCount.formatted())
                statRow("Database", value: dbSize)

                // The store's health had no surface here at all: this section
                // showed counts and a size for a database that might be running
                // from /tmp and about to lose the lot on restart.
                if let reason = appState.database.fallbackReason {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: DS.Glyph.problem)
                            .font(DS.miniFont)
                        Text(reason)
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(DS.error)
                }

                // Same for the vault: every markdown file mull writes lives there,
                // and a folder it cannot write to was only ever mentioned on Home.
                if let vaultIssue = MullDirectory.issueDescription {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: DS.Glyph.problem)
                            .font(DS.miniFont)
                        Text(vaultIssue)
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(DS.error)
                }

                HStack {
                    Spacer()
                    Button("Open in Finder") {
                        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                            .first?.appendingPathComponent("mull") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(DS.captionFont)
                }
            }

            // Between the counts and the clears: the "Memories" figure above is
            // the length of this list, and forgetting one is the finest-grained
            // version of the deletions below.
            NotesSection { Task { await refresh() } }

            // Retention
            Section("Auto-cleanup") {
                Picker("Keep raw events for", selection: $shownRetention) {
                    Text("7 days").tag("7")
                    Text("30 days").tag("30")
                    Text("90 days").tag("90")
                    Text("1 year").tag("365")
                    Text("Unlimited").tag("unlimited")
                }
                .onChange(of: shownRetention) { old, v in
                    // Already applied (or reverted by a cancel) — nothing to confirm.
                    guard v != dataRetention else { return }
                    // Widening retention, or turning pruning off, destroys nothing.
                    guard v != "unlimited", let days = Int(v) else {
                        dataRetention = v
                        return
                    }
                    // Counting what the change would destroy is a whole-table scan.
                    // Run inline it froze the window between the click and the
                    // dialog — the same freeze the counts at the top of this tab
                    // used to cause, for the same reason.
                    _ = old
                    Task {
                        let doomed = await eventsOlderThan(days: days)
                        guard !Task.isCancelled else { return }
                        guard doomed > 0 else {
                            dataRetention = v
                            return
                        }
                        pendingRetentionCount = doomed
                        pendingRetention = v
                    }
                }
                .confirmationDialog(
                    "Delete \(pendingRetentionCount.formatted()) recorded \(pendingRetentionCount == 1 ? "event" : "events")?",
                    isPresented: Binding(
                        get: { pendingRetention != nil },
                        set: { if !$0 { pendingRetention = nil } }
                    )
                ) {
                    Button("Delete and keep \(retentionLabel(pendingRetention))", role: .destructive) {
                        guard let v = pendingRetention, let days = Int(v) else { return }
                        dataRetention = v
                        // Every other destructive action in this tab routes a failure
                        // into `cleanupProblem`; this one swallowed it with `try?`, so
                        // a locked or full database left the setting claiming "7 days"
                        // over months of events with nothing on screen to say the
                        // deletion had not happened.
                        do {
                            try appState.database.deleteEventsOlderThan(days: days)
                        } catch {
                            cleanupProblem = "The setting was changed, but the older events "
                                + "could not be deleted: \(error.localizedDescription)"
                        }
                        pendingRetention = nil
                        Task { await refresh() }
                    }
                    Button("Cancel", role: .cancel) {
                        // Snap the picker back to the setting that is actually in force.
                        shownRetention = dataRetention
                        pendingRetention = nil
                    }
                } message: {
                    Text("Everything older than \(retentionLabel(pendingRetention)) will be permanently removed from your recordings. Summaries and the markdown files in ~/mull are kept. This cannot be undone.")
                }

                Text("Only the raw events age out. Your daily summaries and markdown files are never pruned.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
            }

            // Named against "Auto-cleanup" above it: the two sections used to be one
            // word apart, with nothing in either title saying which was the schedule
            // and which was the button you press yourself.
            Section("Clear now") {
                Button("Clear today's recordings") { showClearToday = true }
                    .confirmationDialog("Clear today?", isPresented: $showClearToday) {
                        Button("Clear Today", role: .destructive) { clearToday() }
                    } message: {
                        // The old copy promised only the events and reassured that
                        // "summaries are kept" — which is exactly backwards for a
                        // privacy action. Clearing the day now clears what mull
                        // concluded from the day too; your own writing is what stays.
                        Text(todayForgetDetail)
                    }

                Button("Clear all events") { showClearEvents = true }
                    .confirmationDialog("Clear all events?", isPresented: $showClearEvents) {
                        Button("Clear Events", role: .destructive) { clearEvents() }
                    } message: {
                        Text("Removes all \(totalEventCount.formatted()) recorded events. Summaries, memories, and your markdown files are kept.")
                    }

                Button(role: .destructive) { showClearAll = true } label: {
                    Text("Delete everything")
                }
                .confirmationDialog("Delete everything?", isPresented: $showClearAll) {
                    // The escape hatch its own doc comment promised. `exportVaultCopy`
                    // was fully written and called from nowhere, so the only thing
                    // offered beside an irreversible delete was a Finder window and a
                    // suggestion to copy the folder by hand.
                    Button("Save a copy of ~/mull first…") { exportVaultCopy() }
                    Button("Show me ~/mull first…") {
                        NSWorkspace.shared.open(MullDirectory.root)
                    }
                    Button("Delete Everything", role: .destructive) { deleteAll() }
                } message: {
                    // The old copy said only "all data", while deleteAll() also calls
                    // MullDirectory.deleteEverything() — it erases the ~/mull markdown
                    // files onboarding promised as the durable, portable artifact.
                    // Naming them is the difference between a choice and an ambush.
                    Text("""
                        This permanently deletes \(totalEventCount.formatted()) recorded events, \
                        \(summaryCount.formatted()) daily summaries, \(memoryCount.formatted()) memories, \
                        and every markdown file in ~/mull — me.md, now.md, and all your notes, \
                        projects and reports. Nothing goes to the Trash. This cannot be undone.
                        """)
                }
                // One alert for all three actions above — they set the same
                // state, and only one can have just been pressed.
                .alert(
                    "That didn't finish",
                    isPresented: Binding(get: { cleanupProblem != nil },
                                         set: { if !$0 { cleanupProblem = nil } })
                ) {
                    Button("OK", role: .cancel) { cleanupProblem = nil }
                } message: {
                    Text(cleanupProblem ?? "")
                }
            }

            // Privacy
            Section("Privacy") {
                // This used to read "nothing is ever sent" — false in the same window
                // as the AI tab, which uploads activity to a cloud provider (and ships
                // a built-in Gemini key, so "I never entered a key" is not a defence).
                // A privacy promise the product itself breaks is worse than none.
                Text("mull sends no telemetry or analytics, ever. There is no mull server.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)

                HStack(alignment: .top, spacing: DS.sm) {
                    Image(systemName: cloudProviderName == nil ? DS.Glyph.locked : "arrow.up.forward.app")
                        .font(DS.captionFont)
                        .foregroundStyle(cloudProviderName == nil ? DS.recording : DS.paused)
                    if let provider = cloudProviderName {
                        Text("Your recorded activity is sent to \(provider) when you use Chat or generate a summary, because that provider is turned on in the AI tab. Switch it off there to keep everything on this Mac.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkDim)
                    } else {
                        Text("Your recorded activity stays on this Mac. It only leaves if you turn on a cloud AI provider in the AI tab — mull will say so here when you do.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkDim)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await refresh() }
    }

    // MARK: - Helpers

    /// `actionLabel` exists because not every permission can still be *granted*
    /// from inside mull: once macOS has recorded a denial it will not prompt again,
    /// and the only honest button is one that opens System Settings.
    private func permRow(_ name: String, granted: Bool, detail: String,
                         actionLabel: String = "Grant",
                         action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? DS.Glyph.success : DS.Glyph.denied)
                .foregroundStyle(granted ? DS.recording : DS.error)
                .font(DS.bodyFont)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(DS.bodyFont)
                Text(detail)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button(actionLabel) { action() }
                    .font(DS.captionFont)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Calendar permission

    /// Read access, specifically. "Add only" counts as authorised in System
    /// Settings but cannot read a single event, so it does not count here.
    private var calendarGranted: Bool { calendarStatus == .fullAccess }

    private var calendarDetail: String {
        if calendarGranted { return String(localized: "Your schedule, in now.md and the week view") }
        switch calendarStatus {
        case .notDetermined:
            return String(localized: "Not asked yet — your schedule is missing from now.md")
        case .denied, .restricted:
            return String(localized: "Denied — grant it in System Settings, then reopen the week view")
        default:
            // .writeOnly ("Add only"): looks granted, reads nothing. This is the
            // quiet cause of a week view that stays empty for someone certain
            // they said yes.
            return String(localized: "Add-only access — mull can't read events. Full access needed")
        }
    }

    private func requestCalendarAccess() {
        guard calendarStatus == .notDetermined else {
            // macOS prompts once and only once. After that the answer can only be
            // changed in System Settings, so send the user straight there rather
            // than firing a request that returns false without showing anything.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // EventKit answers on a private queue; the status re-read has to land back
        // on the main actor before it touches view state.
        // Full access, not write-only: mull never creates events, it only reads
        // them, and write-only would leave the week view exactly as empty as a
        // denial while looking granted in System Settings.
        calendarStore.requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                calendarStatus = EKEventStore.authorizationStatus(for: .event)
            }
        }
    }

    // MARK: - Email capture

    /// Turn capture on, then find out whether it can actually work — and say so if
    /// it can't. Leaving the toggle on over a denied Automation prompt is the
    /// defect this replaces: it looked enabled forever and captured nothing.
    private func enableEmailCapture() {
        emailCaptureEnabled = true
        emailProblem = nil
        emailChecking = true
        Task { @MainActor in
            let problem = await EmailService.checkMailAccess()
            emailChecking = false
            emailProblem = problem
            // A switch that stays on while nothing is being captured is a lie the
            // user has no way to detect. If Mail can't be read, the setting goes
            // back off and the row explains itself.
            if problem != nil { emailCaptureEnabled = false }
            appState.email.refreshState()
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(DS.bodyFont)
            Spacer()
            Text(value).font(DS.microFont).foregroundStyle(DS.inkDim)
        }
    }

    /// Counts, sizes and permission states for this tab.
    ///
    /// The counting half runs off the main thread. It is four whole-table passes —
    /// one of which materialised every summary row purely to take `.count` of it —
    /// and on a database holding months of keystroke-grade events, running them
    /// inline from `.onAppear` froze the Settings window for as long as they took.
    /// The retired Profile tab froze the same way, for the same reason; every read
    /// this window makes on appearance goes off the main thread now.
    private func refresh() async {
        let database = appState.database
        let counts = await Task.detached(priority: .userInitiated) {
            (today: database.eventCountToday(),
             total: database.countEvents(from: .distantPast, to: .distantFuture),
             summaries: database.summaryCount(),
             memories: database.fetchAllMemories().count,
             bytes: database.totalStorageBytes())
        }.value

        guard !Task.isCancelled else { return }
        eventCount = counts.today
        totalEventCount = counts.total
        summaryCount = counts.summaries
        memoryCount = counts.memories
        dbSize = ByteCountFormatter.string(fromByteCount: counts.bytes, countStyle: .file)
        // Show what is actually in force, not the @AppStorage default, so a value
        // written by a previous version still displays correctly.
        shownRetention = dataRetention
        // Permissions can change outside the app; read them rather than trusting
        // whatever was true when this view was first constructed.
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        // A failure from the background poll (Automation revoked months after the
        // user agreed) surfaces here rather than staying invisible forever.
        emailProblem = emailCaptureEnabled ? EmailService.lastProblem : nil
        browserProblem = RecordingService.lastBrowserProblem
        // Asks the system rather than prompting, so opening this tab never
        // produces a dialog the user didn't ask for.
        Notifier.shared.refreshDeliveryState { notificationsBlocked = $0 }
    }

    /// How many events a retention change would destroy. Shown in the confirmation
    /// so "7 days" is a decision with a number attached rather than a blind click.
    private func eventsOlderThan(days: Int) async -> Int {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return 0 }
        let database = appState.database
        return await Task.detached(priority: .userInitiated) {
            database.countEvents(from: .distantPast, to: cutoff)
        }.value
    }

    private func retentionLabel(_ value: String?) -> String {
        switch value {
        case "7": "7 days"
        case "30": "30 days"
        case "90": "90 days"
        case "365": "1 year"
        default: String(localized: "the selected period")
        }
    }

    /// Which cloud vendor, if any, currently receives recorded activity. `nil` means
    /// everything stays local (off, or a local model over localhost).
    /// Reads through `llmProvider` (not `appState`) so the notice redraws the
    /// moment the AI tab changes, but the cloud/local judgement itself lives in
    /// one place — the forget dialog asks the same question and must not be able
    /// to answer it differently.
    private var cloudProviderName: String? {
        AppState.cloudProviderName(for: llmProvider)   // "off"/"local"/"localopenai" → nil
    }

    /// Zip ~/mull to a location the user picks, then reveal it in Finder.
    ///
    /// Offered as the first button on the "delete everything" dialog: the vault is
    /// the durable artifact onboarding promised, so the destructive path has to
    /// carry an escape hatch beside it, not somewhere else in the app.
    private func exportVaultCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mull-folder.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let source = MullDirectory.root

        // ditto runs off the main thread — zipping a full vault on it froze the
        // window. It writes to a staging file beside the destination and only
        // replaces the real one on success, so a failed export destroys neither
        // the vault nor a zip that was already there, and Finder is revealed
        // only when there is actually something to reveal.
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let staging = dest.deletingLastPathComponent()
                .appendingPathComponent(".mull-vault-\(UUID().uuidString).zip")

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                           source.path, staging.path]
            let errors = Pipe()
            p.standardError = errors

            var failure: String?
            do {
                try p.run()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let text = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    failure = text.isEmpty ? "ditto exited with code \(p.terminationStatus)." : text
                }
            } catch {
                failure = error.localizedDescription
            }

            if failure == nil {
                do {
                    _ = try fm.replaceItemAt(dest, withItemAt: staging)
                } catch {
                    failure = error.localizedDescription
                }
            }
            try? fm.removeItem(at: staging)

            await MainActor.run {
                if let failure {
                    appState.postNotice("Export failed", detail: failure, isProblem: true)
                } else {
                    appState.postNotice("mull folder exported", revealURL: dest)
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            }
        }
    }

    private var todayInterval: DateInterval {
        DateInterval(start: Calendar.current.startOfDay(for: Date()), end: Date())
    }

    /// Same sentence the menu bar's Forget shows, so the two surfaces cannot
    /// describe the same action differently.
    private var todayForgetDetail: String {
        let plan = appState.forgetPlan(for: todayInterval)
        return [plan.sentence(label: "today"), plan.warning]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    /// Routed through the forget path, not `deleteEvents` — the events are only
    /// the input, and deleting them alone left today's summary, the memories
    /// formed today and the frozen daily snapshot all standing while this dialog
    /// reported the day cleared. Two surfaces offering the same promise must not
    /// keep it to different depths.
    private func clearToday() {
        cleanupProblem = appState.forget(appState.forgetPlan(for: todayInterval)).failureMessage
        Task { await refresh() }
    }

    private func clearEvents() {
        do {
            try appState.database.deleteEvents(since: .distantPast)
            appState.todayEventCount = 0
        } catch {
            cleanupProblem = String(localized: "The recordings could not be deleted: \(error.localizedDescription)")
        }
        appState.database.vacuum()
        Task { await refresh() }
    }

    /// Both halves are attempted even if the first fails — a vault that could
    /// not be removed is no reason to leave the database standing too — and
    /// every failure is reported. The counters are re-read from the database
    /// rather than zeroed: after a failed delete, "0 events" would be the UI
    /// claiming a success the data can contradict.
    private func deleteAll() {
        var problems: [String] = []
        do {
            try appState.database.deleteAllData()
        } catch let remains as DatabaseService.ArchivesRemainError {
            // The tables really were cleared here, so the generic sentence below
            // would be false — and false in the direction that matters, since what
            // is left is a readable copy of the whole history.
            problems.append(remains.errorDescription ?? String(localized: "Quarantined copies of your history could not be deleted."))
        } catch {
            problems.append(String(localized: "The recordings database could not be cleared: \(error.localizedDescription)"))
        }
        appState.database.vacuum()
        do {
            try MullDirectory.deleteEverything()
        } catch {
            problems.append(String(localized: "The ~/mull folder could not be removed: \(error.localizedDescription)"))
        }
        appState.todayEventCount = appState.database.eventCountToday()
        appState.loadTodaySummary()
        appState.loadRecentSummaries()
        cleanupProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
        Task { await refresh() }
    }
}

