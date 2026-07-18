import SwiftUI
import ServiceManagement

/// Settings window — 4 tabs, no redundancy.
///
///   General:  Schedule, startup, output size, export destinations
///   AI:       LLM provider, API keys, connection test, MCP client setup
///   Data:     Permissions, data sources, storage, retention, cleanup
///   Profile:  What mull knows about you (Insights) — correctable
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralTab()
                .environmentObject(appState)
                .tabItem { Label("General", systemImage: "gearshape") }

            AITab()
                .environmentObject(appState)
                .tabItem { Label("AI", systemImage: "brain") }

            DataTab()
                .environmentObject(appState)
                .tabItem { Label("Data", systemImage: "externaldrive") }

            InsightsTab()
                .environmentObject(appState)
                .tabItem { Label("Profile", systemImage: "person.text.rectangle") }
        }
        .frame(width: 520, height: 520)
        .tint(DS.moon)   // keep native controls on the warm brand accent
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("summaryTime") private var summaryTimeHour = 23
    @AppStorage("summaryTimeMinute") private var summaryTimeMinute = 0
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("outputMaxChars") private var outputMaxChars = 50000
    @AppStorage("exportPath") private var exportPath = "~/mull"
    @AppStorage("obsidianVault") private var obsidianVault = ""
    @AppStorage("autoExport") private var autoExport = false
    @State private var profileResetDone = false

    private let charOptions = [
        (5000, "5K chars — Minimal"),
        (10000, "10K chars — Light"),
        (50000, "50K chars — Default"),
        (100000, "100K chars — Large"),
        (200000, "200K chars — Full day"),
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
                    Text(":")
                    Picker("", selection: $summaryTimeMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .frame(width: 60)
                    .labelsHidden()
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() }
                        else { try? SMAppService.mainApp.unregister() }
                    }
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
                        .foregroundStyle(.tertiary)
                }

                Toggle("Auto-export after each mull", isOn: $autoExport)
            }

            Section("Export Destinations") {
                HStack {
                    Text("Local folder")
                    Spacer()
                    TextField("", text: $exportPath)
                        .frame(width: 180)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.captionFont)
                }

                HStack {
                    Text("Obsidian vault")
                    Spacer()
                    TextField("optional", text: $obsidianVault)
                        .frame(width: 180)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.captionFont)
                }
            }

            Section("Profile") {
                Text("The questions you answered at setup. They seed me.pinned.md (placed atop me.md, never overwritten). Capture refines the rest.")
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Redo profile questions") {
                        (NSApp.delegate as? AppDelegate)?.showOnboarding(startStep: .profile)
                    }
                    Spacer()
                    Button("Reset answers", role: .destructive) {
                        OnboardingProfile.reset()
                        appState.regenerateContextNow()
                        profileResetDone = true
                    }
                    .disabled(!OnboardingProfile.hasAnswers)
                }

                if profileResetDone {
                    Label("Profile answers cleared from me.pinned.md", systemImage: "checkmark.circle.fill")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.recording)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: summaryTimeHour) { _, h in
            appState.mullEngine.scheduleSummary(at: h, minute: summaryTimeMinute)
        }
        .onChange(of: summaryTimeMinute) { _, m in
            appState.mullEngine.scheduleSummary(at: summaryTimeHour, minute: m)
        }
    }
}

// MARK: - AI Tab

