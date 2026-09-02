import Combine
import Foundation

/// The menu bar's line to whatever is on screen.
///
/// mull's main window is a plain `NSWindow` built in `AppDelegate`, not a SwiftUI
/// scene, so neither of the two ways a menu item normally reaches a view is open to
/// it: `focusedSceneValue` needs a scene to travel through, and a menu item cannot
/// hold a reference to `CalendarWeekView` — that is a struct rebuilt on every body
/// pass, while the main menu is built once at launch and kept.
///
/// So the menu posts to a mailbox and the views on screen read it. Subscribing is
/// also what says whether there is anybody to answer: `calendarIsShowing` is what
/// draws View › Today live rather than dimmed, and it is false the moment the
/// calendar leaves the detail column.
///
/// Every command here has a control on screen as well. A menu item is where a Mac
/// user looks to find out that a shortcut exists at all — which is the whole reason
/// these moved out of the off-screen `keyEquivalents` stack they used to live in —
/// but it is never the only way to reach something.
@MainActor
final class MenuCommands: ObservableObject {
    static let shared = MenuCommands()

    enum Command: Equatable {
        /// The window itself.
        case search

        /// The calendar. One case per menu item; `CalendarWeekView.perform` is the
        /// exhaustive switch that keeps a new case from being added and forgotten.
        case today
        case previous
        case next
        case goToDate
        case day
        case week
        case month
        case year
        case newEvent
        case zoomIn
        case zoomOut
    }

    /// A subject rather than a stored closure. A closure handed over from `onAppear`
    /// captures a copy of the view struct, and reading `mode` or `today` back out of
    /// that copy afterwards reads whatever they were when the copy was made.
    /// `.onReceive` runs against the view SwiftUI has now, which is the only one whose
    /// state is current.
    ///
    /// `stream` is erased once and kept, not built on each access: `onReceive` is
    /// handed this on every body pass, and a fresh `AnyPublisher` each time is a fresh
    /// subscription each time. The clock behind the now-line is stored for the same
    /// reason (`CalendarWeekView.clock`).
    private let subject: PassthroughSubject<Command, Never>
    let stream: AnyPublisher<Command, Never>

    /// Whether the calendar is in the detail column right now.
    @Published private(set) var calendarIsShowing = false
    /// Whether the main window is up. Search is the window's, not any one page's.
    @Published private(set) var windowIsShowing = false

    private init() {
        let subject = PassthroughSubject<Command, Never>()
        self.subject = subject
        self.stream = subject.eraseToAnyPublisher()
    }

    func send(_ command: Command) { subject.send(command) }

    func calendarAppeared() { calendarIsShowing = true }
    func calendarDisappeared() { calendarIsShowing = false }
    func windowAppeared() { windowIsShowing = true }
    func windowDisappeared() {
        windowIsShowing = false
        // A window that has gone takes its calendar with it, and `onDisappear` on a
        // view inside a closing window is not promised.
        calendarIsShowing = false
    }
}
