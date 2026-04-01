import SwiftUI

/// Surface 4: Full window — the "second brain" dashboard.
///
/// Not just a timeline viewer. This is where Dream proactively shows you
/// what it understands about you. Three tabs:
///
///   1. Live — Real-time view of what's being recorded right now
///   2. Insights — AI-generated analysis of your patterns (after Dream runs)
///   3. Timeline — Daily summaries archive
struct FullWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: DashboardTab = .live
    @State private var showAIExport = false

    enum DashboardTab: String, CaseIterable {
        case live = "Live"
        case insights = "Insights"
        case timeline = "Timeline"

        var icon: String {
            switch self {
            case .live: "record.circle"
            case .insights: "brain.head.profile"
            case .timeline: "calendar"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(duration: 0.2)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12))
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Actions
                Button {
                    showAIExport = true
                } label: {
                    Label("AI に渡す", systemImage: "brain.head.profile")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.small)
                .keyboardShortcut("a", modifiers: .command)

                Button {
                    appState.triggerDreamNow()
                } label: {
                    Label("Dream Now", systemImage: "moon.stars")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isDreaming || appState.todayEventCount == 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.controlBackgroundColor).opacity(0.5))

            Divider()

            // Content
            switch selectedTab {
            case .live:
                LiveTab()
                    .environmentObject(appState)
            case .insights:
                InsightsTab()
                    .environmentObject(appState)
            case .timeline:
                TimelineTab()
                    .environmentObject(appState)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .sheet(isPresented: $showAIExport) {
            AIExportSheet()
                .environmentObject(appState)
        }
    }
}

// MARK: - Live Tab (Real-time recording view)

struct LiveTab: View {
    @EnvironmentObject var appState: AppState
    @State private var liveEvents: [RecordingEvent] = []
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                Circle()
                    .fill(appState.isRecording ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(appState.isRecording ? "Recording" : "Stopped")
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Text("\(appState.todayEventCount) events today")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text(appState.todayStorageFormatted)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            // Live event stream
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(liveEvents.enumerated()), id: \.offset) { index, event in
                            LiveEventRow(event: event)
                                .id(index)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: liveEvents.count) { _, _ in
                    if let last = liveEvents.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .onAppear { startRefresh() }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private func startRefresh() {
        loadEvents()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            loadEvents()
        }
    }

    private func loadEvents() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        // Show last 100 events
        let all = appState.database.fetchEvents(from: startOfDay, to: Date())
        liveEvents = Array(all.suffix(100))
    }
}

struct LiveEventRow: View {
    let event: RecordingEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Time
            Text(timeString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .trailing)

