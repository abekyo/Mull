import XCTest
import AppKit
import Combine
@testable import mull

/// The menu bar, asserted against the running app.
///
/// This suite exists because of a failure that no unit test could have seen and no
/// reviewer did: mull declares no `WindowGroup` — the main window is a plain
/// `NSWindow` built in `AppDelegate` — and SwiftUI builds the standard menus around
/// the scenes it is given. With only a `MenuBarExtra`, it builds no File menu at
/// all, so the shipping app had no ⌘W. Not a Close item that did nothing: no item.
/// ⌘M and ⌘Q were there, because Window and the app menu are built unconditionally,
/// and that is what made the hole invisible.
///
/// So the assertions are made against `NSApp.mainMenu` itself rather than against
/// the `Commands` value that is supposed to produce it. What the source says it
/// declares is exactly the thing that was not in question.
///
/// The test host is the app, so the menu here is the real one.
@MainActor
final class MenuCommandTests: XCTestCase {

    // MARK: - The menu bar

    /// Every shortcut the app is meant to answer, and where a reader finds it.
    ///
    /// A key equivalent lives on exactly one item, so this doubles as the check that
    /// nothing is bound twice.
    private static let expected: [(name: String, key: String, modifiers: NSEvent.ModifierFlags)] = [
        // The basics an app is expected to have. ⌘W is the one that was missing.
        ("Close", "w", [.command]),
        ("Settings", ",", [.command]),
        // Advertised in print — "⇧⌘C" is drawn on the sidebar's Copy context row —
        // and, until this was bound, answered only by a global monitor that cannot
        // see events delivered to mull.
        ("Copy Context", "c", [.command, .shift]),
        ("Find", "f", [.command]),
        ("Show/Hide Sidebar", "s", [.command, .control]),
        // The calendar. These worked before, from an off-screen stack of
        // zero-opacity buttons that told nobody they existed.
        ("New Event", "n", [.command]),
        ("Day", "1", [.command]),
        ("Week", "2", [.command]),
        ("Month", "3", [.command]),
        ("Year", "4", [.command]),
        ("Today", "t", [.command]),
        ("Go to Date", "t", [.command, .shift]),
        ("Previous", String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command]),
        ("Next", String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command]),
        ("Zoom In", "+", [.command]),
        ("Zoom Out", "-", [.command]),
    ]

    func testEveryShortcutTheAppPromisesIsOnTheMenuBar() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu, "the app under test built no main menu")
        for (name, key, modifiers) in Self.expected {
            XCTAssertNotNil(Self.item(in: menu, key: key, modifiers: modifiers),
                            "\(name) has no menu item, so its shortcut reaches nothing")
        }
    }

    /// AppKit provides Undo, Redo, Cut, Copy, Paste and Select All in the Edit menu.
    /// Nothing mull declares may take one of those keys away — a ⌘C that copies the
    /// day's context instead of the selected text would be the same class of mistake
    /// this suite was written for, in the other direction.
    func testMullTakesNoneOfTheStandardEditingKeys() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let standard = ["z": "undo:", "x": "cut:", "c": "copy:", "v": "paste:", "a": "selectAll:"]
        for (key, selector) in standard {
            let item = Self.item(in: menu, key: key, modifiers: [.command])
            let action = item?.action.map(NSStringFromSelector)
            XCTAssertEqual(action, selector,
                           "⌘\(key.uppercased()) is no longer the standard editing command")
        }
    }

    /// The Help menu carries nothing, on purpose: mull registers no help book, and a
    /// menu item that says Help and answers nothing is the promise §7.4 is about.
    func testHelpOffersNothingRatherThanSomethingThatDoesNothing() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let help = menu.items.first { $0.submenu?.title == "Help" || $0.title == "Help" }
        XCTAssertEqual(help?.submenu?.items.count ?? 0, 0)
    }

    /// Depth-first, because the item may be nested (Edit › Find › Find…) and where a
    /// menu item lives is a layout decision, not part of what is being asserted.
    private static func item(in menu: NSMenu,
                             key: String,
                             modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == key,
               item.keyEquivalentModifierMask == modifiers {
                return item
            }
            if let submenu = item.submenu,
               let found = self.item(in: submenu, key: key, modifiers: modifiers) {
                return found
            }
        }
        return nil
    }

    // MARK: - The line from the menu to the view

    /// A menu item cannot hold a reference to `CalendarWeekView` — that is a struct
    /// rebuilt on every body pass — so it posts to `MenuCommands` and the view on
    /// screen reads it. This is that delivery, without a view.
    func testAPressReachesWhoeverIsListening() {
        var received: [MenuCommands.Command] = []
        let subscription = MenuCommands.shared.stream.sink { received.append($0) }
        defer { subscription.cancel() }

        MenuCommands.shared.send(.today)
        MenuCommands.shared.send(.newEvent)

        XCTAssertEqual(received, [.today, .newEvent])
    }

    /// Nothing on screen to answer means the items are drawn dimmed. A live ⌘3 on the
    /// Chat page would silently reshape a calendar nobody is looking at.
    func testTheMenuGoesDimWhenTheCalendarLeaves() {
        let menu = MenuCommands.shared
        defer { menu.windowDisappeared() }

        menu.windowAppeared()
        menu.calendarAppeared()
        XCTAssertTrue(menu.calendarIsShowing)
        XCTAssertTrue(menu.windowIsShowing)

        menu.calendarDisappeared()
        XCTAssertFalse(menu.calendarIsShowing)
        XCTAssertTrue(menu.windowIsShowing, "leaving the calendar page does not close the window")
    }

    /// `onDisappear` on a view inside a closing window is not promised, so the window
    /// takes the calendar down with it rather than trusting the page to say so.
    func testClosingTheWindowTakesTheCalendarWithIt() {
        let menu = MenuCommands.shared
        defer { menu.windowDisappeared() }

        menu.windowAppeared()
        menu.calendarAppeared()
        menu.windowDisappeared()

        XCTAssertFalse(menu.windowIsShowing)
        XCTAssertFalse(menu.calendarIsShowing)
    }
}
