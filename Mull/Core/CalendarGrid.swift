import Foundation
import CoreGraphics

/// The arithmetic behind the calendar grid, with no view in it.
///
/// All of this lived inside `CalendarWeekView` as private methods, where the only
/// way to find out whether a span was laid out correctly was to look at the screen.
/// It is the part most likely to be quietly wrong — clamping at midnight, columns
/// for overlapping meetings, a legibility floor that must not swallow the span
/// below it, a week index that must not be off by one on the day the week turns —
/// so it is the part that belongs somewhere a test can reach it.
enum CalendarGrid {

    // MARK: - Spans

    /// A stretch of time asking to be drawn.
    struct Interval: Equatable {
        let start: Date
        let end: Date

        init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    /// Where a span sits, how tall it is drawn, and how tall its minutes alone say
    /// it should be. When those two differ the card has been padded up to stay
    /// legible, and the view has to say so rather than misreport a duration.
    ///
    /// `column` / `columns` place it beside anything it overlaps; `continuesBefore`
    /// / `continuesAfter` say it runs past the edge of the day being drawn rather
    /// than beginning or ending there.
    struct Span: Equatable {
        var y: CGFloat
        var height: CGFloat
        var trueHeight: CGFloat
        var column: Int = 0
        var columns: Int = 1
        var continuesBefore: Bool = false
        var continuesAfter: Bool = false

        var isPadded: Bool { height > trueHeight + 0.5 }
    }

    /// Lay spans out on the time axis of one particular day.
    ///
    /// Three things happen here, and the middle one is why the others are not enough
    /// on their own:
    ///
    /// 1. Each span is clamped to `day`. A span running 23:40 → 00:50 was drawn from
    ///    its own hour to a height past the bottom of the grid, where it was
    ///    silently clipped; it now stops at midnight and says it continues.
    /// 2. Overlapping spans are grouped into clusters and given a column each, as
    ///    Apple Calendar does. They used to be stacked at the same x, so the earlier
    ///    of two overlapping meetings was both invisible *and* unclickable.
    /// 3. A short span is padded up to `minHeight`, but only as far as the next span
    ///    in its own column allows, so padding can never make two consecutive spans
    ///    appear to overlap.
    static func layout(_ intervals: [Interval],
                       day: Date,
                       hourHeight: CGFloat,
                       minHeight: CGFloat,
                       gap: CGFloat,
                       calendar: Calendar = .current) -> [Span] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // 1 — clamp to the rendered day.
        var spans: [Span] = intervals.map { interval in
            let start = max(interval.start, dayStart)
            let end = min(max(interval.end, start), dayEnd)
            let trueHeight = max(hourHeight * end.timeIntervalSince(start) / 3600, 1)
            return Span(y: yOffset(for: start, hourHeight: hourHeight, calendar: calendar),
                        height: trueHeight,
                        trueHeight: trueHeight,
                        continuesBefore: interval.start < dayStart,
                        continuesAfter: interval.end > dayEnd)
        }

        // 2 — cluster by true extent, then hand out columns within each cluster.
        for cluster in overlapClusters(spans) {
            var columnEnds: [CGFloat] = []
            for i in cluster {
                let free = columnEnds.firstIndex { $0 <= spans[i].y + 0.5 }
                let column = free ?? columnEnds.count
                if free == nil { columnEnds.append(0) }
                columnEnds[column] = spans[i].y + spans[i].trueHeight
                spans[i].column = column
            }
            // Every member of a cluster is cut to the same width, so a column of
            // meetings doesn't change width halfway down the hour.
            for i in cluster { spans[i].columns = max(columnEnds.count, 1) }
        }

        // 3 — pad short spans, but only into space no one else in the column holds.
        for i in spans.indices {
            let nextY = spans.indices
                .filter { $0 != i && spans[$0].column == spans[i].column && spans[$0].y > spans[i].y + 0.5 }
                .map { spans[$0].y }
                .min() ?? .greatestFiniteMagnitude
            let room = max(nextY - spans[i].y - gap, 2)
            spans[i].height = max(spans[i].trueHeight, min(minHeight, room))
        }

        return spans
    }

