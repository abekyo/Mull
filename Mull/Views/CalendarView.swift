import SwiftUI

/// Apple Calendar week-view style — auto-filled from recorded activity.
/// No manual input. Your day fills itself.
///
/// Design matches Apple Calendar as closely as possible:
///   - Flex-width day columns
///   - Today's date in a blue circle
///   - Thin grid lines (0.5pt)
///   - Left color bar on blocks (not full background)
///   - Today's column has subtle background tint
///   - Auto-scrolls to current time on appear
struct CalendarWeekView: View {
    @EnvironmentObject var appState: AppState
    @State private var weekOffset: Int = 0
    @State private var weekBlocks: [Date: [TimeBlock]] = [:]
    @State private var weekEvents: [Date: [CalendarEvent]] = [:]
    @State private var popoverBlock: TimeBlock?

    enum CalMode: String, CaseIterable { case day = "Day", week = "Week", month = "Month", year = "Year" }
    @State private var mode: CalMode = .week
    @State private var dayOffset: Int = 0
    @State private var monthOffset: Int = 0
    @State private var monthData: [Date: (duration: TimeInterval, label: String)] = [:]
    @State private var yearOffset: Int = 0
    @State private var yearCounts: [Date: Int] = [:]

    private let hourStart = 0
    private let hourEnd = 24
    private let hourHeight: CGFloat = 50
    private let timeColumnWidth: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            switch mode {
            case .day:   dayContent
            case .week:  weekContent
            case .month: monthContent
            case .year:  yearContent
            }
        }
        .onChange(of: weekOffset) { _, _ in loadWeek() }
        .onChange(of: dayOffset) { _, _ in loadDay() }
        .onChange(of: monthOffset) { _, _ in loadMonth() }
        .onChange(of: yearOffset) { _, _ in loadYear() }
        .onChange(of: mode) { _, m in
            switch m {
            case .day: loadDay()
            case .week: loadWeek()
            case .month: loadMonth()
            case .year: loadYear()
            }
        }
        .popover(item: $popoverBlock) { block in
            blockDetail(block)
        }
    }

    /// Day | Week | Month | Year segmented switch.
    private var modeBar: some View {
        HStack {
            Picker("", selection: $mode) {
                ForEach(CalMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            Spacer()
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    private var weekContent: some View {
        VStack(spacing: 0) {
            weekHeader
            Divider()
            dayHeaders
            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    calendarGrid
                }
                .onAppear {
                    loadWeek()
                    let scrollHour = max(Calendar.current.component(.hour, from: Date()) - 1, 0)
                    proxy.scrollTo(scrollHour, anchor: .top)
                }
            }
        }
    }

    // MARK: - Day

    private var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset,
                              to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private var dayContent: some View {
        VStack(spacing: 0) {
            dayHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        timeLabels
                        dayColumn(date: selectedDay)
                    }
                }
                .onAppear {
                    loadDay()
                    let h = max(Calendar.current.component(.hour, from: Date()) - 1, 0)
                    proxy.scrollTo(h, anchor: .top)
                }
            }
        }
    }

    private var dayHeader: some View {
        HStack {
            Button { dayOffset -= 1 } label: { Image(systemName: "chevron.left").font(DS.bodyFont) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            Text(Self.fullDayLabel(selectedDay)).font(DS.titleFont)
            if dayOffset != 0 {
                Button("Today") { dayOffset = 0 }
                    .font(DS.captionFont).buttonStyle(.bordered).controlSize(.small)
                    .padding(.leading, DS.sm)
            }
            Spacer()
            Button { dayOffset += 1 } label: { Image(systemName: "chevron.right").font(DS.bodyFont) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(dayOffset >= 0)
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    private func loadDay() {
        let engine = TimeBlockEngine(database: appState.database)
        let day = selectedDay
        let key = Calendar.current.startOfDay(for: day)
        weekBlocks[key] = engine.generateBlocks(for: day)
        weekEvents[key] = appState.calendar.events(for: day)
    }

    private static func fullDayLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: date)
    }

    // MARK: - Week Header

    private var weekHeader: some View {
        HStack {
            Button { weekOffset -= 1 } label: {
                Image(systemName: "chevron.left")
                    .font(DS.bodyFont)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Text(weekRangeLabel)
                .font(DS.titleFont)

            if weekOffset != 0 {
                Button("Today") { weekOffset = 0 }
                    .font(DS.captionFont)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.leading, DS.sm)
            }

            Spacer()

            Button { weekOffset += 1 } label: {
                Image(systemName: "chevron.right")
                    .font(DS.bodyFont)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(weekOffset >= 0)
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    private var weekRangeLabel: String {
        let (monday, _) = weekRange
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monday)
    }

    // MARK: - Day Headers (sticky, doesn't scroll)

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            // Time column spacer
            Spacer().frame(width: timeColumnWidth)

            ForEach(weekDays, id: \.self) { date in
                let isToday = Calendar.current.isDateInToday(date)

                VStack(spacing: 2) {
                    Text(dayName(date))
                        .font(DS.miniFont)
                        .foregroundStyle(isToday ? Color.accentColor : .secondary)

                    // Apple-style: today's number in a blue circle
                    if isToday {
                        Text(dayNumber(date))
                            .font(DS.smallMedium)
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.accentColor))
                    } else {
                        Text(dayNumber(date))
                            .font(DS.smallFont)
                            .foregroundStyle(.primary)
                            .frame(width: 24, height: 24)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, DS.xs)
    }

    // MARK: - Calendar Grid

    private var calendarGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            timeLabels
            ForEach(weekDays, id: \.self) { date in
                dayColumn(date: date)
            }
        }
    }

    private var timeLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(hourStart..<hourEnd, id: \.self) { hour in
                Text(hour == 0 ? "" : String(format: "%d", hour))
                    .font(DS.microFont)
                    .foregroundStyle(.tertiary)
                    .frame(width: timeColumnWidth, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, DS.sm)
                    .offset(y: -6) // Align with grid line
                    .id(hour) // For scroll target
            }
        }
    }

    private func dayColumn(date: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(date)
        let dayKey = calendar.startOfDay(for: date)
        let blocks = weekBlocks[dayKey] ?? []
        let events = weekEvents[dayKey] ?? []

        return ZStack(alignment: .topLeading) {
            // Background: today gets a subtle tint
            if isToday {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.03))
            }

            // Grid lines — thin, Apple-style
            VStack(spacing: 0) {
                ForEach(hourStart..<hourEnd, id: \.self) { _ in
                    Color.clear
                        .frame(height: hourHeight)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 0.5)
                        }
                }
            }

            // Two sub-columns: calendar events (left) + activity blocks (right)
            GeometryReader { geo in
                let hasEvents = !events.isEmpty
                let eventWidth = hasEvents ? geo.size.width * 0.38 : 0
                let blockWidth = hasEvents ? geo.size.width * 0.60 : geo.size.width

                // Calendar events (left column)
                if hasEvents {
                    ForEach(events) { event in
                        calendarEventView(event: event, width: eventWidth)
                            .offset(x: 1, y: yOffsetForDate(event.start))
                    }
                }

                // Activity blocks (right column)
                ForEach(blocks) { block in
                    blockView(block: block, width: blockWidth)
                        .offset(x: hasEvents ? eventWidth + 2 : 0, y: yOffset(for: block))
                }
            }

            // Now indicator
            if isToday {
                nowIndicator
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: - Calendar Event View (left column)

    private func calendarEventView(event: CalendarEvent, width: CGFloat) -> some View {
        let height = max(hourHeight * event.duration / 3600, 20)

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(event.color)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(DS.miniMedium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if height > 30 {
                        Text(event.timeFormatted)
                            .font(DS.miniFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, DS.xs)
                .padding(.vertical, 2)
            }
            .frame(width: width - 2, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(event.color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(event.color.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Activity Block View (right column)

    private func blockView(block: TimeBlock, width: CGFloat) -> some View {
        let height = max(hourHeight * block.duration / 3600, 20)

        return Button { popoverBlock = block } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(block.color)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(block.app)
                        .font(DS.miniMedium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if height > 32, !block.label.isEmpty, block.label != block.app {
                        Text(block.label)
                            .font(DS.miniFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if height > 48 {
                        Text(block.durationFormatted)
                            .font(DS.miniFont)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, DS.xs)
                .padding(.vertical, 2)

                Spacer(minLength: 0)
            }
            .frame(width: width - 2, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(block.color.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(block.color.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Now Indicator (red line + red dot, Apple-style)

    private var nowIndicator: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let minute = Calendar.current.component(.minute, from: Date())
        let y = CGFloat(hour - hourStart) * hourHeight + CGFloat(minute) / 60.0 * hourHeight

        return GeometryReader { geo in
            HStack(spacing: 0) {
                Circle()
                    .fill(DS.nowLine)
                    .frame(width: 8, height: 8)
                    .offset(x: -4)
                Rectangle()
                    .fill(DS.nowLine)
                    .frame(width: geo.size.width, height: 1)
            }
            .offset(y: y)
        }
    }

    // MARK: - Block Detail Popover

    private func blockDetail(_ block: TimeBlock) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(spacing: DS.sm) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(block.color)
                    .frame(width: 4, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.app)
                        .font(DS.bodyMedium)
                    if !block.label.isEmpty && block.label != block.app {
                        Text(block.label)
                            .font(DS.captionFont)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack(spacing: DS.md) {
                Label(block.startFormatted + " – " + block.endFormatted, systemImage: "clock")
                    .font(DS.captionFont)
                Label(block.durationFormatted, systemImage: "hourglass")
                    .font(DS.captionFont)
                Label("\(block.eventCount)", systemImage: "number")
                    .font(DS.captionFont)
            }
            .foregroundStyle(.secondary)

            if let title = block.topWindowTitle {
                HStack(spacing: DS.xs) {
                    Image(systemName: "doc.text")
                        .font(DS.miniFont)
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let clip = block.topClipboard {
                HStack(spacing: DS.xs) {
                    Image(systemName: "text.quote")
                        .font(DS.miniFont)
                        .foregroundStyle(.tertiary)
                    Text("\"\(String(clip.prefix(100)))\"")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                        .italic()
                        .lineLimit(2)
                }
            }
        }
        .padding(DS.lg)
        .frame(width: 280)
    }

    // MARK: - Data Loading

    private func loadWeek() {
        let (monday, _) = weekRange
        let engine = TimeBlockEngine(database: appState.database)
        var blockResult: [Date: [TimeBlock]] = [:]
        var eventResult: [Date: [CalendarEvent]] = [:]

        for offset in 0..<7 {
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: monday) else { continue }
            let dayKey = Calendar.current.startOfDay(for: date)
            blockResult[dayKey] = engine.generateBlocks(for: date)
            eventResult[dayKey] = appState.calendar.events(for: date)
        }

        weekBlocks = blockResult
        weekEvents = eventResult
    }

    // MARK: - Helpers

    private var weekRange: (Date, Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysFromMonday + (weekOffset * 7), to: today),
              let sunday = calendar.date(byAdding: .day, value: 6, to: monday) else {
            return (today, today)
        }
        return (monday, sunday)
    }

    private var weekDays: [Date] {
        let (monday, _) = weekRange
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: monday) }
    }

    private func yOffset(for block: TimeBlock) -> CGFloat {
        yOffsetForDate(block.start)
    }

    private func yOffsetForDate(_ date: Date) -> CGFloat {
        let hour = Calendar.current.component(.hour, from: date)
        let minute = Calendar.current.component(.minute, from: date)
        return CGFloat(hour - hourStart) * hourHeight + CGFloat(minute) / 60.0 * hourHeight
    }

    private func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func dayNumber(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: date)
    }
}

// MARK: - Month View

extension CalendarWeekView {

    var monthContent: some View {
        VStack(spacing: 0) {
            monthHeader
            Divider()
            monthWeekdayRow
            monthGrid
                .onAppear { loadMonth() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var monthHeader: some View {
        HStack {
            Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left").font(DS.bodyFont) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            Text(monthLabel).font(DS.titleFont)
            if monthOffset != 0 {
                Button("Today") { monthOffset = 0 }
                    .font(DS.captionFont).buttonStyle(.bordered).controlSize(.small)
                    .padding(.leading, DS.sm)
            }
            Spacer()
            Button { monthOffset += 1 } label: { Image(systemName: "chevron.right").font(DS.bodyFont) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(monthOffset >= 0)
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    private var monthWeekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], id: \.self) { d in
                Text(d).font(DS.miniFont).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, DS.xs)
    }

    private var monthGrid: some View {
        let days = monthGridDays
        let weeks = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
        // 6 week-rows that divide the available height equally, so the grid grows
        // and shrinks with the window instead of sitting at a fixed height.
        return VStack(spacing: 1) {
            ForEach(weeks.indices, id: \.self) { wi in
                HStack(spacing: 1) {
                    ForEach(weeks[wi], id: \.self) { date in
                        monthCell(date)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DS.md)
        .padding(.vertical, DS.sm)
    }

    private func monthCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let key = cal.startOfDay(for: date)
        let inMonth = cal.component(.month, from: date) == cal.component(.month, from: displayedMonth)
        let isToday = cal.isDateInToday(date)
        let info = monthData[key]
        let hasActivity = (info?.duration ?? 0) > 60

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                if isToday {
                    Text(dayNum(date)).font(DS.smallMedium).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(DS.moon))
                } else {
                    Text(dayNum(date)).font(DS.smallFont)
                        .foregroundStyle(inMonth ? DS.ink : DS.inkFaint)
                }
                Spacer()
                if hasActivity { Circle().fill(DS.moon).frame(width: 5, height: 5) }
            }
            if hasActivity, let info {
                Text(info.label).font(DS.miniFont).foregroundStyle(DS.inkDim).lineLimit(1)
                Text(formatDur(info.duration)).font(DS.tinyFont).foregroundStyle(DS.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isToday ? DS.moon.opacity(0.06) : DS.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.hairline, lineWidth: 0.5))
        .opacity(inMonth ? 1 : 0.45)
        .onTapGesture { jumpToWeek(of: date) }
    }

    // MARK: Month data

    var displayedMonth: Date {
        let cal = Calendar.current
        let base = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return cal.date(byAdding: .month, value: monthOffset, to: base) ?? base
    }

    private var monthLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return f.string(from: displayedMonth)
    }

    /// 42 days (6 weeks) covering the month, starting on the Monday of the first week.
    private var monthGridDays: [Date] {
        let cal = Calendar.current
        let firstOfMonth = displayedMonth
        let weekday = cal.component(.weekday, from: firstOfMonth)
        let daysFromMonday = (weekday + 5) % 7
        guard let start = cal.date(byAdding: .day, value: -daysFromMonday, to: firstOfMonth) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    func loadMonth() {
        let engine = TimeBlockEngine(database: appState.database)
        let cal = Calendar.current
        var result: [Date: (duration: TimeInterval, label: String)] = [:]
        for date in monthGridDays {
            // Don't compute the future.
            if cal.startOfDay(for: date) > cal.startOfDay(for: Date()) { continue }
            let blocks = engine.generateBlocks(for: date)
            guard !blocks.isEmpty else { continue }
            let total = blocks.reduce(0.0) { $0 + $1.duration }
            let main = blocks.max(by: { $0.duration < $1.duration })
            let label = (main?.label.isEmpty == false ? main?.label : main?.app) ?? ""
            result[cal.startOfDay(for: date)] = (total, label)
        }
        monthData = result
    }

    private func jumpToWeek(of date: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: today, to: target).day ?? 0
        weekOffset = Int((Double(days) / 7).rounded(.towardZero))
        mode = .week
    }

    private func dayNum(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: date)
    }

    private func formatDur(_ d: TimeInterval) -> String {
        let m = Int(d / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60, rem = m % 60
        return rem > 0 ? "\(h)h\(rem)m" : "\(h)h"
    }
}

// MARK: - Year View (activity heatmap)

extension CalendarWeekView {

    var yearContent: some View {
        VStack(spacing: 0) {
            yearHeader
            Divider()
            ScrollView {
                yearHeatmap
                    .padding(DS.lg)
                    .onAppear { loadYear() }
            }
            Spacer(minLength: 0)
        }
    }

    private var yearHeader: some View {
        HStack {
            Button { yearOffset -= 1 } label: { Image(systemName: "chevron.left").font(DS.bodyFont) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            Text(yearLabel).font(DS.titleFont)
            if yearOffset != 0 {
                Button("This year") { yearOffset = 0 }
                    .font(DS.captionFont).buttonStyle(.bordered).controlSize(.small)
                    .padding(.leading, DS.sm)
            }
            Spacer()
            Button { yearOffset += 1 } label: { Image(systemName: "chevron.right").font(DS.bodyFont) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(yearOffset >= 0)
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.sm)
    }

    /// GitHub-style heatmap: columns = weeks, rows = weekday, intensity = activity.
    private var yearHeatmap: some View {
        let maxCount = max(yearCounts.values.max() ?? 1, 1)
        let rows = Array(repeating: GridItem(.fixed(13), spacing: 3), count: 7)
        return VStack(alignment: .leading, spacing: DS.sm) {
            LazyHGrid(rows: rows, spacing: 3) {
                ForEach(yearGridDays, id: \.self) { date in
                    yearCell(date, maxCount: maxCount)
                }
            }
            // Legend
            HStack(spacing: 4) {
                Text("less").font(DS.tinyFont).foregroundStyle(DS.inkFaint)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(heatColor(fraction: f))
                        .frame(width: 11, height: 11)
                }
                Text("more").font(DS.tinyFont).foregroundStyle(DS.inkFaint)
            }
        }
    }

    private func yearCell(_ date: Date, maxCount: Int) -> some View {
        let cal = Calendar.current
        let inYear = cal.component(.year, from: date) == cal.component(.year, from: displayedYear)
        let isFuture = cal.startOfDay(for: date) > cal.startOfDay(for: Date())
        let count = yearCounts[cal.startOfDay(for: date)] ?? 0
        let fraction = count == 0 ? 0 : 0.15 + 0.85 * (Double(count) / Double(maxCount))
        return RoundedRectangle(cornerRadius: 2)
            .fill(isFuture || !inYear ? Color.clear : heatColor(fraction: fraction))
            .frame(width: 13, height: 13)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(DS.hairline, lineWidth: inYear && !isFuture ? 0.5 : 0))
            .help(inYear && !isFuture ? "\(Self.shortDate(date)): \(count) events" : "")
            .onTapGesture { if inYear && !isFuture { jumpToDay(date) } }
    }

    private func heatColor(fraction: Double) -> Color {
        fraction <= 0 ? DS.surfaceHi : DS.moon.opacity(0.15 + 0.75 * fraction)
    }

    var displayedYear: Date {
        let cal = Calendar.current
        let base = cal.date(from: cal.dateComponents([.year], from: Date())) ?? Date()
        return cal.date(byAdding: .year, value: yearOffset, to: base) ?? base
    }

    private var yearLabel: String {
        let f = DateFormatter(); f.dateFormat = "yyyy"
        return f.string(from: displayedYear)
    }

    /// Days from the Monday on/before Jan 1 through Dec 31 of the displayed year.
    private var yearGridDays: [Date] {
        let cal = Calendar.current
        let jan1 = displayedYear
        let weekday = cal.component(.weekday, from: jan1)
        let daysFromMonday = (weekday + 5) % 7
        guard let start = cal.date(byAdding: .day, value: -daysFromMonday, to: jan1),
              let dec31 = cal.date(byAdding: DateComponents(year: 1, day: -1), to: jan1) else { return [] }
        var days: [Date] = []
        var d = start
        while d <= dec31 {
            days.append(d)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return days
    }

    func loadYear() {
        let cal = Calendar.current
        let start = displayedYear
        let end = min(cal.date(byAdding: .year, value: 1, to: start) ?? start, Date())
        guard end > start else { yearCounts = [:]; return }
        let events = appState.database.fetchEvents(from: start, to: end)
        var counts: [Date: Int] = [:]
        for e in events { counts[cal.startOfDay(for: e.timestamp), default: 0] += 1 }
        yearCounts = counts
    }

    private func jumpToDay(_ date: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        dayOffset = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? 0
        mode = .day
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// Make TimeBlock work with popover
extension TimeBlock: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: TimeBlock, rhs: TimeBlock) -> Bool {
        lhs.id == rhs.id
    }
}
