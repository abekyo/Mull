import ApplicationServices

/// The window an app has on screen, asked for the way apps actually answer.
///
/// `kAXFocusedWindow` is what every caller here used to ask for, alone, and it is the
/// attribute most likely to be missing: an app answers it only once a window of its
/// own has taken focus, and several answer it never. Preview is the cheap proof — it
/// returns nothing for focused *or* main, and its title is sitting in `AXWindows[0]`
/// the whole time.
///
/// A nil here is not a cosmetic loss, and it is not one loss either. The title stamps
/// every row `RecordingService.recordEvent` writes and is where the row's *entity*
/// comes from, so an app that never answers becomes hours of activity attributed to
/// nothing, plus junk projects named after the fallback text ("Firefox: unknown
/// (20m9s)"). The body walk behind it is the larger half again: window contents are
/// about 80% of the characters mull keeps (DIRECTION §3.1), and they were being asked
/// for through the same missing attribute.
///
/// One cascade, in one place, because the two call sites had drifted once already —
/// the title learned to fall back and the body did not.
enum FrontWindow {

    /// Ask each window the app names, cheapest first, and take the first real answer.
    ///
    /// `read` returning nil means "this window did not answer", not "the app has no
    /// windows", which is why the cascade folds over answers rather than over
    /// elements: an app that names a focused window with no title can still have a
    /// main window that has one.
    ///
    /// Only the *first* of `AXWindows` is tried. The list is every window the app has,
    /// including ones behind other apps, and mull attributes what it reads to whatever
    /// is in front of the person — so a search through all of them would buy titles at
    /// the price of attributing the wrong one.
    static func firstAnswer<T>(from appElement: AXUIElement, _ read: (AXUIElement) -> T?) -> T? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = window(named: attribute as CFString, in: appElement),
               let answer = read(window) {
                return answer
            }
        }
        guard let first = firstWindow(in: appElement) else { return nil }
        return read(first)
    }

    /// The window itself, for a caller that reads more than one thing off it.
    ///
    /// The cascade picks the window here, not the answer: a window that is found and
    /// holds nothing is a real answer, and re-running an expensive read against the
    /// next candidate to contradict it is not what this is for.
    static func element(of appElement: AXUIElement) -> AXUIElement? {
        firstAnswer(from: appElement) { $0 }
    }

    /// The title of whatever window the app is showing.
    static func title(ofAppAt appElement: AXUIElement) -> String? {
        firstAnswer(from: appElement) { title(of: $0) }
    }

    /// An empty title is the same as no title to every caller here, so it is folded
    /// into nil once rather than checked at each call site.
    static func title(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    /// The window an app names under one attribute, if it names one.
    private static func window(named attribute: CFString, in appElement: AXUIElement) -> AXUIElement? {
        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, attribute, &windowRef)
        // Some apps answer kAXFocusedWindow with something that isn't an AXUIElement.
        // A force-cast crashes the whole recorder there, so the CF type is verified
        // first — this was three separate guards, one of which was still an `as!`.
        guard result == .success, let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(window as AnyObject, to: AXUIElement.self)
    }

    /// Last resort: the app's first window. An app with windows but no focused or main
    /// one still has something on screen.
    private static func firstWindow(in appElement: AXUIElement) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows.first
    }
}
