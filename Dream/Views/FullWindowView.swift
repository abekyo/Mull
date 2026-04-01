import SwiftUI

/// The Dream dashboard — three tabs designed to make you feel understood.
///
/// Live:     Real-time proof Dream is watching (builds trust)
/// Insights: The "wow" moment — Dream shows you patterns about yourself
/// Timeline: Daily summaries archive
struct FullWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: DashboardTab = .insights
    @State private var showAIExport = false

    enum DashboardTab: String, CaseIterable {
        case live = "Live"
        case insights = "Insights"
        case files = "Files"
        case timeline = "Timeline"

        var icon: String {
            switch self {
            case .live: "waveform"
            case .insights: "sparkles"
            case .files: "doc.text"
            case .timeline: "calendar"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 2) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(duration: 0.25)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: DS.xs) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                            Text(tab.rawValue)
                                .font(DS.bodyMedium)
                        }
                        .padding(.horizontal, DS.lg)
                        .padding(.vertical, DS.sm)
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.1)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    showAIExport = true
                } label: {
                    Label("Copy to AI", systemImage: "brain.head.profile")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .controlSize(.small)

                Button {
                    appState.triggerDreamNow()
                } label: {
                    Label("Summarize", systemImage: "moon.stars")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isDreaming || appState.todayEventCount == 0)
            }
            .padding(.horizontal, DS.xl)
            .padding(.vertical, DS.sm)

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .live:
                    LiveTab()
                        .environmentObject(appState)
                case .insights:
                    InsightsTab()
                        .environmentObject(appState)
                case .files:
                    FilesTab()
                        .environmentObject(appState)
                case .timeline:
                    TimelineTab()
                        .environmentObject(appState)
                }
            }
            .transition(.opacity)
        }
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $showAIExport) {
            AIExportSheet()
                .environmentObject(appState)
        }
    }
}

// MARK: - Live Tab
//
// Not a debug log. An aquarium.
// You see your digital life flowing by, quietly.
// The purpose: "I can see exactly what Dream captures. Nothing scary. I trust it."

struct LiveTab: View {
    @EnvironmentObject var appState: AppState
    @State private var liveEvents: [RecordingEvent] = []
    @State private var refreshTimer: Timer?
    @State private var currentApp: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Current state — large, calm, centered
            currentStateHeader

            // The stream — events gently appear from the bottom
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    // Breathing space at top
                    Color.clear.frame(height: DS.xl)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(liveEvents.enumerated()), id: \.offset) { index, event in
                            LiveEventBubble(event: event, isLatest: index == liveEvents.count - 1)
                                .id(index)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.horizontal, DS.xl)

                    // Breathing space at bottom
                    Color.clear.frame(height: DS.xxl)
                        .id("bottom")
                }
                .onChange(of: liveEvents.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.4)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            // Footer — what Dream sees right now
            Divider()
            captureFooter
        }
        .background(Color(.textBackgroundColor))
        .onAppear { startRefresh() }
        .onDisappear { refreshTimer?.invalidate() }
    }

    // MARK: - Current State (large, calm)

    private var currentStateHeader: some View {
        VStack(spacing: DS.md) {
            HStack(spacing: DS.md) {
                // Recording pulse
                ZStack {
                    if appState.isRecording {
                        Circle()
                            .fill(DS.recording.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Circle()
                            .fill(DS.recording.opacity(0.3))
                            .frame(width: 18, height: 18)
                    }
                    Circle()
                        .fill(appState.isRecording ? DS.recording : DS.error)
                        .frame(width: 10, height: 10)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.isRecording ? "Dream is listening" : "Recording stopped")
                        .font(DS.titleFont)
                    Text("Everything you type, copy, and open is being remembered")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // Stats — quiet, right-aligned
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(appState.todayEventCount)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                    Text("events today")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.lg)
    }

    // MARK: - Capture Footer (what's happening right now)

    private var captureFooter: some View {
        HStack(spacing: DS.xl) {
            captureType(icon: "keyboard", label: "Keyboard", color: .blue, active: true)
            captureType(icon: "doc.on.clipboard", label: "Clipboard", color: .orange, active: true)
            captureType(icon: "macwindow", label: "Windows", color: .green, active: true)
            captureType(icon: "calendar", label: "Calendar", color: .red, active: true)
            captureType(icon: "envelope", label: "Email", color: .purple, active: appState.email.isEnabled)
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.md)
    }

    private func captureType(icon: String, label: String, color: Color, active: Bool) -> some View {
        VStack(spacing: DS.xs) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(active ? color : .quaternary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(active ? .secondary : .quaternary)
        }
    }

    // MARK: - Data

    private func startRefresh() {
        loadEvents()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            loadEvents()
        }
    }

    private func loadEvents() {
        let start = Calendar.current.startOfDay(for: Date())
        let all = appState.database.fetchEvents(from: start, to: Date())
        let new = Array(all.suffix(100))
        if new.count != liveEvents.count {
            withAnimation(.easeInOut(duration: 0.3)) {
                liveEvents = new
            }
        }
    }
}