    /// Indices grouped so that every span in a group overlaps at least one other
    /// member of it — the unit that has to share the available width.
    private static func overlapClusters(_ spans: [Span]) -> [[Int]] {
        let order = spans.indices.sorted { spans[$0].y < spans[$1].y }
        var clusters: [[Int]] = []
        var current: [Int] = []
        var clusterEnd: CGFloat = -.greatestFiniteMagnitude

        for i in order {
            if current.isEmpty || spans[i].y < clusterEnd - 0.5 {
                current.append(i)
                clusterEnd = max(clusterEnd, spans[i].y + spans[i].trueHeight)
            } else {
                clusters.append(current)
                current = [i]
                clusterEnd = spans[i].y + spans[i].trueHeight
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// The horizontal slice of a lane a span gets, given the column it landed in.
    static func slice(_ span: Span, laneX: CGFloat, laneWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let width = laneWidth / CGFloat(max(span.columns, 1))
        return (laneX + width * CGFloat(span.column), width)
    }

    // MARK: - The all-day band

    /// A day-shaped commitment asking to be drawn above the hour grid — a flight, a
    /// week of PTO, a birthday. Carries its own identity because the band draws one
    /// bar per commitment and has to find the event again to open it.
    struct DayInterval: Equatable {
        let id: String
        let start: Date
        let end: Date

        init(id: String, start: Date, end: Date) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    /// Where one bar sits in the band: the first displayed column it covers, how many
    /// it covers, the lane it holds for the whole of that run, and whether it runs
    /// past either edge of what is on screen.
    struct Bar: Equatable, Identifiable {
        let id: String
        var column: Int
        var span: Int
        var lane: Int = 0
        var continuesBefore: Bool = false
        var continuesAfter: Bool = false
    }

    /// Lay day-shaped commitments across the days on screen.
    ///
    /// The band used to be one independent stack of chips per column, fed by a
    /// dictionary that files a multi-day event under *every* day it covers. That drew
    /// a four-day trip as four separate outlined chips carrying the same title — four
    /// bookings, as far as the eye is concerned — and, because each column stacked
    /// its own chips with no memory of its neighbours, a bar could sit in the second
    /// row on Monday and the first on Tuesday the moment a one-day event above it
    /// ended.
    ///
    /// So: one bar per commitment, and a lane held for the length of its run. Lanes
    /// are handed out greedily in column order, which for intervals is the optimal
    /// colouring — a bar never takes a lane a longer-running one still needs.
    /// Ends that leave the range are reported rather than rounded off, so a trip that
    /// began last Thursday cannot read as having begun on Monday.
    static func allDayBars(_ intervals: [DayInterval],
                           days: [Date],
                           calendar: Calendar = .current) -> [Bar] {
        guard !days.isEmpty else { return [] }
        let columns = days.map { calendar.startOfDay(for: $0) }

        var bars: [Bar] = []
        for interval in intervals {
            let first = calendar.startOfDay(for: interval.start)
            // The last *moment* it occupies, not its end: an all-day event's end
            // lands on midnight or on 23:59:59 depending on where it came from, and
            // stepping back a second reads both without inventing a trailing day.
            // Same rule as `CalendarService.dayEvents`, which fills the dictionary.
            let last = calendar.startOfDay(
                for: max(interval.end.addingTimeInterval(-1), interval.start))
            let covered = columns.indices.filter { columns[$0] >= first && columns[$0] <= last }
            guard let column = covered.first, let endColumn = covered.last else { continue }

            bars.append(Bar(id: interval.id,
                            column: column,
                            span: endColumn - column + 1,
                            continuesBefore: first < columns[column],
                            continuesAfter: last > columns[endColumn]))
        }

        // Longest first where two begin on the same day, so the week-long thing sits
        // above the afternoon of it — and `id` last, so the same week never lays
        // itself out two different ways between one load and the next.
        bars.sort { ($0.column, -$0.span, $0.id) < ($1.column, -$1.span, $1.id) }

        var laneFreeFrom: [Int] = []
        for i in bars.indices {
            let free = laneFreeFrom.firstIndex { $0 <= bars[i].column }
            let lane = free ?? laneFreeFrom.count
            if free == nil { laneFreeFrom.append(0) }
            laneFreeFrom[lane] = bars[i].column + bars[i].span
            bars[i].lane = lane
        }
        return bars
    }

    // MARK: - The time axis

    /// How far down a column a moment sits, measured from that day's midnight.
    ///
    /// Elapsed time, not wall-clock components. The two are the same on 364 days a
    /// year and differ by an hour on the two that aren't, and mixing them is what
    /// made a clock change disagree with itself: `time(on:atY:)` has always
    /// measured from midnight in seconds, `layout` sizes every card from
    /// `timeIntervalSince`, and this alone read hour-and-minute off the wall clock.
    /// On a spring-forward day that put the card an hour away from the row that was
    /// clicked to make it; on a fall-back day it stacked 01:00–04:00 on top of the
    /// 04:00 that follows it and laid them out as if they overlapped.
    ///
    /// A 23- or 25-hour day therefore draws a column that is short or long by one
    /// hour's height, which is the honest picture: the hour is missing, or there
    /// twice, and the gutter labels come from the same arithmetic.
    static func yOffset(for date: Date, hourHeight: CGFloat, calendar: Calendar = .current) -> CGFloat {
        let elapsed = date.timeIntervalSince(calendar.startOfDay(for: date))
        return CGFloat(elapsed / 3600) * hourHeight
    }

    /// The moment a point down the column stands for. Clamped to the day, so a drag
    /// that runs off the bottom means midnight rather than tomorrow lunchtime.
    ///
    /// The exact inverse of `yOffset` — including on the days a day is not 24 hours
    /// long, where the clamp is the real length of `day` rather than a flat 24.
    static func time(on day: Date, atY y: CGFloat, hourHeight: CGFloat,
                     calendar: Calendar = .current) -> Date {
        let midnight = calendar.startOfDay(for: day)
        let next = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400)
        let seconds = Double(y / hourHeight) * 3600
        let clamped = min(max(seconds, 0), next.timeIntervalSince(midnight))
        return midnight.addingTimeInterval(clamped)
    }

    /// How tall a whole day's column is. A clock change makes a day 23 or 25 hours
    /// long, and a column fixed at 24 either hides an hour or invents one.
    static func dayHeight(_ day: Date, hourHeight: CGFloat, calendar: Calendar = .current) -> CGFloat {
        let midnight = calendar.startOfDay(for: day)
        let next = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400)
        return CGFloat(next.timeIntervalSince(midnight) / 3600) * hourHeight
    }

    // MARK: - Dragging a span

    /// Where a dragged span's start lands: `shift` seconds down the axis and
    /// `dayDelta` columns across, snapped, and held inside the day it was dropped on.
    ///
    /// The clamp is the point. A drag used to add its shift to the start and stop
    /// there, so nudging an 00:15 meeting upward by a few points moved it to *the
    /// previous day* — and, because a span is drawn at its offset from its own
    /// midnight, the card leapt from the top of the column to the bottom of the same
    /// column on the way. The same wrap happened downward at 23:45. Moving between
    /// days is now something the pointer asks for sideways, in whole columns, and
    /// never something the axis does to you by accident.
    ///
    /// Measured in elapsed seconds from midnight rather than in wall-clock hours, so
    /// a 23- or 25-hour day clamps to its real length like everything else here.
    static func draggedStart(from start: Date,
                             shift: TimeInterval,
                             dayDelta: Int,
                             minutes: Int = 15,
                             calendar: Calendar = .current) -> Date {
        let originDay = calendar.startOfDay(for: start)
        let targetDay = calendar.date(byAdding: .day, value: dayDelta, to: originDay) ?? originDay
        let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDay)
            ?? targetDay.addingTimeInterval(86_400)

        let elapsed = start.timeIntervalSince(originDay) + shift
        let moved = snapped(targetDay.addingTimeInterval(elapsed),
                            minutes: minutes, rounding: .nearest)
        // The last snap point that still begins on the target day. Clamping before
        // snapping would let the snap push it back over the boundary it was held at.
        let last = max(nextDay.addingTimeInterval(-TimeInterval(max(minutes, 1) * 60)), targetDay)
        return min(max(moved, targetDay), last)
    }

    /// How many columns sideways a drag has asked for, given the width of one.
    /// Clamped to the days actually on screen: an event dragged off the edge of the
    /// week would otherwise be written to a day the reader cannot see it land on.
    static func draggedColumns(_ translation: CGFloat,
                               columnWidth: CGFloat,
                               from column: Int,
                               columns: Int) -> Int {
        guard columnWidth > 1, columns > 1 else { return 0 }
        let asked = Int((translation / columnWidth).rounded())
        return min(max(column + asked, 0), columns - 1) - column
    }

    // MARK: - The draft being composed

    /// The name a draft is saved under.
    ///
    /// Return on a field nobody typed into used to write an event with no title at
    /// all — a blank card on a real calendar, which is not something any other
    /// calendar on this Mac will produce. The placeholder has been saying "New Event"
    /// for as long as the card has been open, so saving under the name that was
    /// already on screen is the only reading of Return that doesn't surprise.
    ///
    /// Trimmed, because a title typed and then rubbed out leaves a space behind, and
    /// an event called " " is the blank one wearing a disguise.
    static func draftTitle(_ typed: String, placeholder: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? placeholder : trimmed
    }

    enum Rounding { case down, up, nearest }

    /// To the quarter hour — the unit a calendar thinks in, and what turns a rough
    /// drag into "10:00 – 11:15" instead of "09:58 – 11:13".
    static func snapped(_ date: Date, minutes: Int = 15, rounding: Rounding = .down) -> Date {
        let step = TimeInterval(max(minutes, 1) * 60)
        let raw = date.timeIntervalSinceReferenceDate / step
        let rule: FloatingPointRoundingRule
        switch rounding {
        case .down:    rule = .down
        case .up:      rule = .up
        case .nearest: rule = .toNearestOrAwayFromZero
        }
        return Date(timeIntervalSinceReferenceDate: raw.rounded(rule) * step)
    }

    // MARK: - Which day, which week

    /// The first day of the week `date` falls in.
    ///
    /// Which day that is belongs to the reader, not to us: a machine set to 日曜始まり
    /// gets Sunday, one set to Monday gets Monday.
    static func startOfWeek(_ date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    static func dayIndex(of date: Date, from origin: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day],
                                from: calendar.startOfDay(for: origin),
                                to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Weeks between the week holding `date` and the week holding `origin`.
    ///
    /// An earlier form divided a raw day-delta by seven and truncated, which is not
    /// the same question: the day before the week turns is −1 day → offset 0 →
    /// *this* week, which begins today and does not contain the day that was
    /// clicked. Diffing the two week-starts cannot be off by a week.
    static func weekIndex(of date: Date, from origin: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.weekOfYear],
                                from: startOfWeek(origin, calendar: calendar),
                                to: startOfWeek(date, calendar: calendar)).weekOfYear ?? 0
    }

