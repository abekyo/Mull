import SwiftUI
import EventKit
import AppKit

// Loading, navigation and the small shared helpers.
//
// Lifted out of CalendarView.swift. Nothing here changed in the move.

extension CalendarWeekView {

    // MARK: - Data Loading

    func loadDay() {
        let day = selectedDay
        let key = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: key) ?? key
        let database = appState.database
        let calendarService = appState.calendar
        let rangeKey = loadKey
        let hidden = hiddenCalendars
        let token = beginLoad()
        // The header already reads the new day — yesterday's blocks must not sit under it.
        weekBlocks = [:]
        weekEvents = [:]
        weekAllDay = [:]
        calendarAccess = calendarService.accessState

        Task.detached(priority: .userInitiated) {
            let engine = TimeBlockEngine(database: database)
            let blocks = engine.generateBlocks(for: day)
            let events = calendarService.dayEvents(from: key, to: dayEnd, excluding: hidden)
            await MainActor.run {
                guard finishLoad(token, key: rangeKey) else { return }
                weekBlocks[key] = blocks
                weekEvents = events.timed
                weekAllDay = events.allDay
            }
        }
    }

    /// A week is 7 full day analyses plus one EventKit fetch. Doing that on the main
    /// thread froze the window on every arrow-key week change; it runs detached and
    /// publishes once.
    func loadWeek() {
        let (weekStart, _) = weekRange
        let database = appState.database
        let calendarService = appState.calendar
        let rangeKey = loadKey
        let hidden = hiddenCalendars
        let token = beginLoad()
        // Never let last week's grid sit under this week's header.
        weekBlocks = [:]
        weekEvents = [:]
        weekAllDay = [:]
        calendarAccess = calendarService.accessState

        Task.detached(priority: .userInitiated) {
            let engine = TimeBlockEngine(database: database)
            var blockResult: [Date: [TimeBlock]] = [:]

            for offset in 0..<7 {
                guard let date = Calendar.current.date(byAdding: .day, value: offset, to: weekStart) else { continue }
                let dayKey = Calendar.current.startOfDay(for: date)
                blockResult[dayKey] = engine.generateBlocks(for: date)
            }

            // One EventKit round trip for the whole week, not seven.
            let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
            let eventResult = calendarService.dayEvents(from: weekStart, to: weekEnd,
                                                        excluding: hidden)

            await MainActor.run {
                guard finishLoad(token, key: rangeKey) else { return }
                weekBlocks = blockResult
                weekEvents = eventResult.timed
                weekAllDay = eventResult.allDay
            }
        }
    }

    /// The span of days whose events are on screen.
    var eventRange: (Date, Date)? {
        let cal = Calendar.current
        switch mode {
        case .day:
            let start = cal.startOfDay(for: selectedDay)
            return (start, cal.date(byAdding: .day, value: 1, to: start) ?? start)
        case .week:
            let start = weekRange.0
            return (start, cal.date(byAdding: .day, value: 7, to: start) ?? start)
        case .month:
            guard let first = monthGridDays.first, let last = monthGridDays.last else { return nil }
            return (first, cal.date(byAdding: .day, value: 1, to: last) ?? last)
        case .year:
            return nil
        }
    }

    /// Re-read only the calendar half of the range, after a short pause.
    ///
    /// The pause is what makes an account sync — which posts a store change per batch
    /// — cost one fetch instead of forty. Nothing is cleared first and the loading
    /// pill stays down, so saving an event no longer blinks the week out and back.
    func refreshEvents() {
        guard let range = eventRange else { return }
        eventRefresh?.cancel()
        let calendarService = appState.calendar
        let rangeKey = loadKey
        let currentMode = mode
        let hidden = hiddenCalendars

        eventRefresh = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let fetched = calendarService.dayEvents(from: range.0, to: range.1, excluding: hidden)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard rangeKey == loadKey else { return }
                switch currentMode {
                case .day, .week:
                    weekEvents = fetched.timed
                    weekAllDay = fetched.allDay
                case .month:
                    monthEvents = CalendarService.merged(timed: fetched.timed,
                                                         allDay: fetched.allDay)
                case .year:
                    break
                }
            }
        }
    }

    /// Claim a load slot. A newer load supersedes an older one, so a slow week that
    /// lands after the user already paged elsewhere is dropped instead of flickering in.
    func beginLoad() -> Int {
        loadToken += 1
        isLoading = true
        loadedKey = nil
        return loadToken
    }

    /// True when `token` is still the newest load (and the spinner should come down).
    func finishLoad(_ token: Int, key: String) -> Bool {
        guard loadToken == token else { return false }
        isLoading = false
        loadedKey = key
        return true
    }

    // MARK: - Navigation
    //
    // Three ways to the same place: the header chevrons, the arrow keys, and the
    // date picker. None of them is clamped at today: the observed half of the grid
    // has nothing to say about tomorrow, but the scheduled half does, and refusing
    // to page forward hid every meeting the user had already agreed to.

    /// The date the view is currently showing, whatever unit it is showing it in.
    var anchorDate: Date {
        switch mode {
        case .day:   return selectedDay
        case .week:  return weekRange.0
        case .month: return displayedMonth
        case .year:  return displayedYear
        }
    }

    /// Move by one of whatever unit is on screen.
    func step(_ delta: Int) {
        keyboardSelection = nil
        switch mode {
        case .day:   dayOffset += delta
        case .week:  weekOffset += delta
        case .month: monthOffset += delta
        case .year:  yearOffset += delta
        }
    }

    /// ⌘T. All four offsets reset, so switching mode afterwards also lands on now.
    func goToToday() {
        dayOffset = 0
        weekOffset = 0
        monthOffset = 0
        yearOffset = 0
        wantsAnchorScroll = true
    }

    /// Open a specific date in the unit currently on screen.
    func jump(to date: Date) {
        switch mode {
        case .day:   dayOffset = dayIndex(of: date)
        case .week:  weekOffset = weekIndex(of: date)
        case .month: monthOffset = monthIndex(of: date)
        case .year:  yearOffset = yearIndex(of: date)
        }
    }

    func dayIndex(of date: Date) -> Int { CalendarGrid.dayIndex(of: date, from: today) }
    func weekIndex(of date: Date) -> Int { CalendarGrid.weekIndex(of: date, from: today) }
    func monthIndex(of date: Date) -> Int { CalendarGrid.monthIndex(of: date, from: today) }
    func yearIndex(of date: Date) -> Int { CalendarGrid.yearIndex(of: date, from: today) }

    // MARK: - Helpers

    func startOfWeek(_ date: Date) -> Date { CalendarGrid.startOfWeek(date) }

    var weekRange: (Date, Date) {
        let calendar = Calendar.current
        let thisWeek = startOfWeek(today)
        guard let start = calendar.date(byAdding: .day, value: weekOffset * 7, to: thisWeek),
              let end = calendar.date(byAdding: .day, value: 6, to: start) else {
            return (thisWeek, thisWeek)
        }
        return (start, end)
    }

    var weekDays: [Date] {
        let (start, _) = weekRange
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    /// Weekday names ordered from the system's first weekday. All three grids read
    /// their column headings from here, so one screen cannot label its columns two
    /// different ways depending on which range the reader happens to be in.
    func orderedWeekdaySymbols(_ symbols: KeyPath<Calendar, [String]>) -> [String] {
        let cal = Calendar.current
        return CalendarGrid.orderedWeekdaySymbols(cal[keyPath: symbols], firstWeekday: cal.firstWeekday)
    }

    func dayName(_ date: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: date)
        return Calendar.current.shortStandaloneWeekdaySymbols[weekday - 1]
    }

    /// The bare number, not a formatted date. A "d" pattern is localised to 19日 in
    /// Japanese, which is right in a sentence and wrong inside a 24pt circle — the
    /// column header wants the digit alone, as Apple Calendar shows it.
    func dayNumber(_ date: Date) -> String {
        String(Calendar.current.component(.day, from: date))
    }

    static func shortDate(_ date: Date) -> String {
        CalendarWeekView.templateFormatter("MMMd").string(from: date)
    }
}
