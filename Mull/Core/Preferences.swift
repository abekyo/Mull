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
    /// `TimeBlockEngine.defaultResumeGap` for why ten minutes is the default.
    static var resumeGap: TimeInterval {
        guard let stored = store.object(forKey: resumeGapKey) as? Int else {
            return TimeBlockEngine.defaultResumeGap
        }
        return TimeInterval(max(stored, 0))
    }

    // MARK: - Output

    /// Character ceiling on assembled context, or `0` for no ceiling. Read here
    /// rather than from `UserDefaults.standard`, which was the original instance of
    /// the bug this type exists for: the ceiling the user set applied to the app's
    /// copy-to-clipboard and not to anything `MullMCP` handed an agent.
    static var outputMaxChars: Int { store.integer(forKey: "outputMaxChars") }
}