    static func monthIndex(of date: Date, from origin: Date, calendar: Calendar = .current) -> Int {
        let base = calendar.date(from: calendar.dateComponents([.year, .month], from: origin)) ?? origin
        let target = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.dateComponents([.month], from: base, to: target).month ?? 0
    }

    static func yearIndex(of date: Date, from origin: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.year, from: date) - calendar.component(.year, from: origin)
    }

    /// Weekday names rotated to begin at `firstWeekday`. Every grid in the calendar
    /// reads its column headings from here, so one screen cannot label its columns
    /// two different ways depending on which range the reader happens to be in.
    ///
    /// `symbols` is Foundation's array, whose index 0 is always Sunday.
    static func orderedWeekdaySymbols(_ symbols: [String], firstWeekday: Int) -> [String] {
        guard symbols.count == 7 else { return symbols }
        return (0..<7).map { symbols[(firstWeekday - 1 + $0) % 7] }
    }

    /// The 42 days a month grid draws: six weeks, starting on the first weekday of the
    /// week the 1st falls in, whichever day the system says that is.
    ///
    /// Six rows always, never five — a grid whose height depends on where the 1st lands
    /// changes size as you page through the year, and in a popover that moves the day
    /// you were about to click out from under the pointer.
    ///
    /// One copy, read by the month view and by `MonthPicker`. They had a line-for-line
    /// identical version each, which is two places for the first-weekday arithmetic to
    /// be got right in and one place for it to be got wrong.
    ///
    /// - Parameter firstOfMonth: any instant in the month; only its year and month are read.
    static func monthGridDays(of firstOfMonth: Date, calendar: Calendar = .current) -> [Date] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: firstOfMonth))
        else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}
