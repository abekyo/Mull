import Foundation

/// Everything the recorder needs to know about the machine it is running on.
///
/// The capture layer is the one asymmetry the product has and it
/// was the one layer with no tests, for a structural reason rather than a lazy
/// one: `RecordingService` called `NSWorkspace`, `AXUIElementCopyAttributeValue`,
/// `NSPasteboard` and `IsSecureEventInputEnabled` directly, so there was no way
/// to construct it in a test and no way to make it observe anything. Every
/// privacy gate mull advertises — excluded apps, secure input, private browsing —
/// lived behind that wall, unverified.
///
/// Naming what the recorder needs from the OS moves all of it behind five
/// properties. `SystemCaptureEnvironment` is the real one; tests use a stub and
/// can finally assert the thing that matters: **that a password copied out of
/// 1Password never reaches the database.**
protocol CaptureEnvironment: AnyObject {
    /// The app in front, as the user would name it. Nil when nothing is frontmost.
    var frontmostAppName: String? { get }
    /// Its bundle identifier, for the exclusion list.
    var frontmostBundleID: String? { get }
    /// The focused window's title, via Accessibility.
    var activeWindowTitle: String? { get }
    /// `NSPasteboard.changeCount` — cheap, and the only way to know a copy happened.
    var clipboardChangeCount: Int { get }
    /// The pasteboard's string contents. Read only after the privacy gates pass:
    /// a secret must not even be held in memory here.
    var clipboardText: String? { get }
    /// Whether the copying app marked this copy "do not store" — the one privacy
    /// signal that is attached to the *copy* rather than to whatever happens to be
    /// frontmost a moment later. Deliberately a separate property from
    /// `clipboardText` so the answer can be had without reading the secret.
    var clipboardIsMarkedDoNotStore: Bool { get }
    /// System-wide secure input — a password field somewhere has the keyboard.
    var isSecureInputEnabled: Bool { get }
    /// Injectable so session durations and timestamps are assertable.
    var now: Date { get }
}

extension CaptureEnvironment {
    var now: Date { Date() }
}
