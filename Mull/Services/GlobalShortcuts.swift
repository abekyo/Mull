import AppKit

/// System-wide hotkeys that work while mull is in the background.
///
/// Separate from AppState because the monitor is a *resource with a lifetime*, not
/// state: it must be registered once and torn down exactly once, and forgetting the
/// teardown leaks a global event tap that keeps firing into a dead object. Owning it
/// in its own object makes that lifetime automatic — `deinit` here removes the
/// monitor, so no owner has to remember to.
///
/// These are `addGlobalMonitorForEvents` observers, not registered hotkeys: they
/// only observe (they never swallow the keystroke), and they require Accessibility
/// permission. Without it the handlers simply never fire — which is why the
/// shortcuts are convenience accelerators for actions that all have in-app entry
/// points too, never the only way to reach something.
final class GlobalShortcuts {

    private var monitor: Any?

    /// Handlers are invoked on the main actor. They are hopped there rather than
    /// called inline because the monitor block runs on whatever thread AppKit
    /// delivers the event on, while every action these drive touches UI state.
    init(onOpenWindow: @escaping () -> Void,
         onCopyContext: @escaping () -> Void,
         onInjectContext: @escaping () -> Void) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // ⌘+Shift+D — open main window
            if mods == [.command, .shift] && event.keyCode == 2 {
                Task { @MainActor in
                    onOpenWindow()
                }
            }

            // ⌘+Shift+C — instant copy context to clipboard (no UI, no sheet)
            if mods == [.command, .shift] && event.keyCode == 8 {
                Task { @MainActor in
                    onCopyContext()
                }
            }

            // ⌘+Shift+W — inject context into current text field (clipboard-safe)
            if mods == [.command, .shift] && event.keyCode == 13 {
                Task { @MainActor in
                    onInjectContext()
                }
            }
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
