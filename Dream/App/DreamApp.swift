import SwiftUI

@main
struct DreamApp: App {
    @StateObject private var appState = AppState()
    @State private var showOnboarding = false

    var body: some Scene {
        // Menu bar panel — Surface 1 & 2
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

        // Onboarding window — shown ONCE on first launch as a real window
        Window("Welcome to Dream", id: "onboarding") {
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(appState)
                .onDisappear {
                    // After onboarding closes, hide dock icon
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Settings window — Surface 5
        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // Full window — Surface 4
        Window("Dream", id: "main-window") {
            FullWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 800, height: 600)
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }

    private var menuBarIconName: String {
        if appState.isDreaming { return "moon.stars.fill" }
        return "moon.fill"
    }
}
