import SwiftUI

/// Compact privacy status for the panel footer.
struct PrivacyStatusBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: DS.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)

            Text(statusText)
                .font(DS.microFont)
                .foregroundStyle(.quaternary)
        }
    }

    private var statusColor: Color {
        switch appState.llmProvider {
        case .local: DS.recording
        case .claude, .openai: DS.paused
        }
    }

    private var statusText: String {
        switch appState.llmProvider {
        case .local: "Local · \(appState.todayStorageFormatted)"
        case .claude: "Anthropic API · \(appState.todayStorageFormatted)"
        case .openai: "OpenAI API · \(appState.todayStorageFormatted)"
        }
    }
}
