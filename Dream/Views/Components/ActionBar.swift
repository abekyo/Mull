import SwiftUI

/// The action bar below each summary card.
/// "AI に渡す" is the ONLY primary button — the product's reason for being.
///
/// Keyboard: ⌘+A = AI Export, ⌘+C = Copy, ⌘+E = Export
struct ActionBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var showAIExport: Bool
    @State private var showCopied = false
    @State private var hoveredButton: ActionButton? = nil

    enum ActionButton { case copy, ai, export }

    var body: some View {
        HStack(spacing: 6) {
            // Copy — secondary ⌘C
            actionButton(
                id: .copy,
                label: showCopied ? "Copied!" : "Copy",
                icon: showCopied ? "checkmark" : "doc.on.clipboard",
                shortcut: "C",
                isPrimary: false
            ) {
                copyContent()
            }

            // AI Export — PRIMARY ⌘A (the core value)
            actionButton(
                id: .ai,
                label: "AI に渡す",
                icon: "brain.head.profile",
                shortcut: "A",
                isPrimary: true
            ) {
                showAIExport = true
            }

            // Export — secondary ⌘E
            actionButton(
                id: .export,
                label: "Export",
                icon: "square.and.arrow.up",
                shortcut: "E",
                isPrimary: false
            ) {
                exportToFile()
            }
        }
    }

    // MARK: - Reusable Button with Hover + Shortcut Hint

    @ViewBuilder
    private func actionButton(
        id: ActionButton,
        label: String,
        icon: String,
        shortcut: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(isPrimary ? DS.bodyMedium : DS.bodyFont)

                if hoveredButton == id {
                    Text("⌘\(shortcut)")
                        .font(DS.microFont)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, isPrimary ? DS.lg : DS.md)
            .padding(.vertical, DS.sm)
            .foregroundStyle(isPrimary ? .white : (hoveredButton == id ? .primary : .secondary))
            .background(
                RoundedRectangle(cornerRadius: DS.radiusSm)
                    .fill(
                        isPrimary
                            ? Color.accentColor.opacity(hoveredButton == id ? 0.85 : 1.0)
                            : Color(.controlBackgroundColor).opacity(hoveredButton == id ? 0.9 : 0.6)
                    )
            )
            .scaleEffect(hoveredButton == id ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.spring(duration: 0.15)) {
                hoveredButton = isHovered ? id : nil
            }
        }
        .keyboardShortcut(KeyEquivalent(Character(shortcut.lowercased())), modifiers: .command)
    }

    // MARK: - Actions

    private func copyContent() {
        let text: String
        if let summary = appState.todaySummary {
            text = summary.content
        } else {
            let meFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Dream/me.md")
            if let meContent = try? String(contentsOf: meFile, encoding: .utf8) {
                text = meContent
            } else {
                // Build live context from raw events
                text = buildLiveContext()
            }
        }

        // Apply user's max character setting — truncate silently, don't add noise to output
        let maxChars = UserDefaults.standard.integer(forKey: "outputMaxChars")
        let finalText = (maxChars > 0 && text.count > maxChars)
            ? String(text.prefix(maxChars))
            : text

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalText, forType: .string)

        withAnimation(.spring(duration: 0.2)) { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.spring(duration: 0.2)) { showCopied = false }
        }
    }

    /// Build context from ALL of today's events — unfiltered, AI will judge.
    private func buildLiveContext() -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let events = appState.database.fetchEvents(from: startOfDay, to: Date())

        guard !events.isEmpty else {
            return "No activity recorded yet today."
        }

        var lines: [String] = []
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        lines.append("Raw activity data for today (\(dateStr)). Use this to understand what the user did:")
        lines.append("")

        // ALL events — chronological, no limit, no dedup
        // Grouped by type for readability but nothing is omitted
        let keystrokeEvents = events.filter { $0.eventType == .keystroke }
        let clipEvents = events.filter { $0.eventType == .clipboard }
        let titleEvents = events.filter { $0.eventType == .screenText }
        let sessionEvents = events.filter { $0.eventType == .appSwitch }

        // Window titles — compressed: only keep final version of each typing sequence
        if !titleEvents.isEmpty {
            let compressed = compressSequence(titleEvents.compactMap(\.textContent))
            if !compressed.isEmpty {
                lines.append("Files and pages opened:")
                var seen = Set<String>()
                for title in compressed {
                    let key = String(title.prefix(50).lowercased())
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    lines.append("- \(title)")
                }
                lines.append("")
            }
        }

        // Keystrokes — raw but compressed (remove intermediate typing that became final version)
        if !keystrokeEvents.isEmpty {
            lines.append("Keyboard input (\(keystrokeEvents.count) raw entries):")
            for event in keystrokeEvents {
                guard let text = event.textContent, !text.isEmpty else { continue }
                let clean = String(text.prefix(500)).replacingOccurrences(of: "\n", with: "\\n")
                let time = formatTime(event.timestamp)
                lines.append("- \(time) [\(event.appName ?? "")] \(clean)")
            }
            lines.append("")
        }

        // ALL clipboard — every copy
        if !clipEvents.isEmpty {
            lines.append("Clipboard (copied/pasted — \(clipEvents.count) entries):")
            for event in clipEvents {
                guard let text = event.textContent, !text.isEmpty else { continue }
                let clean = String(text.prefix(1000)).replacingOccurrences(of: "\n", with: "\\n")
                let time = formatTime(event.timestamp)
                lines.append("- \(time) \(clean)")
            }
            lines.append("")
        }

        // App sessions
        let sessions = events.filter { $0.eventType == .appSwitch && ($0.textContent?.contains("(") ?? false) }
        if !sessions.isEmpty {
            lines.append("App sessions:")
            var appSeen = Set<String>()
            for event in sessions.reversed() {
                guard let text = event.textContent, let app = event.appName else { continue }
                guard !appSeen.contains(app) else { continue }
                appSeen.insert(app)
                lines.append("- \(text)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Compress a sequence of incrementally typed strings into final versions only.
    ///
    /// Input:  ["文字を売っても", "文字を売っても何も", "文字を売っても何も文字数が", "文字を売っても何も文字数が増えない", "Queue another"]
    /// Output: ["文字を売っても何も文字数が増えない", "Queue another"]
    ///
    /// Rule: if the next string starts with the current string (or vice versa), keep only the longer one.
    private func compressSequence(_ items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }

        var result: [String] = []

        for i in 0..<items.count {
            let current = items[i]
            let isPrefix: Bool

            if i + 1 < items.count {
                let next = items[i + 1]
                // Current is a prefix of next → this is an intermediate, skip
                isPrefix = next.hasPrefix(current) || current.hasPrefix(next)
            } else {
                isPrefix = false
            }

            if !isPrefix {
                result.append(current)
            }
        }

        return result
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func exportToFile() {
        let content: String
        if let summary = appState.todaySummary {
            content = summary.content
        } else {
            content = "Dream is recording. \(appState.todayEventCount) events captured today."
        }

        let exportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Dream")
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filePath = exportDir.appendingPathComponent("export-\(formatter.string(from: Date())).md")

        try? content.write(to: filePath, atomically: true, encoding: .utf8)
        NSWorkspace.shared.selectFile(filePath.path, inFileViewerRootedAtPath: exportDir.path)
    }

}
