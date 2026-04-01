import SwiftUI

@main
struct DreamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar panel (quick access)
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(appState)
                .onAppear { appState.markDreamRead() }
        } label: {
            Label {
                Text("Dream")
            } icon: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: menuBarIconName)
                    if appState.hasUnreadDream {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -2)
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)

        // Main window (Dock click opens this)
        WindowGroup {
            FullWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 800, height: 600)
        .keyboardShortcut("d", modifiers: [.command, .shift])

        // Settings
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private var menuBarIconName: String {
        if appState.isDreaming { return "moon.stars.fill" }
        if appState.isPaused { return "moon.zzz" }
        return "moon.fill"
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if !hasCompletedOnboarding {
            showOnboarding()
        }
    }

    /// Clicking the Dock icon when no windows are visible reopens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Reopen main window
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func showOnboarding() {
        let appState = AppState()

        let onboardingView = OnboardingView(isPresented: .constant(true))
            .environmentObject(appState)

        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Dream"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }
}