struct AITab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("llmProvider") private var provider = "off"
    @AppStorage("ollamaModel") private var ollamaModel = "llama3.2"
    @AppStorage("localBaseURL") private var localBaseURL = "http://localhost:1234/v1"
    @AppStorage("localModel") private var localModel = ""
    @State private var geminiKey = ""
    @State private var claudeKey = ""
    @State private var openaiKey = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var aiTools: [AIToolSetup.AITool] = []
    @State private var setupResult: String?

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

                if provider == "off" {
                    Text("mull runs fully on-device: rule-based me.md/now.md/full.md keep updating, and nothing is sent anywhere. Pick a provider to enable nightly LLM summaries, per-project deliberation, and Chat — those send data to the chosen service.")
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                } else if LLMProvider(rawValue: provider)?.isCloud == true {
                    Text("⚠️ This provider sends your activity data off-device to process it.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.paused)
                }
            }

            Section(providerDetailTitle) {
                switch provider {
                case "gemini":
                    APIKeyField(placeholder: "API Key (optional)", keychainKey: "gemini_api_key",
                                text: $geminiKey, onSaved: { testConnection() })
                    if geminiKey.isEmpty && !BundledKeys.gemini.isEmpty {
                        HStack(spacing: DS.xs) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(DS.recording)
                            Text("Built-in key active — works out of the box")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.recording)
                        }
                    } else if geminiKey.isEmpty {
                        Text("Enter your key from Google AI Studio, or leave empty for built-in access")
                            .font(DS.captionFont)
                            .foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: DS.xs) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(DS.recording)
                                .font(DS.captionFont)
                            Text("Using your own key — no rate limits")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.recording)
                        }
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
                    Text("Requires Ollama running locally.")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                case "localopenai":
                    TextField("Base URL", text: $localBaseURL)
                    TextField("Model (blank = server's loaded model)", text: $localModel)
                    Text("Any OpenAI-compatible local server. LM Studio: start its Local Server (default http://localhost:1234/v1) and load a model. Also works with Jan, llama.cpp server, vLLM, LocalAI. Stays on-device.")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                default:
                    EmptyView()
                }

                // Test button — not applicable when LLM is off.
                if provider != "off" {
                VStack(alignment: .leading, spacing: DS.sm) {
                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            HStack(spacing: DS.xs) {
                                if isTesting { ProgressView().controlSize(.mini) }
                                Text(isTesting ? "Testing..." : "Test Connection")
                            }
                        }
                        .disabled(isTesting)

                        if let result = testResult {
                            HStack(spacing: DS.xs) {
                                Image(systemName: result.contains("✓") ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.contains("✓") ? DS.recording : DS.error)
                                Text(result)
                                    .font(DS.captionFont)
                                    .foregroundStyle(result.contains("✓") ? DS.recording : DS.error)
                            }
                            .transition(.opacity)
                        }
                    }

                    // Show retry hint on failure
                    if let result = testResult, !result.contains("✓") {
                        HStack(spacing: DS.xs) {
                            Button("Retry") {
                                testConnection()
                            }
                            .font(DS.captionFont)
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Dismiss") {
                                withAnimation { testResult = nil }
                            }
                            .font(DS.captionFont)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: testResult)
                }
            }

            Section("AI Tool Integrations") {
                ForEach(aiTools) { tool in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(DS.bodyMedium)
                            Text(tool.configPath)
                                .font(DS.miniFont)
                                .foregroundStyle(.quaternary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if !tool.detected {
                            Text("Not installed")
                                .font(DS.captionFont)
                                .foregroundStyle(.tertiary)
                        } else if tool.configured {
                            HStack(spacing: DS.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DS.recording)
                                Text("Connected")
                                    .font(DS.captionFont)
                                    .foregroundStyle(DS.recording)
                            }
                        } else {
                            Button("Connect") {
                                let result = AIToolSetup.setup(tool: tool)
                                switch result {
                                case .success(let msg):
                                    setupResult = "✓ \(msg)"
                                    aiTools = AIToolSetup.detectTools()
                                case .failure(let err):
                                    setupResult = "✗ \(err.localizedDescription)"
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }

                // Real handshake — spawns the bundled binary and runs MCP initialize.
                Button {
                    setupResult = "Testing…"
                    Task.detached {
                        let r = AIToolSetup.testConnection()
                        await MainActor.run {
                            switch r {
                            case .success(let m): setupResult = "✓ \(m)"
                            case .failure(let e): setupResult = "✗ \(e.localizedDescription)"
                            }
                        }
                    }
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal.circle")
                }
                .controlSize(.small)

                if let result = setupResult {
                    Text(result)
                        .font(DS.captionFont)
                        .foregroundStyle(result.contains("✓") ? DS.recording : DS.error)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            geminiKey = KeychainService.load(key: "gemini_api_key") ?? ""
            claudeKey = KeychainService.load(key: "claude_api_key") ?? ""
            openaiKey = KeychainService.load(key: "openai_api_key") ?? ""
            aiTools = AIToolSetup.detectTools()
        }
        .onChange(of: provider) { _, v in
            appState.llmProvider = LLMProvider(rawValue: v) ?? .off
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
                .font(.system(size: 8))
            Text("Stored in macOS Keychain")
                .font(DS.captionFont)
        }
        .foregroundStyle(.tertiary)
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            do {
                switch provider {
                case "gemini":
                    guard let key = KeychainService.loadKey("gemini_api_key") else {
                        testResult = "✗ No API key entered"
                        isTesting = false
                        return
                    }
                    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)") else { return }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200 {
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                        let hasFlash = models.contains { $0.contains("flash") }
                        testResult = hasFlash ? "✓ Gemini Flash available" : "✓ Connected (\(models.count) models)"
                    } else {
                        testResult = Self.httpFailureMessage(code)
                    }

                case "claude":
                    guard let key = KeychainService.loadKey("claude_api_key") else {
                        testResult = "✗ No API key entered"
                        isTesting = false
                        return
                    }
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return }
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
                    testResult = code == 200 ? "✓ Connected" : Self.httpFailureMessage(code)

                case "openai":
                    guard let key = KeychainService.loadKey("openai_api_key") else {
                        testResult = "✗ No API key entered"
                        isTesting = false
                        return
                    }
                    guard let url = URL(string: "https://api.openai.com/v1/models") else { return }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 15
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    testResult = code == 200 ? "✓ Connected" : Self.httpFailureMessage(code)

                case "localopenai":
                    let base = localBaseURL.trimmingCharacters(in: .whitespaces)
                    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
                    guard let url = URL(string: "\(trimmed)/models") else {
                        testResult = "✗ Invalid base URL"
                        isTesting = false
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
                        testResult = "✓ Server up, but no model loaded — load one in LM Studio"
                    } else if localModel.isEmpty || models.contains(where: { $0.hasPrefix(localModel) }) {
                        testResult = "✓ Ready (\(models.prefix(2).joined(separator: ", ")))"
                    } else {
                        testResult = "✗ \(localModel) not loaded. Available: \(models.prefix(3).joined(separator: ", "))"
                    }

                default:
                    guard let url = URL(string: "http://localhost:11434/api/tags") else { return }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 10
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                    if models.contains(where: { $0.hasPrefix(ollamaModel) }) {
                        testResult = "✓ \(ollamaModel) ready"
                    } else {
                        let available = models.prefix(3).joined(separator: ", ")
                        testResult = "✗ \(ollamaModel) not found. Available: \(available)"
                    }
                }
            } catch let error as URLError where error.code == .timedOut {
                testResult = "✗ Timed out — server not responding"
            } catch let error as URLError where error.code == .cannotConnectToHost {
                testResult = "✗ Cannot connect — is the server running?"
            } catch let error as URLError where error.code == .notConnectedToInternet {
                testResult = "✗ No internet connection"
            } catch {
                let msg = error.localizedDescription
                testResult = "✗ \(msg.count > 60 ? String(msg.prefix(60)) + "…" : msg)"
            }
            isTesting = false
        }
    }

    /// Status-code-specific guidance — "HTTP 401" tells the user nothing actionable.
    private static func httpFailureMessage(_ code: Int) -> String {
        switch code {
        case 401: return "✗ Key rejected (401) — check the key; it may be revoked or from the wrong account"
        case 403: return "✗ Access denied (403) — this key lacks permission for the API"
        case 429: return "✗ Quota or rate limit (429) — check billing / usage caps"
        case 500...599: return "✗ Provider error (\(code)) — their side; retry in a moment"
        default: return "✗ HTTP \(code)"
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
                .foregroundStyle(.tertiary)
                .help(revealed ? "Hide key" : "Show key")
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
    @AppStorage("dataRetention") private var dataRetention = "unlimited"
    @AppStorage("emailCaptureEnabled") private var emailCaptureEnabled = false

    @State private var eventCount = 0
    @State private var summaryCount = 0
    @State private var memoryCount = 0
    @State private var dbSize = "—"

    @State private var showClearToday = false
    @State private var showClearEvents = false
    @State private var showClearAll = false

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
                permRow("Clipboard", granted: true, detail: "Always available") {}
            }

            // Data sources
            Section("Data Sources") {
                Toggle("Email (Mail.app)", isOn: $emailCaptureEnabled)
                    .onChange(of: emailCaptureEnabled) { _, enabled in
                        appState.email.refreshState()
                    }
                Text("Subject and sender only. Email body is never read.")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }

            // Per-app exclusion — privacy control. Nothing is captured while an
            // excluded app is frontmost (keystrokes, clipboard, and window titles).
            Section("Don't record in these apps") {
                Text("While one of these is frontmost, mull captures nothing — no keystrokes, clipboard, or window titles.")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)

                ForEach(appState.excludedAppList, id: \.id) { app in
                    HStack {
                        Text(app.name).font(DS.bodyFont)
                        Spacer()
                        if app.id == "com.mull.app" {
                            Text("always").font(DS.captionFont).foregroundStyle(.tertiary)
                        } else {
                            Button {
                                appState.includeApp(app.id)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(DS.error)
                            }
                            .buttonStyle(.plain)
                            .help("Resume recording in \(app.name)")
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
                statRow("Events", value: eventCount.formatted())
                statRow("Summaries", value: summaryCount.formatted())
                statRow("Memories", value: memoryCount.formatted())
                statRow("Database", value: dbSize)

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
                Picker("Keep raw events for", selection: $dataRetention) {
                    Text("7 days").tag("7")
                    Text("30 days").tag("30")
                    Text("90 days").tag("90")
                    Text("1 year").tag("365")
                    Text("Unlimited").tag("unlimited")
                }
                .onChange(of: dataRetention) { _, v in
                    guard v != "unlimited", let days = Int(v) else { return }
                    try? appState.database.deleteEventsOlderThan(days: days)
                    refresh()
                }
            }

            // Cleanup
            Section("Cleanup") {
                Button("Clear today's recordings") { showClearToday = true }
                    .confirmationDialog("Clear today?", isPresented: $showClearToday) {
                        Button("Clear Today", role: .destructive) { clearToday() }
                    } message: { Text("Removes today's events. Summaries are kept.") }

                Button("Clear all events") { showClearEvents = true }
                    .confirmationDialog("Clear all events?", isPresented: $showClearEvents) {
                        Button("Clear Events", role: .destructive) { clearEvents() }
                    } message: { Text("Removes all events. Summaries and memories are kept.") }

                Button(role: .destructive) { showClearAll = true } label: {
                    Text("Delete everything")
                }
                .confirmationDialog("Delete everything?", isPresented: $showClearAll) {
                    Button("Delete Everything", role: .destructive) { deleteAll() }
                } message: { Text("Permanently deletes all data. Cannot be undone.") }
            }

            // Privacy
            Section("Privacy") {
                Label("mull collects no usage data — nothing is ever sent.", systemImage: "lock.shield")
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refresh() }
    }

    // MARK: - Helpers

    private func permRow(_ name: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? DS.recording : DS.error)
                .font(DS.bodyFont)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(DS.bodyFont)
                Text(detail).font(DS.captionFont).foregroundStyle(.tertiary)
            }
            Spacer()
            if !granted {
                Button("Grant") { action() }
                    .font(DS.captionFont)
                    .controlSize(.small)
            }
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(DS.bodyFont)
            Spacer()
            Text(value).font(DS.microFont).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        eventCount = appState.database.eventCountToday()
        summaryCount = appState.database.fetchRecentSummaries(limit: 9999).count
        memoryCount = appState.database.fetchAllMemories().count
        dbSize = ByteCountFormatter.string(fromByteCount: appState.database.totalStorageBytes(), countStyle: .file)
    }

    private func clearToday() {
        let start = Calendar.current.startOfDay(for: Date())
        // Deletion belongs to the database layer, not to a View writing raw SQL
        // against the pool — the FTS shadow tables have to stay in step with it.
        try? appState.database.deleteEvents(since: start)
        appState.todayEventCount = 0
        refresh()
    }

    private func clearEvents() {
        try? appState.database.deleteEvents(since: .distantPast)
        appState.database.vacuum()
        appState.todayEventCount = 0
        refresh()
    }

    private func deleteAll() {
        try? appState.database.deleteAllData()
        appState.database.vacuum()
        appState.todaySummary = nil
        appState.todayEventCount = 0
        appState.loadRecentSummaries()
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("mull")
        try? FileManager.default.removeItem(at: dir)
        refresh()
    }
}

