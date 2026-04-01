import SwiftUI

@main
struct WhatlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar panel (quick access)
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(appState)
                .onAppear { appState.markSummaryRead() }
        } label: {
            Label {
                Text("Whatly")
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
    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

        if !hasCompletedOnboarding {
            showOnboarding()
        } else {
            showMainWindow()
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

        let appState = AppState()
        let view = FullWindowView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whatly"
        window.contentViewController = controller
        window.center()
        window.setFrameAutosaveName("WhatlyMainWindow")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding Window

    func showOnboarding() {
        let appState = AppState()
        let view = OnboardingView(isPresented: .constant(true))
            .environmentObject(appState)

        let controller = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Whatly"
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
