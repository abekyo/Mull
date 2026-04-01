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
                keyHint("⌘A", label: "AI")
                keyHint("⌘C", label: "Copy")
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
            // Title
            HStack(spacing: DS.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.paused)
                Text("Permissions needed")
                    .font(DS.bodyMedium)
            }

            // Status per permission
            permissionRow(
                name: "Accessibility",
                granted: appState.permissions.accessibilityGranted,
                detail: "Window titles",
                action: { appState.permissions.openAccessibilitySettings() }
            )
            permissionRow(
                name: "Input Monitoring",
                granted: appState.permissions.inputMonitoringGranted,
                detail: "Keyboard recording",
                action: { appState.permissions.openInputMonitoringSettings() }
            )
            permissionRow(
                name: "Clipboard",
                granted: true,
                detail: "Copy/paste",
                action: nil
            )
        }
        .dreamCard()
    }

    private func permissionRow(name: String, granted: Bool, detail: String, action: (() -> Void)?) -> some View {
        HStack(spacing: DS.sm) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(granted ? DS.recording : DS.error)

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(DS.bodyFont)
                Text(detail)
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !granted, let action {
                Button("Grant") { action() }
                    .font(DS.captionFont)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
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
            } else if appState.isDreaming {
                HStack(spacing: DS.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.dreamProgress ?? "Dreaming...")
                        .font(DS.bodyFont)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.sm)
            } else {
                recordingStatus
            }

            ActionBar(showAIExport: $showAIExport)
        }
        .dreamPrimaryCard()
    }

    private var recordingStatus: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                // Pulsing recording dot
                Circle()
                    .fill(appState.isRecording ? DS.recording : DS.recording.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .shadow(color: appState.isRecording ? DS.recording.opacity(0.5) : .clear, radius: 4)

                Text("\(appState.todayEventCount) events")
                    .font(DS.bodyMedium)
                    .monospacedDigit()

                Text("recorded")
                    .font(DS.bodyFont)
                    .foregroundStyle(.secondary)
            }

            if appState.todayEventCount > 0 {
                HStack {
                    Text("Dream runs at 23:00")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        appState.triggerDreamNow()
                    } label: {
                        Text("Dream Now")
                            .font(DS.captionFont)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            } else {
                Text("Dream runs at 23:00")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }

            if let error = appState.dreamProgress, error.hasPrefix("Dream failed") {
                Text(error)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.error)
            }
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
                Text("Dream is recording")
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