// MARK: - Event Bubble (not a log line — a gentle bubble)

struct LiveEventBubble: View {
    let event: RecordingEvent
    let isLatest: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.md) {
            // Time — whisper quiet
            Text(timeStr)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isLatest ? .tertiary : .quaternary)
                .frame(width: 52, alignment: .trailing)

            // Type indicator — soft color bar instead of dot
            RoundedRectangle(cornerRadius: 1.5)
                .fill(typeColor.opacity(isLatest ? 0.6 : 0.3))
                .frame(width: 3)
                .frame(minHeight: 24)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // App name + type in one line
                HStack(spacing: DS.xs) {
                    if let app = event.appName {
                        Text(app)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isLatest ? .secondary : .tertiary)
                    }
                    Text(typeLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }

                // The content itself
                Text(cleanedContent)
                    .font(.system(size: 13))
                    .foregroundStyle(isLatest ? .primary : (isHovered ? .primary : .secondary))
                    .lineLimit(isHovered ? 10 : 2)
                    .textSelection(.enabled)
                    .lineSpacing(2)
            }

            Spacer()
        }
        .padding(.vertical, DS.xs)
        .padding(.trailing, DS.xl)
        .background(
            isLatest
                ? Color.accentColor.opacity(0.03)
                : (isHovered ? Color.primary.opacity(0.02) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private var timeStr: String {
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

    private var typeLabel: String {
        switch event.eventType {
        case .keystroke: "typed"
        case .clipboard: "copied"
        case .screenText: "opened"
        case .appSwitch: "switched"
        case .audio: "heard"
        }
    }

    private var cleanedContent: String {
        let raw = event.textContent ?? ""
        return raw.replacingOccurrences(of: "\\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Insights Tab (the "wow" tab)

struct InsightsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var keywords: [KeywordStat] = []
    @State private var appUsage: [AppUsageStat] = []
    @State private var hourly: [HourlyStat] = []
    @State private var weekday: [WeekdayStat] = []
    @State private var langMix = LanguageMix(japanesePercent: 0, englishPercent: 0, codePercent: 0)
    @State private var facts: [Fact] = []

    var body: some View {
        ScrollView {
            VStack(spacing: DS.lg) {
                // Hero: identity card
                heroCard
                    .padding(.horizontal, DS.xl)
                    .padding(.top, DS.lg)

                // Schedule (if available)
                if let schedule = appState.calendar.todaySchedule() {
                    scheduleCard(schedule)
                        .padding(.horizontal, DS.xl)
                }

                // Dream summary (if available)
                if let summary = appState.todaySummary {
                    summaryCard(summary)
                        .padding(.horizontal, DS.xl)
                }

                // Analytics grid — equal height rows
                HStack(alignment: .top, spacing: DS.md) {
                    activityHeatmap.frame(maxWidth: .infinity)
                    weekdayChart.frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.xl)

                HStack(alignment: .top, spacing: DS.md) {
                    languageCard.frame(maxWidth: .infinity)
                    appUsageCard.frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.xl)

                // Keywords — full width
                keywordsCard
                    .padding(.horizontal, DS.xl)

                // What Dream knows — full width
                memoryCard
                    .padding(.horizontal, DS.xl)
                    .padding(.bottom, DS.xl)
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        let engine = appState.analytics
        keywords = engine.topKeywords(days: 7, limit: 20)
        appUsage = engine.appUsage(days: 7)
        hourly = engine.hourlyPattern(days: 7)
        weekday = engine.weekdayPattern(days: 30)
        langMix = engine.languageMix(days: 7)
        facts = FactExtractor(analytics: engine, database: appState.database).extractFacts(days: 7)
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(spacing: DS.md) {
            // Big identity statement
            HStack(spacing: DS.md) {
                ZStack {
                    Circle()
                        .fill(DS.accentGradient)
                        .frame(width: 48, height: 48)
                    Image(systemName: "person.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: DS.xs) {
                    Text("Your Profile")
                        .font(DS.titleFont)

                    if facts.isEmpty {
                        Text("Dream is still learning about you...")
                            .font(DS.captionFont)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(appState.todayEventCount)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                    Text("events today")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
            }

            // Facts as tags
            if !facts.isEmpty {
                FlowLayout(spacing: DS.xs) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        factTag(fact)
                    }
                }
            }
        }
        .dreamHeroCard()
    }

    private func factTag(_ fact: Fact) -> some View {
        HStack(spacing: DS.xs) {
            Image(systemName: factIcon(fact.category))
                .font(.system(size: 8))
                .foregroundStyle(factColor(fact.category))
            Text(fact.text)
                .font(.system(size: 11))
        }
        .padding(.horizontal, DS.sm)
        .padding(.vertical, DS.xs)
        .background(factColor(fact.category).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
    }

    private func factIcon(_ category: FactCategory) -> String {
        switch category {
        case .identity: "person.fill"
        case .skills: "wrench.fill"
        case .projects: "folder.fill"
        case .patterns: "clock.fill"
        }
    }

    private func factColor(_ category: FactCategory) -> Color {
        switch category {
        case .identity: .blue
        case .skills: .green
        case .projects: .orange
        case .patterns: .purple
        }
    }

    // MARK: - Schedule Card

    private func scheduleCard(_ schedule: String) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(Color.accentColor)
                Text("Today's Schedule")
                    .font(DS.titleFont)
            }

            let lines = schedule.components(separatedBy: "\n").dropFirst() // Skip "Today's schedule:" header
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let isNow = line.contains("← NOW")
                let isSoon = line.contains("← in")

                HStack(spacing: DS.sm) {
                    Circle()
                        .fill(isNow ? DS.recording : (isSoon ? DS.paused : Color.secondary.opacity(0.3)))
                        .frame(width: 6, height: 6)

                    Text(line.replacingOccurrences(of: "- ", with: ""))
                        .font(isNow ? DS.bodyMedium : DS.bodyFont)
                        .foregroundStyle(isNow ? .primary : .secondary)
                }
            }
        }
        .dreamCard()
    }

    // MARK: - Summary Card

    private func summaryCard(_ summary: DailySummary) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Today's Dream")
                    .font(DS.titleFont)
                Spacer()
                Text(String(format: "%.0fs", summary.processingSeconds))
                    .font(DS.microFont)
                    .foregroundStyle(.tertiary)
            }

            SummaryContent(summary: summary)
        }
        .dreamCard()
    }

    // MARK: - Activity Heatmap (hourly)

    private var activityHeatmap: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("ACTIVITY")
                .sectionLabel()

            // 24-hour bar chart
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hourly) { h in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor(intensity: h.intensity))
                            .frame(width: 10, height: max(3, h.intensity * 50))

                        if h.hour % 6 == 0 {
                            Text("\(h.hour)")
                                .font(.system(size: 8))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
            .frame(height: 65)

            let peaks = hourly.sorted { $0.eventCount > $1.eventCount }.prefix(3).map { "\($0.hour):00" }
            if !peaks.isEmpty {
                Text("Peak: \(peaks.joined(separator: ", "))")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }
        }
        .dreamCard()
    }

    private func barColor(intensity: Double) -> Color {
        if intensity > 0.7 { return Color.accentColor }
        if intensity > 0.3 { return Color.accentColor.opacity(0.6) }
        return Color.accentColor.opacity(0.15)
    }

    // MARK: - Weekday Chart

    private var weekdayChart: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("WEEK")
                .sectionLabel()

            HStack(spacing: DS.sm) {
                ForEach(weekday) { day in
                    VStack(spacing: DS.xs) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(intensity: day.intensity))
                            .frame(width: 28, height: max(4, day.intensity * 40))

                        Text(day.name)
                            .font(.system(size: 9))
                            .foregroundStyle(day.intensity > 0.7 ? .primary : .tertiary)
                    }
                }
            }
            .frame(height: 60)

            let busiest = weekday.max(by: { $0.eventCount < $1.eventCount })
            if let b = busiest {
                Text("Busiest: \(b.name)")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }
        }
        .dreamCard()
    }

    // MARK: - Language Mix

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("LANGUAGE")
                .sectionLabel()

            // Segmented bar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if langMix.japanesePercent > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red.opacity(0.65))
                            .frame(width: geo.size.width * langMix.japanesePercent / 100)
                    }
                    if langMix.englishPercent > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue.opacity(0.55))
                            .frame(width: geo.size.width * langMix.englishPercent / 100)
                    }
                    if langMix.codePercent > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green.opacity(0.55))
                            .frame(width: geo.size.width * langMix.codePercent / 100)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 14)

            HStack(spacing: DS.md) {
                langLabel(color: .red, name: "日本語", pct: langMix.japanesePercent)
                langLabel(color: .blue, name: "English", pct: langMix.englishPercent)
                langLabel(color: .green, name: "Code", pct: langMix.codePercent)
            }
        }
        .dreamCard()
    }

    private func langLabel(color: Color, name: String, pct: Double) -> some View {
        HStack(spacing: DS.xs) {
            Circle().fill(color.opacity(0.65)).frame(width: 6, height: 6)
            Text("\(name) \(String(format: "%.0f", pct))%")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - App Usage

    private var appUsageCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("APPS")
                .sectionLabel()

            ForEach(Array(appUsage.prefix(5))) { app in
                HStack(spacing: DS.sm) {
                    Text(app.appName)
                        .font(.system(size: 11))
                        .frame(width: 60, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.5))
                            .frame(width: geo.size.width * app.percentage / 100)
                    }
                    .frame(height: 8)

                    Text(String(format: "%.0f%%", app.percentage))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                }
                .frame(height: 18)
            }
        }
        .dreamCard()
    }

    // MARK: - Keywords

    private var keywordsCard: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("TOP KEYWORDS")
                .sectionLabel()

            if keywords.isEmpty {
                Text("Keywords appear after a few hours of recording")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: DS.xs) {
                    ForEach(keywords.prefix(15)) { kw in
                        let maxCount = keywords.first?.count ?? 1
                        let intensity = Double(kw.count) / Double(max(maxCount, 1))

                        HStack(spacing: 3) {
                            Text(kw.word)
                                .font(.system(size: 11))
                            Text("\(kw.count)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, DS.sm)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(intensity * 0.15 + 0.03))
                        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
                    }
                }
            }
        }
        .dreamCard()
    }

    // MARK: - Memory Card

    private var memoryCard: some View {
        let memories = appState.database.fetchAllMemories()

        return VStack(alignment: .leading, spacing: DS.sm) {
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(Color.accentColor)
                Text("What Dream Knows")
                    .font(DS.titleFont)
            }

            if memories.isEmpty {
                VStack(spacing: DS.sm) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(.quaternary)
                    Text("Dream will learn about you over time")
                        .font(DS.bodyFont)
                        .foregroundStyle(.tertiary)
                    Text("Memories are extracted after each nightly Dream run")
                        .font(DS.captionFont)
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.lg)
            } else {
                ForEach(memories) { memory in
                    HStack(alignment: .top, spacing: DS.sm) {
                        Text(memory.memoryType.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, DS.sm)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 3))

                        VStack(alignment: .leading, spacing: 1) {
                            Text(memory.name)
                                .font(DS.bodyMedium)
                            Text(memory.description)
                                .font(DS.captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .dreamCard()
    }
}

// MARK: - Timeline Tab

struct TimelineTab: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDate = Date()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
        } detail: {
            detail
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: DS.md) {
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal, DS.sm)

            Button {
                selectedDate = Date()
            } label: {
                Label("Today", systemImage: "calendar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, DS.md)

            // Generate Now button
            Button {
                appState.triggerDreamNow()
            } label: {
                HStack(spacing: DS.sm) {
                    if appState.isDreaming {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(appState.isDreaming ? "Generating..." : "Generate Summary")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .padding(.horizontal, DS.md)
            .disabled(appState.isDreaming || appState.todayEventCount == 0)

            if appState.todayEventCount == 0 {
                Text("Start working to generate a summary")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.md)
            }

            Divider()
                .padding(.horizontal, DS.md)

            // Summary list in sidebar
            ScrollView {
                LazyVStack(spacing: 2) {
                    // Today (even without summary)
                    sidebarRow(
                        date: Date(),
                        label: "Today",
                        hasSummary: appState.todaySummary != nil,
                        eventCount: appState.todayEventCount,
                        isSelected: Calendar.current.isDateInToday(selectedDate)
                    )

                    ForEach(appState.recentSummaries) { summary in
                        if !Calendar.current.isDateInToday(summary.date) {
                            sidebarRow(
                                date: summary.date,
                                label: summary.dateFormatted,
                                hasSummary: true,
                                eventCount: summary.eventCount,
                                isSelected: Calendar.current.isDate(selectedDate, inSameDayAs: summary.date)
                            )
                        }
                    }
                }
                .padding(.horizontal, DS.sm)
            }
        }
    }

    private func sidebarRow(date: Date, label: String, hasSummary: Bool, eventCount: Int, isSelected: Bool) -> some View {
        Button {
            selectedDate = date
        } label: {
            HStack(spacing: DS.sm) {
                Circle()
                    .fill(hasSummary ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(DS.bodyMedium)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    Text("\(eventCount) events")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if hasSummary {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor.opacity(0.5))
                }
            }
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.sm)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusSm))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(spacing: DS.lg) {
                if Calendar.current.isDateInToday(selectedDate) {
                    todayDetail
                } else {
                    pastDayDetail
                }
            }
            .padding(DS.xl)
        }
    }

    // MARK: - Today Detail

    @ViewBuilder
    private var todayDetail: some View {
        // Header
        VStack(spacing: DS.sm) {
            Text("TODAY")
                .font(.system(size: 11, weight: .bold))
                .tracking(1)
                .foregroundStyle(.tertiary)

            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                .font(DS.titleFont)

            HStack(spacing: DS.lg) {
                statBadge(value: "\(appState.todayEventCount)", label: "events")
                statBadge(value: appState.todayStorageFormatted, label: "captured")
                if let summary = appState.todaySummary {
                    statBadge(value: String(format: "%.0fs", summary.processingSeconds), label: "processed")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, DS.sm)

        // "What you mainly did" — the hero insight
        mainActivitiesView(for: selectedDate)

        // Calendar-style time blocks
        timeBlocksView(for: selectedDate)

        if let summary = appState.todaySummary {
            // Dream summary
            VStack(alignment: .leading, spacing: DS.md) {
                HStack {
                    Image(systemName: "moon.stars.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Dream Summary")
                        .font(DS.titleFont)
                    Spacer()
                    Text(summary.llmProvider)
                        .font(DS.microFont)
                        .foregroundStyle(.tertiary)
                }
                SummaryContent(summary: summary)
            }
            .dreamCard()
        } else {
            // No summary yet — show live data preview
            VStack(spacing: DS.md) {
                Image(systemName: "moon.haze")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor.opacity(0.4))

                Text("No summary yet for today")
                    .font(DS.bodyMedium)

                Text("Press \"Generate Summary\" to create one now,\nor wait for tonight's automatic Dream.")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                // Show top apps as preview
                let apps = appState.analytics.appUsage(days: 1)
                if !apps.isEmpty {
                    VStack(alignment: .leading, spacing: DS.xs) {
                        Text("TODAY SO FAR")
                            .sectionLabel()
                        ForEach(Array(apps.prefix(5))) { app in
                            HStack {
                                Text(app.appName)
                                    .font(DS.captionFont)
                                Spacer()
                                Text(String(format: "%.0f%%", app.percentage))
                                    .font(DS.microFont)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.top, DS.sm)
                }
            }
            .frame(maxWidth: .infinity)
            .dreamCard()
        }

        // Raw events preview
        recentEventsPreview
    }

    // MARK: - Past Day Detail

    @ViewBuilder
    private var pastDayDetail: some View {
        let summary = appState.recentSummaries.first(where: {
            Calendar.current.isDate($0.date, inSameDayAs: selectedDate)
        })

        VStack(spacing: DS.sm) {
            Text(selectedDate.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1)
                .foregroundStyle(.tertiary)

            Text(selectedDate.formatted(.dateTime.month(.wide).day().year()))
                .font(DS.titleFont)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, DS.sm)

        // "What you mainly did"
        mainActivitiesView(for: selectedDate)

        // Calendar-style time blocks
        timeBlocksView(for: selectedDate)

        if let summary {
            VStack(alignment: .leading, spacing: DS.md) {
                HStack {
                    Image(systemName: "moon.stars.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Dream Summary")
                        .font(DS.titleFont)
                    Spacer()

                    HStack(spacing: DS.md) {
                        Label("\(summary.eventCount) events", systemImage: "waveform.path")
                        Label(String(format: "%.0fs", summary.processingSeconds), systemImage: "clock")
                        Label(summary.llmProvider, systemImage: "brain")
                    }
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
                }

                SummaryContent(summary: summary)
            }
            .dreamCard()
        } else {
            VStack(spacing: DS.md) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 28))
                    .foregroundStyle(.quaternary)
                Text("No Dream for this day")
                    .font(DS.bodyMedium)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Main Activities ("What you mainly did")

    @ViewBuilder
    private func mainActivitiesView(for date: Date) -> some View {
        let engine = TimeBlockEngine(database: appState.database)
        let analysis = engine.analyzDay(for: date)

        if !analysis.mainActivities.isEmpty {
            VStack(alignment: .leading, spacing: DS.md) {
                Text("WHAT YOU MAINLY DID")
                    .sectionLabel()

                // Main activities — large, prominent
                ForEach(analysis.mainActivities) { activity in
                    HStack(spacing: DS.md) {
                        // Color bar
                        RoundedRectangle(cornerRadius: 2)
                            .fill(activity.color)
                            .frame(width: 4, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(activity.label)
                                .font(DS.bodyMedium)
                                .lineLimit(1)

                            HStack(spacing: DS.sm) {
                                Text(activity.durationFormatted)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.accentColor)

                                Text("·")
                                    .foregroundStyle(.quaternary)

                                Text(activity.app)
                                    .font(DS.captionFont)
                                    .foregroundStyle(.tertiary)

                                Text("·")
                                    .foregroundStyle(.quaternary)

                                Text("\(activity.eventCount) events")
                                    .font(DS.captionFont)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()
                    }
                }

                // Other activities — compact list
                if !analysis.otherActivities.isEmpty {
                    Divider()

                    HStack(spacing: DS.sm) {
                        Text("Also:")
                            .font(DS.captionFont)
                            .foregroundStyle(.tertiary)

                        Text(
                            analysis.otherActivities
                                .map { "\($0.label) (\($0.durationFormatted))" }
                                .joined(separator: " · ")
                        )
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    }
                }

                // App breakdown bar
                Divider()

                HStack(spacing: 0) {
                    ForEach(Array(analysis.appBreakdown.prefix(5).enumerated()), id: \.offset) { _, item in
                        let width = max(item.percentage, 3) // Minimum visibility
                        RoundedRectangle(cornerRadius: 0)
                            .fill(appColor(item.app).opacity(0.6))
                            .frame(width: width * 2.5, height: 6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))

                HStack(spacing: DS.md) {
                    ForEach(Array(analysis.appBreakdown.prefix(5).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: DS.xs) {
                            Circle()
                                .fill(appColor(item.app).opacity(0.6))
                                .frame(width: 5, height: 5)
                            Text("\(item.app) \(String(format: "%.0f", item.percentage))%")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .dreamHeroCard()
        }
    }

    private func appColor(_ name: String) -> Color { DS.appColor(name) }

    // MARK: - Time Blocks (Calendar-style)

    @ViewBuilder
    private func timeBlocksView(for date: Date) -> some View {
        let engine = TimeBlockEngine(database: appState.database)
        let blocks = engine.generateBlocks(for: date)

        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("ACTIVITY TIMELINE")
                        .sectionLabel()
                    Spacer()
                    Text("\(blocks.count) blocks · \(totalDuration(blocks))")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, DS.sm)

                // Time blocks
                ForEach(blocks) { block in
                    HStack(alignment: .top, spacing: DS.md) {
                        // Time column
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(block.startFormatted)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(block.durationFormatted)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.quaternary)
                        }
                        .frame(width: 48, alignment: .trailing)

                        // Color bar
                        RoundedRectangle(cornerRadius: 2)
                            .fill(block.color)
                            .frame(width: 3)
                            .frame(minHeight: 32)

                        // Content
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: DS.sm) {
                                Text(block.app)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)

                                if block.isMultiApp {
                                    Text("+ others")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Text("\(block.eventCount) events")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.quaternary)
                            }

                            if !block.label.isEmpty && block.label != block.app {
                                Text(block.label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, DS.xs)
                }
            }
            .dreamCard()
        }
    }

    private func totalDuration(_ blocks: [TimeBlock]) -> String {
        let total = blocks.reduce(0.0) { $0 + $1.duration }
        let hours = Int(total / 3600)
        let minutes = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: - Recent Events Preview

    private var recentEventsPreview: some View {
        let events = appState.database.fetchEvents(
            from: Calendar.current.startOfDay(for: selectedDate),
            to: Calendar.current.isDateInToday(selectedDate)
                ? Date()
                : Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: selectedDate))!
        ).suffix(20)

        return Group {
            if !events.isEmpty {
                VStack(alignment: .leading, spacing: DS.sm) {
                    Text("RECENT EVENTS")
                        .sectionLabel()

                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .top, spacing: DS.sm) {
                            Text(formatTime(event.timestamp))
                                .font(DS.microFont)
                                .foregroundStyle(.quaternary)
                                .frame(width: 48, alignment: .trailing)

                            Circle()
                                .fill(eventColor(event.eventType))
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)

                            VStack(alignment: .leading, spacing: 0) {
                                if let app = event.appName {
                                    Text(app)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(event.textContent ?? "")
                                    .font(DS.captionFont)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                        }
                    }
                }
                .dreamCard()
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
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

    private func statBadge(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(DS.captionFont)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
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

// MARK: - Helper

extension DailySummary {
    static func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