            // Type indicator
            Circle()
                .fill(typeColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            // Content
            VStack(alignment: .leading, spacing: 1) {
                if let app = event.appName {
                    Text(app)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text(event.textContent ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: event.timestamp)
    }

    private var typeColor: Color {
        switch event.eventType {
        case .keystroke: .blue
        case .clipboard: .orange
        case .screenText: .green
        case .appSwitch: .purple
        case .audio: .pink
        }
    }
}

// MARK: - Insights Tab (AI analysis)

struct InsightsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var keywords: [KeywordStat] = []
    @State private var phrases: [KeywordStat] = []
    @State private var appUsage: [AppUsageStat] = []
    @State private var hourly: [HourlyStat] = []
    @State private var weekday: [WeekdayStat] = []
    @State private var langMix: LanguageMix = LanguageMix(japanesePercent: 0, englishPercent: 0, codePercent: 0)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Dream summary (if available)
                if let summary = appState.todaySummary {
                    card(title: "Today's Dream") {
                        SummaryContent(summary: summary)
                    }
                }

                // Two-column layout for analytics
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        keywordsCard
                        phrasesCard
                        languageCard
                    }
                    VStack(spacing: 16) {
                        appUsageCard
                        hourlyCard
                        weekdayCard
                    }
                }

                // Memory
                memoryCard
            }
            .padding(20)
        }
        .onAppear { refreshAnalytics() }
    }

    private func refreshAnalytics() {
        let engine = appState.analytics
        keywords = engine.topKeywords(days: 7, limit: 20)
        phrases = engine.topPhrases(days: 7, limit: 10)
        appUsage = engine.appUsage(days: 7)
        hourly = engine.hourlyPattern(days: 7)
        weekday = engine.weekdayPattern(days: 30)
        langMix = engine.languageMix(days: 7)
    }

    // MARK: - Cards

    private var keywordsCard: some View {
        card(title: "Top Keywords (7 days)") {
            if keywords.isEmpty {
                Text("Not enough data yet").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(keywords.prefix(15)) { kw in
                        HStack(spacing: 3) {
                            Text(kw.word)
                                .font(.system(size: 11))
                            Text("\(kw.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(Double(kw.count) / Double(max(keywords.first?.count ?? 1, 1)) * 0.2 + 0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    private var phrasesCard: some View {
        card(title: "Repeated Phrases") {
            if phrases.isEmpty {
                Text("Patterns emerge after a few days").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                ForEach(phrases) { phrase in
                    HStack {
                        Text("\"\(phrase.word)\"")
                            .font(.system(size: 11))
                        Spacer()
                        Text("\(phrase.count)x")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var appUsageCard: some View {
        card(title: "App Usage (7 days)") {
            ForEach(Array(appUsage.prefix(8))) { app in
                HStack(spacing: 8) {
                    Text(app.appName)
                        .font(.system(size: 11))
                        .frame(width: 80, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: geo.size.width * app.percentage / 100)
                    }
                    .frame(height: 8)
                    Text(String(format: "%.0f%%", app.percentage))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                }
                .frame(height: 16)
            }
        }
    }

    private var hourlyCard: some View {
        card(title: "Activity by Hour") {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hourly) { h in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor.opacity(h.intensity * 0.8 + 0.1))
                            .frame(width: 8, height: max(2, h.intensity * 40))
                        if h.hour % 6 == 0 {
                            Text("\(h.hour)")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(height: 55)

            let peaks = appState.analytics.peakHours(days: 7)
            if !peaks.isEmpty {
                Text("Peak: \(peaks.map { "\($0):00" }.joined(separator: ", "))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var weekdayCard: some View {
        card(title: "Activity by Day (30 days)") {
            HStack(spacing: 8) {
                ForEach(weekday) { day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(day.intensity * 0.7 + 0.1))
                            .frame(width: 24, height: max(4, day.intensity * 30))
                        Text(day.name)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 50)
        }
    }

    private var languageCard: some View {
        card(title: "Language Mix") {
            HStack(spacing: 0) {
                if langMix.japanesePercent > 0 {
                    Rectangle()
                        .fill(Color.red.opacity(0.6))
                        .frame(width: langMix.japanesePercent * 2)
                }
                if langMix.englishPercent > 0 {
                    Rectangle()
                        .fill(Color.blue.opacity(0.6))
                        .frame(width: langMix.englishPercent * 2)
                }
                if langMix.codePercent > 0 {
                    Rectangle()
                        .fill(Color.green.opacity(0.6))
                        .frame(width: langMix.codePercent * 2)
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            HStack(spacing: 12) {
                legendDot(color: .red, label: "Japanese \(String(format: "%.0f", langMix.japanesePercent))%")
                legendDot(color: .blue, label: "English \(String(format: "%.0f", langMix.englishPercent))%")
                legendDot(color: .green, label: "Code \(String(format: "%.0f", langMix.codePercent))%")
            }
        }
    }

    private var memoryCard: some View {
        let memories = appState.database.fetchAllMemories()

        return card(title: "What Dream Knows About You") {
            if memories.isEmpty {
                Text("Dream will learn about you after the first nightly run.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(memories) { memory in
                    HStack(alignment: .top, spacing: 8) {
                        Text(memory.memoryType.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(memory.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(memory.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color.opacity(0.6)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

/// Simple flow layout for keyword tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

// MARK: - Timeline Tab (Daily summaries archive)

struct TimelineTab: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDate = Date()
    @State private var searchQuery = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 16) {
                DatePicker("", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, 8)

                Button {
                    selectedDate = Date()
                } label: {
                    Label("Today", systemImage: "calendar")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 12)

                Spacer()
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(appState.recentSummaries) { summary in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(summary.dateFormatted.uppercased())
                                .font(.system(size: 12, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(.secondary)

                            SummaryContent(summary: summary)

                            HStack {
                                Label("\(summary.eventCount) events", systemImage: "waveform.path")
                                Spacer()
                                Label(String(format: "%.0fs", summary.processingSeconds), systemImage: "clock")
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        }
                        .id(summary.dateShort)
                        .padding(16)
                        .background(Color(.controlBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if appState.recentSummaries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "moon.stars")
                                .font(.system(size: 32))
                                .foregroundStyle(Color.accentColor.opacity(0.4))
                            Text("No Dreams yet")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                }
                .padding(20)
            }
        }
    }
}

// MARK: - Helper

extension DailySummary {
    static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
