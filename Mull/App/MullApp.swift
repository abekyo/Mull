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
                .onAppear { appState.markSummaryRead() }
        } label: {
            Label {
                Text("mull")
            } icon: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: menuBarIconName)
                    if appState.hasUnreadSummary {
                        Circle()
                            .fill(Color.accentColor)
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
        }
    }

    private var menuBarIconName: String {
        if appState.isSummarizing { return "moon.stars.fill" }
        if appState.isPaused { return "moon.zzz" }
        return "moon.fill"
    }
}

// MARK: - AppDelegate — manages real NSWindows directly

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var appState: AppState?
    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Nocturne: the whole app lives on the night canvas, regardless of the
        // system light/dark setting.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if !hasCompletedOnboarding {
            // Delay to let SwiftUI create AppState first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showOnboarding()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showMainWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    // MARK: - Main Window

    func showMainWindow() {
        if let existing = mainWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let appState else { return }
        let view = FullWindowView()
            .environmentObject(appState)
            .preferredColorScheme(.dark)

        let controller = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "mull"
        window.contentViewController = controller
        // Night canvas + a quiet, integrated title bar.
        window.backgroundColor = NSColor(red: 0.039, green: 0.047, blue: 0.078, alpha: 1)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.setFrameAutosaveName("MullMainWindow")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding Window

    func showOnboarding() {
        guard let appState else { return }
        let view = OnboardingView(isPresented: .constant(true))
            .environmentObject(appState)

        let controller = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to mull"
        window.contentViewController = controller
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        showMainWindow()
    }
}
