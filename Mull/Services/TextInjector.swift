import AppKit

/// Low-level synthetic input: types text into whatever field currently has focus.
///
/// Separate from AppState because this is input *synthesis*, not state — it posts
/// raw CGEvents at the HID tap and temporarily hijacks the general pasteboard.
/// Both are sharp tools with real failure modes (a dropped restore leaves the
/// user's clipboard clobbered; a mistimed keystroke lands in the wrong app), and
/// they deserve to be read and reviewed on their own rather than buried among
/// @Published properties.
///
/// There is no AX API to set the value of an arbitrary focused field in another
/// app, so paste-simulation is the only general mechanism available. The clipboard
/// save/restore around it is what makes that acceptable to do behind the user's back.
enum TextInjector {

    /// Paste `text` into the focused text field, then restore the previous clipboard.
    /// Returns `false` when the paste could not be attempted at all.
    ///
    /// Posting a synthetic ⌘V at the HID tap requires Accessibility. Without it
    /// `CGEvent.post` is a silent no-op — the keystroke simply never arrives — and
    /// the caller used to go on to tell the user "Your AI context has been pasted"
    /// over a field where nothing happened. Checking first is the only way to tell
    /// those apart, because the post itself reports nothing either way.
    ///
    /// Stays on the main actor: it was extracted from a @MainActor method, and the
    /// two nested `asyncAfter` hops carry non-Sendable AppKit values (NSPasteboard)
    /// across them. The delays are load-bearing — 0.05s lets the pasteboard write
    /// settle before ⌘V is posted, and 0.3s lets the receiving app finish reading
    /// it before the original contents go back.
    @MainActor
    @discardableResult
    static func inject(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        // 1. Save current clipboard
        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        } ?? []

        // 2. Put context on clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Simulate ⌘V to paste into focused field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)
            // Key down: ⌘V
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
            }
            // Key up: ⌘V
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cghidEventTap)
            }

            // 4. Restore original clipboard after paste completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !savedItems.isEmpty {
                    pasteboard.clearContents()
                    for (typeStr, data) in savedItems {
                        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
                    }
                }
            }
        }
        return true
    }
}
