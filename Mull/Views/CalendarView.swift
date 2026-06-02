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

    private let hourStart = 0
    private let hourEnd = 24
    private let hourHeight: CGFloat = 50
    private let timeColumnWidth: CGFloat = 48

    var body: some View {
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
                    // Scroll to current hour - 1 (show context before now)
                    let scrollHour = max(Calendar.current.component(.hour, from: Date()) - 1, 0)
                    proxy.scrollTo(scrollHour, anchor: .top)
                }
            }
        }
        .onChange(of: weekOffset) { _, _ in loadWeek() }
        .popover(item: $popoverBlock) { block in
            blockDetail(block)
        }
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

// Make TimeBlock work with popover
extension TimeBlock: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: TimeBlock, rhs: TimeBlock) -> Bool {
        lhs.id == rhs.id
    }
}
