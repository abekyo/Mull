import SwiftUI

/// Surface 2: The main menu bar dropdown panel.
/// Keyboard-first: Search auto-focuses, ⌘A/⌘C/⌘E for actions, Esc to close.
struct MenuBarPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var searchQuery = ""
    @State private var debouncedQuery = ""
    @State private var showAIExport = false
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if appState.isPaused {
                pauseBanner
            }

            SearchBar(query: $searchQuery) {
                NSApp.keyWindow?.close()
            }
            .padding(.horizontal, DS.lg)
            .padding(.top, DS.md)
            .padding(.bottom, DS.sm)
            .onChange(of: searchQuery) { _, newValue in
                searchDebounceTask?.cancel()
                searchDebounceTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    debouncedQuery = newValue
                }
            }

            Divider()

            ScrollView {
                VStack(spacing: DS.sm) {
                    if debouncedQuery.isEmpty {
                        timelineContent
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, DS.lg)
                .padding(.vertical, DS.md)
            }
            .frame(maxHeight: DS.panelMaxHeight)

            Divider()

            footer
        }
        .frame(width: DS.panelWidth)
        .sheet(isPresented: $showAIExport) {
            AIExportSheet()
                .environmentObject(appState)
        }
    }

    // MARK: - Pause Banner

    private var pauseBanner: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(DS.paused)
            Text("Recording paused")
                .font(DS.bodyMedium)
                .foregroundStyle(DS.paused)
            Spacer()
            Button("Resume") {
                appState.isPaused = false
            }
            .font(DS.captionFont)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, DS.lg)
        .padding(.vertical, DS.sm)
        .background(DS.paused.opacity(0.08))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            PrivacyStatusBar()
            Spacer()
            HStack(spacing: DS.sm) {
                keyHint("⇧⌘C", label: "Copy")
                keyHint("⇧⌘D", label: "Open")
                keyHint("Esc", label: "Close")
            }
        }
        .padding(.horizontal, DS.lg)
        .padding(.vertical, DS.sm)
    }

    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 2) {
            Text(key)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, DS.xs)
                .padding(.vertical, 1)
                .background(Color(.controlBackgroundColor).opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 9))
        }
        .foregroundStyle(.quaternary)
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineContent: some View {
        // Permission banner — only shows what's actually missing
        if !appState.permissions.inputMonitoringGranted || !appState.permissions.accessibilityGranted {
            permissionBanner
        }

        todayCard

        ForEach(appState.recentSummaries) { summary in
            if !Calendar.current.isDateInToday(summary.date) {
                PastSummaryCard(summary: summary)
            }
        }

        if appState.todaySummary == nil && appState.recentSummaries.isEmpty {
            emptyState
        }
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.paused)
                Text("Permissions needed")
                    .font(DS.bodyMedium)
            }

            if !appState.permissions.accessibilityGranted {
                permissionRow(
                    name: "Accessibility",
                    detail: "Window titles",
                    action: { appState.permissions.openAccessibilitySettings() }
                )
            }
            if !appState.permissions.inputMonitoringGranted {
                permissionRow(
                    name: "Input Monitoring",
                    detail: "Keyboard recording",
                    action: { appState.permissions.openInputMonitoringSettings() }
                )
            }
        }
        .dreamCard()
    }

    private func permissionRow(name: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.error)

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(DS.bodyFont)
                Text(detail)
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Grant") { action() }
                .font(DS.captionFont)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Mini Insight

    private var miniInsight: some View {
        let topApp = appState.analytics.appUsage(days: 1).first
        let peaks = appState.analytics.peakHours(days: 1)
        let lang = appState.analytics.languageMix(days: 1)

        let insight: String
        if let app = topApp {
            let pct = String(format: "%.0f", app.percentage)
            insight = "\(app.appName) \(pct)% of today"
            if !peaks.isEmpty {
                // More detail
            }
        } else {
            insight = "Recording..."
        }

        let langNote: String
        if lang.japanesePercent > 60 {
            langNote = "Mostly Japanese today"
        } else if lang.englishPercent > 60 {
            langNote = "Mostly English today"
        } else if lang.japanesePercent > 20 && lang.englishPercent > 20 {
            langNote = "Bilingual day"
        } else {
            langNote = ""
        }

        return HStack(spacing: DS.sm) {
            Image(systemName: "sparkle")
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)

            Text([insight, langNote].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(DS.captionFont)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Today's Card

    @ViewBuilder
    private var todayCard: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            // Date header
            Text("TODAY — \(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))")
                .sectionLabel()

            if let summary = appState.todaySummary {
                SummaryContent(summary: summary)
            } else if appState.isSummarizing {
                VStack(alignment: .leading, spacing: DS.xs) {
                    HStack(spacing: DS.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text(appState.whatlyProgress ?? "Analyzing your day...")
                            .font(DS.bodyFont)
                            .foregroundStyle(.secondary)
                    }
                    Text("This takes 30-60 seconds")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, DS.sm)
            } else {
                recordingStatus
            }

            // Mini insight — one interesting fact from today
            if appState.todayEventCount > 20 {
                miniInsight
            }

            ActionBar(showAIExport: $showAIExport)
        }
        .dreamPrimaryCard()
    }

    private var recordingStatus: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Recording indicator + count
            HStack(spacing: DS.sm) {
                Circle()
                    .fill(appState.isRecording ? DS.recording : DS.recording.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .shadow(color: appState.isRecording ? DS.recording.opacity(0.5) : .clear, radius: 4)

                Text("\(appState.todayEventCount)")
                    .font(DS.bodyMedium)
                    .monospacedDigit()
                Text("events captured")
                    .font(DS.bodyFont)
                    .foregroundStyle(.secondary)
            }

            // Show what's being captured RIGHT NOW (proof it works)
            if appState.todayEventCount > 0 {
                recentActivityPreview
            }

            // Dream Now or schedule info
            HStack {
                let dreamHour = UserDefaults.standard.object(forKey: "summaryTime") as? Int ?? 23
                let dreamMin = UserDefaults.standard.object(forKey: "summaryTimeMinute") as? Int ?? 0
                Text("Summary at \(String(format: "%02d:%02d", dreamHour, dreamMin))")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)

                Spacer()

                if appState.todayEventCount > 10 {
                    Button {
                        appState.triggerSummaryNow()
                    } label: {
                        Text("Summarize Now")
                            .font(DS.captionFont)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            if let error = appState.whatlyProgress, error.hasPrefix("Summary failed") {
                Text(error)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.error)
            }
        }
    }

    /// Show last 3 captured items so user can SEE Dream is working.
    /// This is the "proof of life" that builds trust on day one.
    private var recentActivityPreview: some View {
        let events = appState.database.fetchEvents(
            from: Calendar.current.date(byAdding: .minute, value: -30, to: Date())!,
            to: Date()
        ).suffix(3)

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                HStack(spacing: DS.xs) {
                    Circle()
                        .fill(eventColor(event.eventType))
                        .frame(width: 4, height: 4)
                    Text(eventPreview(event))
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, DS.lg) // Indent under the recording dot
    }

    private func eventColor(_ type: RecordingEvent.EventType) -> Color {
        switch type {
        case .keystroke: .blue
        case .clipboard: .orange
        case .screenText: .green
        case .appSwitch: .purple
        case .audio: .pink
        }
    }

    private func eventPreview(_ event: RecordingEvent) -> String {
        let text = event.textContent ?? ""
        let clean = String(text.prefix(50)).replacingOccurrences(of: "\n", with: " ")
        switch event.eventType {
        case .keystroke: return "Typed: \(clean)"
        case .clipboard: return "Copied: \(clean)"
        case .screenText: return clean
        case .appSwitch: return "→ \(event.appName ?? clean)"
        case .audio: return "Audio: \(clean)"
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResults: some View {
        let results = appState.database.searchSummaries(query: debouncedQuery)

        if results.isEmpty {
            VStack(spacing: DS.md) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
                Text("No results for \"\(debouncedQuery)\"")
                    .font(DS.bodyFont)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            ForEach(results) { summary in
                PastSummaryCard(summary: summary, expanded: true, highlightQuery: debouncedQuery)
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS.lg) {
            Image(systemName: "moon.stars")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor.opacity(0.3))

            VStack(spacing: DS.xs) {
                Text("Whatly is recording")
                    .font(DS.titleFont)
                Text("Your first summary will be ready tonight at 23:00.")
                    .font(DS.bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
