import SwiftUI

@main
struct MullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    init() {}

    var body: some Scene {
        // Share AppState with AppDelegate on every body evaluation
        let _ = { appDelegate.appState = appState }()

        // Menu bar panel (quick access)
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(appState)
                .mullChrome()
                .onAppear { appState.markSummaryRead() }
        } label: {
            // The status item announced as the constant "mull" whatever it was
            // doing: three icon glyphs (summarizing / paused / recording) and an
            // unread badge, none of which are words. The label stays "mull" for the
            // menu bar's own layout; the state rides on the accessibility value.
            Label {
                Text("mull")
                    .accessibilityValue(menuBarStateDescription)
            } icon: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: menuBarIconName)
                    if appState.hasUnreadSummary {
                        Circle()
                            .fill(DS.moon)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -2)
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
                .environmentObject(appState)
                .mullChrome()
        }
        .commands {
            // SwiftUI puts a Help menu in the menu bar whether or not the app has
            // anything to put in it. mull registers no help book (no
            // CFBundleHelpBookName in the bundle), so "mull Help" sat there
            // enabled and clickable and did nothing at all: no Help Viewer, no
            // alert, no window.
            //
            // §7.4 is the standing rule for what that costs. A promise that fails
            // one check makes every other promise suspect, which is why the
            // never-overwrite wording was weakened until it matched the code. A
            // menu item that says Help and answers nothing is the same failure,
            // sitting above everything the app does keep — in the first place
            // somebody deciding whether to hand over Input Monitoring will look.
            //
            // Removed rather than repointed: the repository is private, so a link
            // to the README would 404, and a second broken promise is not an
            // improvement on the first. What explanation the app has is
            // onboarding, still reachable from "Finish Setting Up mull…" for as
            // long as there is setup left to finish.
            CommandGroup(replacing: .help) { }
        }
    }

    /// The words for what `menuBarIconName` and the badge say in shape and colour.
    private var menuBarStateDescription: String {
        var state: String
        if appState.isSummarizing {
            state = String(localized: "Writing tonight's summary")
        } else if appState.isPaused {
            state = String(localized: "Paused")
        } else {
            state = String(localized: "Recording")
        }
        if appState.hasUnreadSummary { state += String(localized: ", unread summary") }
        return state
    }

    /// Three states, drawn as one family: the brand mark, the brand mark filled in
    /// while mull is actually writing, and the brand asleep. The idle state used to
    /// be `moon.fill` — a fourth moon, and the only place the app's own face was a
    /// bare crescent rather than the `moon.stars` it is everywhere else.
    /// `menuBarStateDescription` carries the same three states in words, which is
    /// what a reader who cannot tell two 16pt glyphs apart actually needs.
    private var menuBarIconName: String {
        if appState.isSummarizing { return DS.Glyph.brandWorking }
        if appState.isPaused { return DS.Glyph.asleep }
        return DS.Glyph.brand
    }
}

// MARK: - Settings routing
//
// A deep link into Settings has to be able to say *which* page it means. A
// message that asks you to choose an AI provider and then drops you on General
// is a small dishonesty: it points somewhere and opens somewhere else.
//
// The tab order here mirrors `SettingsView`'s `TabView` exactly. If a tab is
// ever added or reordered there, this enum moves with it.

enum SettingsTab: Int, Hashable, CaseIterable {
    case general = 0
    case ai = 1
    case data = 2
}

/// Carries "open Settings *there*" from any call site to the Settings window.
///
/// It is a separate object from AppState because it is pure navigation intent —
/// nothing here is recorded, persisted, or part of what mull knows about you.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    /// The tab Settings should be showing. Bind this to `TabView(selection:)`.
    @Published var selected: SettingsTab = .general
    private init() {}
}

