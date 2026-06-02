import SwiftUI
import ServiceManagement

/// Settings window — 3 tabs, no redundancy.
///
///   General:  Schedule, startup, output size, export destinations
///   AI:       LLM provider, API keys, connection test
///   Data:     Permissions, storage, retention, cleanup
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
                    SecureField("API Key (optional)", text: $geminiKey)
                        .onChange(of: geminiKey) { _, v in
                            KeychainService.save(key: "gemini_api_key", value: v)
                        }
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
                    SecureField("API Key", text: $claudeKey)
                        .onChange(of: claudeKey) { _, v in
                            KeychainService.save(key: "claude_api_key", value: v)
                        }
                    keyNote
                case "openai":
                    SecureField("API Key", text: $openaiKey)
                        .onChange(of: openaiKey) { _, v in
                            KeychainService.save(key: "openai_api_key", value: v)
                        }
                    keyNote
                case "local":
                    TextField("Model", text: $ollamaModel)
                    Text("Requires Ollama running locally.")
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
                            Button("Setup") {
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
            switch v {
            case "gemini": appState.llmProvider = .gemini
            case "claude": appState.llmProvider = .claude
            case "openai": appState.llmProvider = .openai
            default: appState.llmProvider = .local
            }
        }
    }

    private var providerDetailTitle: String {
        switch provider {
        case "off": "On-device"
        case "gemini": "Gemini"
        case "claude": "Claude API"
        case "openai": "OpenAI API"
        case "local": "Ollama"
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
                    guard let key = KeychainService.load(key: "gemini_api_key"), !key.isEmpty else {
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
                        testResult = "✗ HTTP \(code)"
                    }

                case "claude":
                    guard let key = KeychainService.load(key: "claude_api_key"), !key.isEmpty else {
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
                    testResult = code == 200 ? "✓ Connected" : "✗ HTTP \(code)"

                case "openai":
                    guard let key = KeychainService.load(key: "openai_api_key"), !key.isEmpty else {
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
                    testResult = code == 200 ? "✓ Connected" : "✗ HTTP \(code)"

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
        try? appState.database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events WHERE timestamp >= ?", arguments: [start])
        }
        appState.todayEventCount = 0
        refresh()
    }

    private func clearEvents() {
        try? appState.database.dbPool.write { db in
            try db.execute(sql: "DELETE FROM recording_events")
        }
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

