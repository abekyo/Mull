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
        }
        .frame(width: 480, height: 460)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("dreamTime") private var dreamTimeHour = 23
    @AppStorage("dreamTimeMinute") private var dreamTimeMinute = 0
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("outputMaxChars") private var outputMaxChars = 50000
    @AppStorage("exportPath") private var exportPath = "~/Dream"
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
            Section("Dream") {
                HStack {
                    Text("Nightly summary at")
                    Spacer()
                    Picker("", selection: $dreamTimeHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .frame(width: 60)
                    .labelsHidden()
                    Text(":")
                    Picker("", selection: $dreamTimeMinute) {
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

                Toggle("Auto-export after each Dream", isOn: $autoExport)
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
        .onChange(of: dreamTimeHour) { _, h in
            appState.dreamEngine.scheduleDream(at: h, minute: dreamTimeMinute)
        }
        .onChange(of: dreamTimeMinute) { _, m in
            appState.dreamEngine.scheduleDream(at: dreamTimeHour, minute: m)
        }
    }
}

// MARK: - AI Tab

struct AITab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("llmProvider") private var provider = "local"
    @AppStorage("ollamaModel") private var ollamaModel = "llama3.2"
    @State private var claudeKey = ""
    @State private var openaiKey = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Provider") {
                Picker("", selection: $provider) {
                    Text("Local (Ollama)").tag("local")
                    Text("Claude API").tag("claude")
                    Text("OpenAI API").tag("openai")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section(providerDetailTitle) {
                switch provider {
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
                default:
                    TextField("Model", text: $ollamaModel)
                    Text("Requires Ollama running locally.")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }

                // Test button
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
                        Text(result)
                            .font(DS.captionFont)
                            .foregroundStyle(result.contains("✓") ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            claudeKey = KeychainService.load(key: "claude_api_key") ?? ""
            openaiKey = KeychainService.load(key: "openai_api_key") ?? ""
        }
        .onChange(of: provider) { _, v in
            switch v {
            case "claude": appState.llmProvider = .claude
            case "openai": appState.llmProvider = .openai
            default: appState.llmProvider = .local
            }
        }
    }

    private var providerDetailTitle: String {
        switch provider {
        case "claude": "Claude API"
        case "openai": "OpenAI API"
        default: "Ollama"
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
                case "claude":
                    guard let key = KeychainService.load(key: "claude_api_key"), !key.isEmpty else {
                        testResult = "✗ No API key"
                        isTesting = false
                        return
                    }
                    let url = URL(string: "https://api.anthropic.com/v1/messages")!
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
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
                        testResult = "✗ No API key"
                        isTesting = false
                        return
                    }
                    let url = URL(string: "https://api.openai.com/v1/models")!
                    var req = URLRequest(url: url)
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    testResult = code == 200 ? "✓ Connected" : "✗ HTTP \(code)"

                default:
                    let url = URL(string: "http://localhost:11434/api/tags")!
                    let (data, _) = try await URLSession.shared.data(from: url)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let models = (json?["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                    if models.contains(where: { $0.hasPrefix(ollamaModel) }) {
                        testResult = "✓ \(ollamaModel) ready"
                    } else {
                        testResult = "✗ Model not found"
                    }
                }
            } catch {
                testResult = "✗ \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}

// MARK: - Data Tab (Permissions + Storage + Cleanup)

struct DataTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("dataRetention") private var dataRetention = "unlimited"
    @AppStorage("analyticsOptIn") private var analyticsOptIn = false

    @State private var eventCount = 0
    @State private var summaryCount = 0
    @State private var memoryCount = 0
    @State private var dbSize = "—"

    @State private var showClearToday = false
    @State private var showClearEvents = false
    @State private var showClearAll = false
    @State private var showAnalyticsDetail = false

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

            // Storage overview
            Section("Storage") {
                statRow("Events", value: eventCount.formatted())
                statRow("Summaries", value: summaryCount.formatted())
                statRow("Memories", value: memoryCount.formatted())
                statRow("Database", value: dbSize)

                HStack {
                    Spacer()
                    Button("Open in Finder") {
                        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                            .first!.appendingPathComponent("Dream")
                        NSWorkspace.shared.open(url)
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
                Toggle("Anonymous usage statistics", isOn: $analyticsOptIn)
                Button("View exactly what's shared") { showAnalyticsDetail = true }
                    .font(DS.captionFont)
                    .sheet(isPresented: $showAnalyticsDetail) { AnalyticsDetailView() }
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
                .foregroundStyle(granted ? .green : .red)
                .font(.system(size: 13))
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
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Dream")
        try? FileManager.default.removeItem(at: dir)
        refresh()
    }
}

// MARK: - Analytics Detail Sheet

struct AnalyticsDetailView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            Text("Exactly what's shared")
                .font(DS.titleFont)

            Text("Anonymous usage data only. Never your content.")
                .font(DS.captionFont)
                .foregroundStyle(.secondary)

            ScrollView {
                Text("""
                {
                  "app_version": "1.0.0",
                  "os": "macOS 15.3",
                  "hardware": "Apple M4",
                  "dream_completed": 1,
                  "dream_duration_seconds": 47,
                  "search_used": 3,
                  "ai_export_used": 1,
                  "recording_events_count": 1247,
                  "plan": "free"
                }
                """)
                .font(DS.microFont)
                .padding(DS.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(DS.xl)
        .frame(width: 380, height: 340)
    }
}
