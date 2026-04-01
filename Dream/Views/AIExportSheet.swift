import SwiftUI

/// Surface 3: AI Context Selection Sheet.
/// The moment the core value is delivered — "your life, AI-ready."
///
/// 3 layers, not 5 checkboxes. Simple choice:
///   Light  → me.md (~200 tokens)
///   Normal → me.md + now.md (~700 tokens)
///   Full   → full.md (~1,500 tokens)
struct AIExportSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLayer: ExportContextLayer = .now
    @State private var showCopiedConfirmation = false
    @State private var previewText = ""

    private let dreamDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Dream")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI に渡す")
                        .font(.system(size: 16, weight: .semibold))
                    Text("How much context?")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            // Layer selector — 3 radio buttons
            VStack(spacing: 6) {
                ForEach(ExportContextLayer.allCases) { layer in
                    Button {
                        selectedLayer = layer
                        updatePreview()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedLayer == layer ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedLayer == layer ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                                .font(.system(size: 14))

                            Image(systemName: layer.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(selectedLayer == layer ? Color.accentColor : .secondary)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(layer.rawValue)
                                    .font(.system(size: 13, weight: selectedLayer == layer ? .medium : .regular))
                                    .foregroundStyle(.primary)
                                Text(layer.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            Text(layer.tokenEstimate)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(selectedLayer == layer ? Color.accentColor.opacity(0.06) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Stats bar (not raw preview — show what matters)
            HStack(spacing: 12) {
                statPill(icon: "character.cursor.ibeam", value: "\(effectiveCharCount.formatted()) chars")
                statPill(icon: "number", value: "~\(tokenCount) tokens")
                if isTruncated {
                    statPill(icon: "scissors", value: "truncated")
                }
            }
            .padding(.vertical, 4)

            // Compact preview — first 4 lines only
            if !previewText.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(previewLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Copied confirmation + paste hint
            if showCopiedConfirmation {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Copied to clipboard!")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    Text("Paste it at the start of your conversation (⌘V)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // Destination buttons
            Divider()

            VStack(spacing: 6) {
                ForEach(AIExportDestination.allCases) { dest in
                    Button { exportTo(dest) } label: {
                        HStack {
                            Image(systemName: dest.icon)
                            Text(dest.rawValue)
                            Spacer()
                            Text(dest == .clipboard ? "Copy" : "Copy & Open")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13, weight: dest == .claude ? .medium : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .background(
                            dest == .claude
                                ? Color.accentColor.opacity(0.1)
                                : Color(.controlBackgroundColor)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { updatePreview() }
    }

    // MARK: - Logic

    private func updatePreview() {
        previewText = buildContext()
    }

    private var wordCount: Int {
        previewText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.count
    }

    private var tokenCount: Int {
        max(1, Int(Double(wordCount) * 1.3))
    }

    private var effectiveCharCount: Int {
        let maxChars = UserDefaults.standard.integer(forKey: "outputMaxChars")
        if maxChars > 0 && previewText.count > maxChars {
            return maxChars
        }
        return previewText.count
    }

    private var isTruncated: Bool {
        let maxChars = UserDefaults.standard.integer(forKey: "outputMaxChars")
        return maxChars > 0 && previewText.count > maxChars
    }

    private var previewLines: [String] {
        Array(
            previewText.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(4)
        )
    }

    private func statPill(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(value)
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(.tertiary)
    }

    private func buildContext() -> String {
        var parts: [String] = []

        for fileName in selectedLayer.files {
            let filePath = dreamDir.appendingPathComponent(fileName)
            if let content = try? String(contentsOf: filePath, encoding: .utf8) {
                parts.append(content)
            }
        }

        // If no files exist yet, build a minimal context from live data
        if parts.isEmpty {
            return buildFallbackContext()
        }

        // Append today's live summary if available and not yet in file
        if let summary = appState.todaySummary {
            parts.append("\n## Today (live)\n\(summary.content)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Fallback Context (Pre-Dream)

    /// Build context from ALL of today's events. No filtering. AI judges.
    private func buildFallbackContext() -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let events = appState.database.fetchEvents(from: startOfDay, to: Date())

        guard !events.isEmpty else {
            return "No activity recorded yet today."
        }

        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        var lines: [String] = []
        lines.append("Raw activity data for today (\(dateStr)). Use this to understand what the user did:")
        lines.append("")

        let keystrokeEvents = events.filter { $0.eventType == .keystroke }
        let clipEvents = events.filter { $0.eventType == .clipboard }
        let titleEvents = events.filter { $0.eventType == .screenText }

        // Window titles — compressed to final versions only
        if !titleEvents.isEmpty {
            let rawTitles = titleEvents.compactMap(\.textContent)
            let compressed = compressSequence(rawTitles)
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

        // ALL keystrokes — every single one, with timestamps
        if !keystrokeEvents.isEmpty {
            lines.append("Keyboard input (\(keystrokeEvents.count) entries, raw with IME intermediate):")
            for event in keystrokeEvents {
                guard let text = event.textContent, !text.isEmpty else { continue }
                let clean = String(text.prefix(500)).replacingOccurrences(of: "\n", with: "\\n")
                let time = formatTime(event.timestamp)
                lines.append("- \(time) [\(event.appName ?? "")] \(clean)")
            }
            lines.append("")
        }

        // ALL clipboard — every copy, with timestamps
        if !clipEvents.isEmpty {
            lines.append("Clipboard (\(clipEvents.count) entries):")
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

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Compress incrementally typed strings → keep final version only.
    private func compressSequence(_ items: [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        var result: [String] = []
        for i in 0..<items.count {
            let current = items[i]
            if i + 1 < items.count {
                let next = items[i + 1]
                if next.hasPrefix(current) || current.hasPrefix(next) { continue }
            }
            result.append(current)
        }
        return result
    }

    // MARK: - Export Action

    private func exportTo(_ destination: AIExportDestination) {
        let context = buildContext()

        // Apply user's max character setting
        let maxChars = UserDefaults.standard.integer(forKey: "outputMaxChars")
        let finalContext = (maxChars > 0 && context.count > maxChars)
            ? String(context.prefix(maxChars)) + "\n\n[Truncated at \(maxChars) chars. Change in Settings → Export.]"
            : context

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finalContext, forType: .string)

        withAnimation(.easeInOut(duration: 0.2)) { showCopiedConfirmation = true }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [dismiss] in
            if let url = destination.url {
                NSWorkspace.shared.open(url)
            }
            dismiss()
        }
    }
}
