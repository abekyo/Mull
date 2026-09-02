import XCTest
import AppKit
import ApplicationServices
@testable import mull

/// Finding the window an app is showing, asserted against the Accessibility API
/// rather than against the source that calls it.
///
/// The defect this locks is not hypothetical and was found twice: `kAXFocusedWindow`
/// is answered only once a window of the app's own has taken focus, and several apps
/// answer it never. Asking for it alone means no title for those apps — and, until
/// this, no window *body* either, which is around 80% of the characters mull keeps.
///
/// The fallback case is reproduced here rather than described: a panel that cannot
/// become key is a window the app has, with no focused and no main window naming it.
/// That is the shape Preview presents, and reading our own process's AX needs no
/// permission (see `PermissionService.accessibilityAPIEnabled`), so it is a real
/// measurement and not a stub.
@MainActor
final class FrontWindowTests: XCTestCase {

    private var appElement: AXUIElement { AXUIElementCreateApplication(getpid()) }

    /// A window the app has and cannot focus. `NSPanel` with `canBecomeKey` false is
    /// the only way to hold that state deliberately from inside a test.
    private final class UnfocusableWindow: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private func makeWindow(titled title: String) -> NSPanel {
        let window = UnfocusableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = title
        window.orderFront(nil)
        return window
    }

    // MARK: - The cascade

    /// The whole point: a window that is neither focused nor main is still the window
    /// the person is looking at, and the old code could not see it.
    func testAWindowThatCannotTakeFocusIsStillFound() throws {
        let window = makeWindow(titled: "mull AX probe — unfocusable")
        defer { window.close() }

        let found = FrontWindow.firstAnswer(from: appElement) { element -> String? in
            guard let title = FrontWindow.title(of: element),
                  title.hasPrefix("mull AX probe") else { return nil }
            return title
        }

        // Only `AXWindows` can name this panel — it refuses to be key and refuses to be
        // main — so a failure here means something else is standing in front of it, and
        // the message says what.
        XCTAssertEqual(found, "mull AX probe — unfocusable",
                       "the app's windows are \(NSApp.windows.filter(\.isVisible).map(\.title))")
    }

    /// And the attribute the old code asked for answers nothing for that same window,
    /// which is what makes the assertion above a measurement rather than a tautology.
    func testTheFocusedAttributeAloneDoesNotFindIt() throws {
        let window = makeWindow(titled: "mull AX probe — unfocusable")
        defer { window.close() }

        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &ref)

        // Either the app names no focused window at all, or it names one that is not
        // this panel. Both are the failure the cascade exists for; neither may be
        // "the panel", or the test above proves nothing.
        if result == .success, let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let focused = unsafeDowncast(ref as AnyObject, to: AXUIElement.self)
            XCTAssertNotEqual(FrontWindow.title(of: focused), "mull AX probe — unfocusable")
        }
    }

    /// An untitled window is not an answer. Folded into nil once, in `title(of:)`, so
    /// the cascade keeps looking instead of returning "" to a caller that would then
    /// record a row with no entity in it.
    func testAnEmptyTitleIsNotAnAnswer() throws {
        let untitled = makeWindow(titled: "")
        defer { untitled.close() }

        let element = try XCTUnwrap(FrontWindow.firstAnswer(from: appElement) { $0 },
                                    "the app has windows, so one of them is the front one")
        XCTAssertNotEqual(FrontWindow.title(of: element), "")

        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref)
        let windows = try XCTUnwrap(ref as? [AXUIElement])
        let blank = try XCTUnwrap(windows.first { element in
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            return (titleRef as? String) == ""
        }, "the probe window is in AXWindows with an empty title")
        XCTAssertNil(FrontWindow.title(of: blank))
    }

    /// A process with no windows answers nothing, and answering nothing is not a
    /// crash. `AXUIElementCreateApplication` will hand back an element for any pid.
    func testAProcessWithNoWindowsAnswersNothing() {
        XCTAssertNil(FrontWindow.title(ofAppAt: AXUIElementCreateApplication(1)))
    }

    // MARK: - One cascade, not three

    /// The title path learned to fall back on its own once, and the body path — the
    /// larger half of the record — was left asking for the attribute that is missing.
    /// Nothing that reads content may reach for it directly again.
    func testNoCapturePathAsksForTheFocusedWindowItself() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in ["Mull/Services/WindowTextCapture.swift",
                     "Mull/Services/SystemCaptureEnvironment.swift",
                     "Mull/Services/ColdReadService.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("kAXFocusedWindowAttribute as CFString"),
                           "\(path) resolves the window itself again — use FrontWindow")
            XCTAssertTrue(source.contains("FrontWindow."), "\(path) no longer goes through the cascade")
        }
    }

    /// `PermissionService` is the exception and stays one: it asks for the attribute to
    /// find out whether the API answers at all, and treats "no value" as a yes. That is
    /// a probe, not a read, and giving it a fallback would only make it slower.
    func testThePermissionProbeIsLeftAsItIs() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Mull/Services/PermissionService.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("kAXFocusedWindowAttribute as CFString"))
        XCTAssertTrue(source.contains("case .success, .noValue, .attributeUnsupported:"))
    }
}