// MARK: - AppDelegate — manages real NSWindows directly

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var mainWindow: NSWindow?
    var onboardingWindow: NSWindow?

    /// The work the launch wanted to do, held back only until there is an AppState to
    /// do it with.
    ///
    /// Both windows need `appState`, and `appState` arrives from the App scene's first
    /// body evaluation, which may or may not have happened by the time AppKit calls
    /// `applicationDidFinishLaunching`. This used to be papered over with a 0.3s sleep,
    /// which meant every first launch opened onto a third of a second of nothing —
    /// a wait that was too long when SwiftUI was ready immediately and would still have
    /// been a race had it been slow. The assignment itself is the signal, so the window
    /// opens on the exact instant it becomes possible and not a frame later.
    var appState: AppState? {
        didSet {
            guard appState != nil, let open = pendingLaunchWindow else { return }
            pendingLaunchWindow = nil
            open()
        }
    }
    private var pendingLaunchWindow: (() -> Void)?

    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Make the stored language true of the bundle for the *next* launch. This
        // one is already bound: CoreFoundation resolved `.lproj` before any of our
        // code ran. Doing it here rather than only in Settings is what stops a
        // preference the picker has not been moved this session — including every
        // one stored before the windows followed it at all — sitting in Japanese
        // over an English window forever.
        UserLanguage.applyChromeAtLaunch()

        // No `NSApp.appearance` pin. The app used to force `.aqua` here because
        // the palette had a single ivory page; every DS colour token is now a
        // dynamic NSColor with a daylight and a lamplight value, so leaving this
        // nil is what lets them resolve. Setting it — to either name — would
        // freeze the whole app in one appearance again.
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        let openFirstWindow: () -> Void
        if !hasCompletedOnboarding {
            // Pick up where they left off. Onboarding can end without being finished
            // — quit mid-flow, closed window, skipped permissions — and restarting
            // from the welcome screen each time asks the user to re-read a pitch they
            // have already read to get back to the one step they still owe.
            let saved = UserDefaults.standard.integer(forKey: "onboardingStep")
            let startStep = OnboardingView.OnboardingStep(rawValue: saved) ?? .welcome
            openFirstWindow = { [weak self] in self?.showOnboarding(startStep: startStep) }
        } else {
            openFirstWindow = { [weak self] in self?.showMainWindow() }
        }

        if appState != nil {
            openFirstWindow()
        } else {
            pendingLaunchWindow = openFirstWindow
        }

        installSetupMenuItem()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    // MARK: - Main Window

    func showMainWindow() {
        // A closed window is still this window: `isReleasedWhenClosed` is false, so
        // it survives being closed and can simply be ordered back to the front.
        // Gating on `isVisible` meant every reopen built a whole second window and
        // threw the first one away — the tab you were on, the note you had open and
        // the scroll position all went with it.
        if let existing = mainWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let appState else { return }
        let view = FullWindowView()
            .environmentObject(appState)
            .mullChrome()

        let controller = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.contentViewController = controller
        // The page + a quiet, integrated title bar with no visible title text.
        // `DS.canvasNS` is the AppKit form of the same dynamic colour, so this
        // window's background follows the system flip like everything drawn
        // inside it. (`NSColor(DS.canvas)` would also work — the round trip
        // keeps the provider, which `testNSColorRoundTripStaysDynamic` pins —
        // but there is no reason to go out through SwiftUI and back.)
        window.backgroundColor = DS.canvasNS
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.setFrameAutosaveName("MullMainWindow")
        window.isReleasedWhenClosed = false
        installSidebarToggle(on: window, appState: appState)
        window.makeKeyAndOrderFront(nil)

        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Put mull's own show/hide-sidebar button in the title bar, at a place it
    /// cannot leave.
    ///
    /// `NavigationSplitView` offers a toggle for free and `FullWindowView` declines
    /// it (`.toolbar(removing: .sidebarToggle)`), because AppKit lays that one out
    /// against the split divider: collapse the sidebar and the divider goes to x=0,
    /// taking the button ~190pt left to sit by the traffic lights; expand it and the
    /// button comes back. Every press moved the thing that had just been pressed.
    ///
    /// A title-bar accessory with `layoutAttribute = .leading` is measured from the
    /// traffic lights instead. Those never move, so neither does this, in either
    /// state — which is the whole point of moving it here. The button is the same
    /// button in both states, so there is also no second one to find.
    ///
    /// The title bar is otherwise empty (`titleVisibility = .hidden`, no toolbar),
    /// so this costs no window chrome: it occupies space that was already blank.
    private func installSidebarToggle(on window: NSWindow, appState: AppState) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        let hosting = NSHostingController(rootView: SidebarToggle(appState: appState).mullChrome())
        // Sized here rather than left to the hosting controller's fitting size: an
        // accessory taller than the title bar makes AppKit grow the title bar to fit
        // it, which would push the whole page down by however much the button asked
        // for. 28pt is the strip that is already there.
        hosting.view.frame = NSRect(x: 0, y: 0, width: 40, height: 28)
        accessory.view = hosting.view
        window.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: - Settings Window
    //
    // The SwiftUI `Settings` scene's `showSettingsWindow:` action doesn't reliably
    // fire for this menu-bar app whose main window is a custom NSWindow. So we host
    // SettingsView in our own NSWindow, exactly like the main window.
    var settingsWindow: NSWindow?

    /// Open Settings, optionally on a specific tab.
    ///
    /// The tab is set *before* the window is built so a first open lands on the
    /// right page rather than visibly jumping to it. Passing nil leaves whatever
    /// page the user was last on alone — reopening Settings from a neutral place
    /// shouldn't yank them somewhere.
    func showSettings(tab: SettingsTab? = nil) {
        if let tab { SettingsRouter.shared.selected = tab }

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let appState else { return }
        let view = SettingsView()
            .environmentObject(appState)
            .mullChrome()
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = controller
        window.backgroundColor = DS.canvasNS
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding Window

    func showOnboarding(startStep: OnboardingView.OnboardingStep = .welcome) {
        guard let appState else { return }

        // Already up (a second "Finish setup" click): bring it forward rather than
        // building a second window over the first.
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(isPresented: .constant(true), startStep: startStep)
            .environmentObject(appState)
            .mullChrome()

        let controller = NSHostingController(rootView: view)

        // The window takes its size from the content rather than being told one.
        //
        // It used to be built at a hard-coded 460×520 around a view whose own frame is
        // 500×560, with no `.resizable` — so 40 points of width and 40 of height were
        // cropped off a screen the user cannot scroll, and the "Skip for now" line and
        // the primary button at the foot of several steps were simply not reachable.
        // `NSWindow(contentViewController:)` sizes itself to the hosting controller's
        // fitting size, so the two numbers can no longer disagree, and resizing is
        // allowed so a larger text size has somewhere to go.
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Welcome to mull"
        window.backgroundColor = DS.canvasNS
        window.center()
        window.isReleasedWhenClosed = false
        // The red button is a real exit and has to run the real teardown.
        //
        // SwiftUI's `.interactiveDismissDisabled()` on the view does nothing to an
        // AppKit window, so closing here used to bypass `finishOnboarding()`
        // entirely: `onboardingWindow` stayed non-nil (so nothing could reopen it),
        // `showMainWindow()` never ran, and the user was left in a menu-bar-only app
        // that had been granted nothing and recorded nothing, with no way back to
        // setup for the rest of the session. Closing is allowed — being stranded by
        // it is not.
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The finished path: onboarding is done, so the window goes and the app opens.
    func closeOnboarding() {
        guard let window = onboardingWindow else {
            refreshSetupMenuItem()
            showMainWindow()
            return
        }
        onboardingWindow = nil
        // Teardown is already running; the delegate must not run it a second time.
        window.delegate = nil
        window.close()
        refreshSetupMenuItem()
        showMainWindow()
    }

    /// The unfinished path: the user closed the window themselves.
    ///
    /// Same teardown as `closeOnboarding()` — window released, main window opened —
    /// but `hasCompletedOnboarding` deliberately stays false, so the step they left
    /// is where they resume, both from the menu item and on next launch.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === onboardingWindow else { return }
        onboardingWindow = nil
        refreshSetupMenuItem()
        showMainWindow()

        if appState?.hasCompletedOnboarding == false {
            appState?.postNotice(
                String(localized: "Setup isn't finished"),
                detail: String(localized: "mull is recording only what it already has permission for. Pick it back up from mull → Finish Setting Up mull."),
                isProblem: true
            )
        }
    }

    // MARK: - "Finish setup" — the way back into an abandoned onboarding
    //
    // Skipping the permissions step is a legitimate choice, but it used to be a
    // one-way door: onboarding marked itself complete on the way out and never
    // offered itself again, leaving a keystroke recorder that records no
    // keystrokes and never asks again. This menu item is the standing offer.

    private var setupMenuItem: NSMenuItem?
    private var setupMenuSeparator: NSMenuItem?

    /// SwiftUI builds the main menu as the scenes come up, so at the top of
    /// `applicationDidFinishLaunching` there may be nothing to insert into yet.
    ///
    /// Waiting a fixed 0.3s for it was both too long (the menu is usually already
    /// there) and not actually a guarantee (nothing promises it will be there after
    /// any particular interval). So: try now, and if the menu hasn't been built, try
    /// again on the next turn of the run loop until it has. It lands on the first turn
    /// where the insert can succeed. The attempt budget only exists so a hypothetical
    /// menu-less build cannot spin forever.
    private func installSetupMenuItem(attemptsRemaining: Int = 60) {
        guard setupMenuItem == nil else { return }
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.async { self.installSetupMenuItem(attemptsRemaining: attemptsRemaining - 1) }
            return
        }
        let item = NSMenuItem(title: String(localized: "Finish Setting Up mull…"),
                              action: #selector(resumeOnboarding),
                              keyEquivalent: "")
        item.target = self
        let separator = NSMenuItem.separator()
        appMenu.insertItem(item, at: 0)
        appMenu.insertItem(separator, at: 1)
        setupMenuItem = item
        setupMenuSeparator = separator
        refreshSetupMenuItem()
    }

    /// Present only while there is something to finish. Held by reference rather
    /// than by index — the app menu is SwiftUI's, and its contents move.
    func refreshSetupMenuItem() {
        let done = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        setupMenuItem?.isHidden = done
        setupMenuSeparator?.isHidden = done
    }

    @objc private func resumeOnboarding() {
        let saved = UserDefaults.standard.integer(forKey: "onboardingStep")
        showOnboarding(startStep: OnboardingView.OnboardingStep(rawValue: saved) ?? .welcome)
    }

    // MARK: - Permission recovery

    /// One click back to the pane that re-grants a permission mull just lost.
    ///
    /// A sheet on mull's own window rather than a free-standing modal: the user is
    /// most likely somewhere else entirely (often in System Settings, having just
    /// flipped the switch), and an alert that seizes the foreground to tell them
    /// what they already know is exactly the nagging the design north star rules
    /// out. With no window on screen, the in-app notice and the system notification
    /// carry it instead — this simply doesn't fire.
    func presentPermissionRecovery(_ permission: PermissionService.Permission) {
        guard let window = mainWindow, window.isVisible, window.attachedSheet == nil else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "mull stopped recording \(permission.whatStops)"
        alert.informativeText = "\(permission.displayName) is no longer granted to mull. "
            + "Turning it back on picks up where the record left off — nothing already "
            + "kept is affected."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.appState?.openSettingsFor(permission)
        }
    }
}

// MARK: - Sidebar toggle (title-bar accessory)

/// The one control that shows and hides the main window's sidebar.
///
/// Lives in the title bar rather than in either column, for the reason
/// `AppDelegate.installSidebarToggle` gives: measured from the traffic lights, it
/// is in the same spot whether the sidebar is open or shut. Put in a column, it
/// would have to be two buttons — or one that moves.
private struct SidebarToggle: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Button {
            appState.sidebarVisible.toggle()
        } label: {
            Image(systemName: DS.Glyph.sidebar)
                .font(DS.iconBody)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.inkDim)
        // ⌃⌘S is macOS's own sidebar shortcut, and it rides on the visible button
        // rather than on a hidden one in the window's background — the same reason
        // ⌘K rides on the search field's magnifier.
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(appState.sidebarVisible ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")
        .accessibilityLabel(appState.sidebarVisible ? "Hide sidebar" : "Show sidebar")
        .padding(.leading, DS.sm)
    }
}
