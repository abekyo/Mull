import Foundation

/// The settings both binaries read.
///
/// `UserDefaults.standard` is not the same store in the two targets. The app's
/// standard domain is its bundle identifier, `com.mull.app`; `MullMCP` is a bare
/// executable with no bundle identifier at all, so *its* standard domain is keyed on
/// the executable name and holds none of the app's values. Every
/// `UserDefaults.standard` read inside `Mull/Core` — which `project.yml` compiles
/// into **both** targets — therefore returns the type's zero value when the reader is
/// an agent rather than the window. The setting appears to work, because the surface
/// the user is looking at while they change it is the one that happens to share a
/// domain with the control.
///
/// That is the wrong way round: CLAUDE.md §5 says the product is the MCP surface and
/// the GUI is secondary. So preferences that govern what mull *reports* are read
/// through here, from one named domain, by whichever binary is asking. Neither target
/// is sandboxed (`project.yml`), so the helper can open the app's domain by name.
enum Preferences {

    /// Must stay equal to `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`. If the app's
    /// identifier changes and this does not, the app keeps writing to its own domain
    /// and `MullMCP` keeps reading an empty one — silently, and only for agents.
    static let domain = "com.mull.app"

    /// Resolved once. Inside the app (and the test bundle, whose host is the app)
    /// this *is* `.standard`; asking for one's own bundle identifier by suite name is
    /// documented as unsupported, so that case is taken first rather than risked.
    static let store: UserDefaults = {
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }()

    // MARK: - Activity segmentation

    static let resumeGapKey = "activityResumeGap"

    /// How long a break can be before coming back counts as a *new* piece of work
    /// rather than the same one resumed. Seconds; `0` disables rejoining entirely.
    ///
    /// See `TimeBlockEngine.coalesceResumed` for what it does and
    /// `BlockSegmenter.defaultResumeGap` for why ten minutes is the default.
    static var resumeGap: TimeInterval {
        guard let stored = store.object(forKey: resumeGapKey) as? Int else {
            return BlockSegmenter.defaultResumeGap
        }
        return TimeInterval(max(stored, 0))
    }

    // MARK: - Calendar mirror

    static let mirrorEnabledKey = "calendarMirrorEnabled"
    static let mirrorCalendarKey = "calendarMirrorCalendarID"
    static let mirrorIntervalKey = "calendarMirrorInterval"

    /// Off unless the user turns it on. A feature that writes to somebody's real
    /// calendar does not get to be on by default, and one that can carry window
    /// titles to an account server gets it twice.
    static var mirrorEnabled: Bool { store.bool(forKey: mirrorEnabledKey) }

    /// Which calendar the mirror writes into. No default: mull never picks a calendar
    /// on the user's behalf and never creates one (SECURITY.md), so an unset value
    /// means the mirror does nothing at all.
    static var mirrorCalendarID: String? {
        store.string(forKey: mirrorCalendarKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static let defaultMirrorInterval: TimeInterval = 3600

    /// How often the mirror reconciles, in seconds.
    ///
    /// This governs *latency* rather than volume: only settled blocks are written and
    /// each is written once, so a shorter interval means finished work reaches the
    /// calendar sooner, not that more of it is written.
    static var mirrorInterval: TimeInterval {
        guard let stored = store.object(forKey: mirrorIntervalKey) as? Int, stored > 0 else {
            return defaultMirrorInterval
        }
        return TimeInterval(max(stored, 60))
    }

    /// Turn the mirror on and point it somewhere, in one act.
    ///
    /// The two settings are separate switches and were reachable only from a Settings
    /// pane, which is how the mirror spent its whole life never running: turning it on
    /// there and leaving the calendar unpicked produces a timer that fires every hour
    /// and returns immediately. They are set together or not at all — a caller that has
    /// a calendar in hand is the only kind that should be enabling this.
    static func enableMirror(calendarID: String) {
        guard !calendarID.isEmpty else { return }
        store.set(calendarID, forKey: mirrorCalendarKey)
        store.set(true, forKey: mirrorEnabledKey)
    }

    // MARK: - Output

    /// Character ceiling on assembled context, or `0` for no ceiling. Read here
    /// rather than from `UserDefaults.standard`, which was the original instance of
    /// the bug this type exists for: the ceiling the user set applied to the app's
    /// copy-to-clipboard and not to anything `MullMCP` handed an agent.
    static var outputMaxChars: Int { store.integer(forKey: "outputMaxChars") }
}
