import SwiftUI
import ServiceManagement
import EventKit

/// Settings window — 4 tabs, no redundancy.
///
///   General:  Schedule, startup, output size
///   AI:       LLM provider, API keys, connection test, MCP client setup
///   Data:     Permissions, data sources, storage, retention, cleanup
///   Profile:  Everything about you — the answers you gave (editable), what
///             capture observed (read-only), the notes mull wrote (correctable)
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
                .tabItem { Label("General", systemImage: "gearshape") }
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

            ProfileTab()
                .environmentObject(appState)
                .tabItem { Label("Profile", systemImage: "person.text.rectangle") }
                .tag(SettingsTab.profile)
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
    @AppStorage(Preferences.resumeGapKey) private var resumeGap = Int(TimeBlockEngine.defaultResumeGap)
    // `autoExport`, `exportPath` and `obsidianVault` used to live here, behind an
    // "Export Destinations" section and an "Auto-export after each mull" toggle.
    // Nothing in the app ever read any of the three: the user typed a vault path,
    // switched auto-export on, and nothing happened — no export, no error, no
    // trace. A control that does nothing is worse than an absent one, because it
    // spends the user's trust. The vault is already plain markdown on disk, and
    // FullWindowView has a working export, so the honest fix is removal.
    //
    // The "Profile" section (Edit answers… / Reset answers) has moved to the
    // Profile tab. Two things called "Profile" in one Settings window — a section
    // here and a tab over there, about different data — meant the person looking
    // for either found the wrong one first. Everything about *you* now lives on
    // the one tab named for you.

    /// What macOS actually says about the login item, as opposed to what the
    /// checkbox claims. Empty when the two agree.
    @State private var loginItemNote: String?
    @State private var loginItemIsProblem = false

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
                        Image(systemName: loginItemIsProblem ? "exclamationmark.triangle.fill" : "info.circle")
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
                     ? "Coming back to the same project inside this window continues the session instead of starting a second one that looks unrelated. The break itself is never counted as working time — the block says how long you were away."
                     : "Every break of more than three minutes begins a new block, even when you come straight back to the same file.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }

            Section("Notifications") {
                // One toggle per source. Deliberately absent: "mull stopped
                // recording" (losing capture without a word is the one failure
                // the app must not allow) and the ⌘⇧C confirmation (it only
                // fires when the user themselves asked for a copy).

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
                Text("The banner when a summary finishes or fails. The summary itself still appears in the window and the menu bar's unread mark.")
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
            loginItemNote = "macOS is waiting for you to approve mull in System Settings › General › Login Items."
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
                loginItemNote = "Almost there — approve mull in System Settings › General › Login Items."
                loginItemIsProblem = true
            }
        } catch {
            // Show the state the system is actually in, not the one just asked for.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemNote = "macOS refused: \(error.localizedDescription)"
            loginItemIsProblem = true
        }
    }

    private func clearLoginItemNote() {
        loginItemNote = nil
        loginItemIsProblem = false
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
        case .ok: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
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
                Text("Exactly this").sectionLabel()
                ScrollView {
                    Text(fragment)
                        .font(DS.microFont)
                        .foregroundStyle(DS.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.sm)
                }
                .frame(height: 150)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusInset).fill(DS.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusInset)
                        .strokeBorder(DS.hairline, lineWidth: 0.75)
                )
            }

            // A footnote is type, not an icon row — the sentence carries itself.
            Text("A timestamped copy of the current file is saved beside it first, as \(AIToolSetup.backupDescription(for: tool)). You can undo this at any time with Disconnect.")
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
        .frame(width: 460, height: 440)
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
    @State private var setupOutcome: TestOutcome = .idle
    /// The tool awaiting the user's yes, and the JSON they are being asked to
    /// approve. Held together so the sheet can never show a stale fragment.
    @State private var pendingConnect: PendingConnect?
    @State private var pendingDisconnect: AIToolSetup.AITool?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("", selection: $provider) {
                    Text("Off — local rule-based only (no cloud)").tag("off")
                    Text("Gemini Flash (Free)").tag("gemini")
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
                        Image(systemName: "exclamationmark.triangle.fill")
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
                    APIKeyField(placeholder: "API Key (AIza…)", keychainKey: "gemini_api_key",
                                text: $geminiKey, onSaved: { testConnection() })
                    // Where a key is kept is a privacy fact, not a feature note, so
                    // every provider that takes one says it — Gemini's key was the
                    // one that silently didn't.
                    if geminiKey.isEmpty {
                        Text("Enter your key from Google AI Studio. A key you enter is kept in the macOS Keychain, never in a file.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkFaint)
                    } else {
                        Text("Requests go straight from this Mac to Google under your own key and account.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkDim)
                        keyNote
                    }
                case "claude":
                    APIKeyField(placeholder: "API Key (sk-ant-…)", keychainKey: "claude_api_key",
                                text: $claudeKey, onSaved: { testConnection() })
                    keyNote
                case "openai":
                    APIKeyField(placeholder: "API Key (sk-…)", keychainKey: "openai_api_key",
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
                        label: "Test connection",
                        outcome: $testOutcome,
                        run: testConnection
                    )
                }

                if let keyReadProblem {
                    HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(DS.miniFont)
                        Text(keyReadProblem)
                            .font(DS.captionFont)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(DS.error)
                }
            }

            Section("AI Tool Integrations") {
                ForEach(aiTools) { tool in
                    HStack {
                        VStack(alignment: .leading, spacing: DS.hair) {
                            Text(tool.name)
                                .font(DS.bodyMedium)
                            Text(tool.configPath)
                                .font(DS.miniFont)
                                .foregroundStyle(DS.inkGhost)
                                .lineLimit(1)
                                // A path's tail is the part that identifies it —
                                // lose the middle, not the file name, and keep the
                                // whole of it on hover.
                                .truncationMode(.middle)
                                .help(tool.configPath)
                        }

                        Spacer()

                        if !tool.detected {
                            // Detection is a guess from known install locations, so
                            // it must not be the last word: "Not found" with a way
                            // through, rather than "Not installed" and a dead row
                            // for someone who has the app somewhere unusual.
                            HStack(spacing: DS.sm) {
                                Text("Not found")
                                    .font(DS.captionFont)
                                    .foregroundStyle(DS.inkFaint)
                                Button("Connect anyway") { beginConnect(tool) }
                                    .font(DS.captionFont)
                                    .controlSize(.small)
                                    .help("Writes mull into \(tool.configPath), creating it if needed")
                            }
                        } else if tool.configured {
                            HStack(spacing: DS.sm) {
                                HStack(spacing: DS.xs) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DS.recording)
                                    Text("Connected")
                                        .font(DS.captionFont)
                                        .foregroundStyle(DS.recording)
                                }
                                // mull can put itself into someone's AI tooling, so
                                // it must be able to take itself back out — without
                                // that, "Connect" is a one-way door out of the app.
                                Button("Disconnect") { pendingDisconnect = tool }
                                    .font(DS.captionFont)
                                    .controlSize(.small)
                            }
                        } else {
                            // Not a direct write any more: this edits a file mull did
                            // not author (~/.claude.json holds every other MCP server
                            // the user has), so it goes through a sheet that shows the
                            // exact fragment and the exact path first.
                            Button("Connect") { beginConnect(tool) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                }

                // Real handshake — spawns the bundled binary and runs MCP initialize.
                // Same control as the provider test above, so both tests behave
                // identically (spinner, result, retry, dismiss); only the label
                // differs, because they test two different things.
                ConnectionTest(
                    label: "Test mull's MCP server",
                    systemImage: "bolt.horizontal.circle",
                    outcome: $setupOutcome,
                    run: testMCPServer
                )
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
        .onChange(of: provider) { _, v in
            appState.llmProvider = LLMProvider(rawValue: v) ?? .off
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
        case "localopenai": "Local (OpenAI-compatible)"
        default: ""
        }
    }

    private var keyNote: some View {
        HStack(spacing: DS.xs) {
            Image(systemName: "lock.fill")
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
            setupOutcome = .failed(error.localizedDescription)
        }
    }

    private func confirmConnect(_ tool: AIToolSetup.AITool) {
        pendingConnect = nil
        apply(AIToolSetup.setup(tool: tool))
    }

    /// Both config edits report the same way and both re-detect afterwards, so the
    /// row's badge reflects the file rather than what the button assumed.
    private func apply(_ result: Result<String, Error>) {
        switch result {
        case .success(let message):
            setupOutcome = .ok(message)
        case .failure(let error):
            setupOutcome = .failed(error.localizedDescription)
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
                        testOutcome = .failed("No API key entered")
                        return
                    }
                    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)") else {
                        testOutcome = .failed("Could not build the request URL — the key may contain invalid characters")
                        return
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 {
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                        let hasFlash = models.contains { $0.contains("flash") }
                        testOutcome = .ok(hasFlash ? "Gemini Flash available" : "Connected (\(models.count) models)")
                    } else {
                        testOutcome = .failed(Self.httpFailureMessage(code))
                    }

                case "claude":
                    guard let key = KeychainService.loadKey("claude_api_key") else {
                        testOutcome = .failed("No API key entered")
                        return
                    }
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                        testOutcome = .failed("Could not build the request URL")
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
                    testOutcome = code == 200 ? .ok("Connected") : .failed(Self.httpFailureMessage(code))

                case "openai":
                    guard let key = KeychainService.loadKey("openai_api_key") else {
                        testOutcome = .failed("No API key entered")
                        return
                    }
                    guard let url = URL(string: "https://api.openai.com/v1/models") else {
                        testOutcome = .failed("Could not build the request URL")
                        return
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    testOutcome = code == 200 ? .ok("Connected") : .failed(Self.httpFailureMessage(code))

                case "localopenai":
                    let base = localBaseURL.trimmingCharacters(in: .whitespaces)
                    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                    guard let url = URL(string: "\(trimmed)/models") else {
                        testOutcome = .failed("Invalid base URL")
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
                        testOutcome = .ok("Server up, but no model loaded — load one in LM Studio")
                    } else if localModel.isEmpty || models.contains(where: { $0.hasPrefix(localModel) }) {
                        testOutcome = .ok("Ready (\(models.prefix(2).joined(separator: ", ")))")
                    } else {
                        testOutcome = .failed("\(localModel) not loaded. Available: \(models.prefix(3).joined(separator: ", "))")
                    }

                default:
                    guard let url = URL(string: "http://localhost:11434/api/tags") else {
                        testOutcome = .failed("Could not build the request URL")
                        return
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 10
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                    if models.contains(where: { $0.hasPrefix(ollamaModel) }) {
                        testOutcome = .ok("\(ollamaModel) ready")
                    } else {
                        let available = models.prefix(3).joined(separator: ", ")
                        testOutcome = .failed("\(ollamaModel) not found. Available: \(available)")
                    }
                }
            } catch let error as URLError where error.code == .timedOut {
                testOutcome = .failed("Timed out — server not responding")
            } catch let error as URLError where error.code == .cannotConnectToHost {
                testOutcome = .failed("Cannot connect — is the server running?")
            } catch let error as URLError where error.code == .notConnectedToInternet {
                testOutcome = .failed("No internet connection")
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
        case 401: return "Key rejected (401) — check the key; it may be revoked or from the wrong account"
        case 403: return "Access denied (403) — this key lacks permission for the API"
        case 429: return "Quota or rate limit (429) — check billing / usage caps"
        case 500...599: return "Provider error (\(code)) — their side; retry in a moment"
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
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.inkFaint)
                .help(revealed ? "Hide key" : "Show key")
                .accessibilityLabel(revealed ? "Hide key" : "Show key")
                .accessibilityHint("Shows or conceals the API key in plain text")
            }

            if saveFailed {
                HStack(spacing: DS.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DS.miniFont)
                        .foregroundStyle(DS.error)
                    Text("Could not save to Keychain — the key is not stored.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.error)
                }
                .transition(.opacity)
            } else if let tail = savedTail {
                HStack(spacing: DS.xs) {
                    Image(systemName: "checkmark.circle.fill")
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

// MARK: - Data Tab (Permissions + Storage + Cleanup)

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
                permRow("Accessibility", granted: appState.permissions.accessibilityGranted, detail: "Window titles") {
                    appState.permissions.openAccessibilitySettings()
                }
                permRow("Input Monitoring", granted: appState.permissions.inputMonitoringGranted, detail: "Keystrokes") {
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
                            Image(systemName: "exclamationmark.triangle.fill")
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
                            Image(systemName: "exclamationmark.triangle.fill")
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

            // Data sources
            Section("Data Sources") {
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
                    Text("macOS will ask whether mull may control Mail. mull reads the subject and sender of mail received in the last 24 hours — never the body — and keeps them on this Mac. If you decline, nothing is captured and you can turn this on again whenever you like.")
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
                            Image(systemName: "exclamationmark.triangle.fill")
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
                    Text("Subject and sender only. Email body is never read.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                }
            }

            // Per-app exclusion — privacy control. Nothing is captured while an
            // excluded app is frontmost (keystrokes, clipboard, and window titles).
            Section("Don't record in these apps") {
                Text("Only while one of them is frontmost, and it covers everything — keystrokes, clipboard, window titles.")
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
                                Image(systemName: "minus.circle.fill").foregroundStyle(DS.error)
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
                        Image(systemName: "exclamationmark.triangle.fill")
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
                        Image(systemName: "exclamationmark.triangle.fill")
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
                    Image(systemName: cloudProviderName == nil ? "lock.fill" : "arrow.up.forward.app")
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
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
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
        if calendarGranted { return "Your schedule, in now.md and the week view" }
        switch calendarStatus {
        case .notDetermined:
            return "Not asked yet — your schedule is missing from now.md"
        case .denied, .restricted:
            return "Denied — grant it in System Settings, then reopen the week view"
        default:
            // .writeOnly ("Add only"): looks granted, reads nothing. This is the
            // quiet cause of a week view that stays empty for someone certain
            // they said yes.
            return "Add-only access — mull can't read events. Full access needed"
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
    /// This is the same freeze ProfileTab's own comment says was fixed there.
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
        default: "the selected period"
        }
    }

    /// Which cloud vendor, if any, currently receives recorded activity. `nil` means
    /// everything stays local (off, or a local model over localhost).
    /// Reads through `llmProvider` (not `appState`) so the notice redraws the
    /// moment the AI tab changes, but the cloud/local judgement itself lives in
    /// one place — the forget dialog asks the same question and must not be able
    /// to answer it differently.
    private var cloudProviderName: String? {
        AppState.cloudProviderName(for: llmProvider)   // "off"/"ollama"/"local" → nil
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
            cleanupProblem = "The recordings could not be deleted: \(error.localizedDescription)"
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
            problems.append(remains.errorDescription ?? "Quarantined copies of your history could not be deleted.")
        } catch {
            problems.append("The recordings database could not be cleared: \(error.localizedDescription)")
        }
        appState.database.vacuum()
        do {
            try MullDirectory.deleteEverything()
        } catch {
            problems.append("The ~/mull folder could not be removed: \(error.localizedDescription)")
        }
        appState.todayEventCount = appState.database.eventCountToday()
        appState.loadTodaySummary()
        appState.loadRecentSummaries()
        cleanupProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
        Task { await refresh() }
    }
}

