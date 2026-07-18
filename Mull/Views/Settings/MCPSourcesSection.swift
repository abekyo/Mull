import SwiftUI

/// Settings → Data → "Sources (MCP)": register external MCP servers mull pulls
/// from (Gmail, GitHub, …). Changes persist to MCPSourceStore; "Pull now" runs an
/// immediate ingestion so the user can verify a source works.
struct MCPSourcesSection: View {
    @EnvironmentObject var appState: AppState

    @State private var sources: [MCPSourceConfig] = MCPSourceStore.load()
    @State private var newConnector = "gmail"
    @State private var newCommand = ""
    @State private var newArgs = ""
    @State private var newTool = ""
    @State private var newToolArgs = ""
    @State private var isPulling = false

    /// The raw command form is a developer tool sitting in consumer settings, and
    /// what it does — launch a process on this Mac — is not something to leave
    /// open by default. Folded away, and it says what it does before it does it.
    @State private var showAdvanced = false

    /// Per-connector results of the last pull, kept as values rather than being
    /// flattened into one string. The old code rendered "gmail: error" and threw
    /// the actual message away, so a failing source told the user precisely
    /// nothing about why.
    @State private var lastOutcomes: [IngestionService.Outcome] = []
    @State private var lastPullAt: Date?
    /// Set only when a pull produced no outcomes at all — which is a distinct
    /// condition from "every source failed".
    @State private var pullNote: String?
    /// Which connectors have their error text expanded.
    @State private var expandedErrors: Set<String> = []

    /// MCP-pullable connectors (local "capture" is excluded — it's not an MCP source).
    private var connectorChoices: [String] {
        FolderOntology.rawConnectors.filter { $0 != "capture" }
    }

    var body: some View {
        Section("Sources (MCP)") {
            if sources.isEmpty {
                Text("No sources yet. Add an MCP server below to pull email, calendar, GitHub, etc. Nothing is pulled until you add one.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }

            ForEach(Array(sources.enumerated()), id: \.offset) { idx, src in
                sourceRow(idx: idx, src: src)
            }

            advancedForm

            HStack(spacing: DS.sm) {
                Button {
                    pullNow()
                } label: {
                    HStack(spacing: DS.xs) {
                        if isPulling { ProgressView().controlSize(.mini) }
                        Text(isPulling ? "Pulling…" : "Pull now")
                    }
                }
                .disabled(isPulling || sources.allSatisfy { !$0.enabled })

                if let lastPullAt {
                    // Without this, a failed pull and a pull that never happened
                    // look identical.
                    Text("Last pull \(Self.stampFormatter.string(from: lastPullAt))")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkFaint)
                }
            }

            if let pullNote {
                Text(pullNote)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
            }

            ForEach(lastOutcomes, id: \.connector) { outcome in
                outcomeRow(outcome)
            }
        }
    }

    // MARK: - Rows

    private func sourceRow(idx: Int, src: MCPSourceConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DS.hair) {
                Text("\(src.connectorID) · \(src.tool)")
                    .font(DS.bodyMedium)
                Text("\(src.server.command) \(src.server.args.joined(separator: " "))")
                    .font(DS.miniFont)
                    .foregroundStyle(DS.inkGhost)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { sources[idx].enabled },
                set: { sources[idx].enabled = $0; persist() }
            ))
            .labelsHidden()
            .accessibilityLabel("Enable \(src.connectorID)")
            .accessibilityHint("Turns this source on or off for the next pull")
            Button(role: .destructive) {
                sources.remove(at: idx)
                persist()
            } label: {
                Image(systemName: "trash").font(DS.captionFont)
            }
            .buttonStyle(.plain)
            .help("Remove \(src.connectorID)")
            .accessibilityLabel("Remove \(src.connectorID)")
            .accessibilityHint("Deletes this source. It is not asked about first.")
        }
    }

    /// One pull result. Failures carry their real error text, on demand — kept
    /// behind a disclosure so a long stack trace doesn't take over the pane.
    private func outcomeRow(_ outcome: IngestionService.Outcome) -> some View {
        VStack(alignment: .leading, spacing: DS.hair) {
            HStack {
                Text(outcome.connector)
                    .font(DS.captionMedium)
                    .foregroundStyle(outcome.error == nil ? DS.ink : DS.error)
                Spacer()
                if outcome.error == nil {
                    Text("\(outcome.new) new of \(outcome.pulled)")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.inkDim)
                } else {
                    Button(expandedErrors.contains(outcome.connector) ? "Hide detail" : "Show detail") {
                        if expandedErrors.contains(outcome.connector) {
                            expandedErrors.remove(outcome.connector)
                        } else {
                            expandedErrors.insert(outcome.connector)
                        }
                    }
                    .font(DS.captionFont)
                    .controlSize(.small)
                }
            }

            if let error = outcome.error, expandedErrors.contains(outcome.connector) {
                Text(error)
                    .font(DS.microFont)
                    .foregroundStyle(DS.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advancedForm: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: DS.sm) {
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").font(DS.miniFont)
                    Text("mull will launch this command on your Mac, with your account's access, every time it pulls from this source. Add only servers you installed yourself and trust. Nothing runs until you press Add and leave the source enabled.")
                        .font(DS.captionFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.paused)

                Picker("Folder", selection: $newConnector) {
                    ForEach(connectorChoices, id: \.self) { Text($0).tag($0) }
                }
                TextField("Command (e.g. npx)", text: $newCommand)
                if let commandHint {
                    Text(commandHint)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.error)
                }
                TextField("Args (e.g. -y @org/mcp-gmail — quote paths with spaces)", text: $newArgs)
                if !parsedArgs.isEmpty {
                    // Show the split as mull will actually perform it: quoting is
                    // exactly the part that silently went wrong before.
                    Text("Runs as: " + ([trimmedCommand] + parsedArgs).map { "[\($0)]" }.joined(separator: " "))
                        .font(DS.microFont)
                        .foregroundStyle(DS.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Tool to call (e.g. search_messages)", text: $newTool)
                TextField("Tool args (k=v, comma-separated — optional)", text: $newToolArgs)
                Button("Add") { addSource() }
                    .disabled(trimmedCommand.isEmpty
                              || newTool.trimmingCharacters(in: .whitespaces).isEmpty
                              || commandHint != nil)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.vertical, DS.xs)
        } label: {
            Text("Advanced — add a source by command")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
        }
    }

    // MARK: - Input

    private var trimmedCommand: String {
        newCommand.trimmingCharacters(in: .whitespaces)
    }

    private var parsedArgs: [String] {
        Self.parseArguments(newArgs)
    }

    /// The one check worth making before mull agrees to run something: a path that
    /// isn't there. A bare name (`npx`) is resolved from PATH at launch time and
    /// can't be verified here, so it passes without comment.
    private var commandHint: String? {
        let cmd = trimmedCommand
        guard cmd.contains("/") else { return nil }
        let expanded = (cmd as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: expanded)
            ? nil : "No executable at that path."
    }

    /// Split a command line on whitespace while honouring single and double
    /// quotes. `split(separator: " ")` used to tear `"/Users/me/My Tools/srv.js"`
    /// into two broken arguments, and the source then failed at launch with no
    /// hint that the path was the problem.
    static func parseArguments(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false

        for ch in input {
            if let open = quote {
                if ch == open { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true          // "" is a legitimate empty argument
            } else if ch == " " || ch == "\t" {
                if hasToken { args.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { args.append(current) }
        return args
    }

    // MARK: - Actions

    private func addSource() {
        let config = MCPSourceConfig(
            connectorID: newConnector,
            server: .init(command: trimmedCommand, args: parsedArgs),
            tool: newTool.trimmingCharacters(in: .whitespaces),
            arguments: parseKeyValues(newToolArgs),
            enabled: true
        )
        sources.append(config)
        persist()
        newCommand = ""; newArgs = ""; newTool = ""; newToolArgs = ""
    }

    private func persist() {
        MCPSourceStore.save(sources)
    }

    private func pullNow() {
        isPulling = true
        pullNote = nil
        Task {
            let service = IngestionService.fromConfiguredSources()
            let outcomes = await service.runOnce()
            await MainActor.run {
                lastOutcomes = outcomes
                lastPullAt = Date()
                expandedErrors = []
                // `runOnce` returns nothing only when a previous pass is still in
                // flight. The old copy said "No enabled sources" here — which the
                // button's own disabled state already rules out, so it named a
                // cause that could not be the cause.
                pullNote = outcomes.isEmpty
                    ? "A scheduled pull is already running — nothing new was started."
                    : nil
                isPulling = false
            }
        }
    }

    private func parseKeyValues(_ s: String) -> [String: String] {
        var dict: [String: String] = [:]
        for pair in s.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if kv.count == 2, !kv[0].isEmpty { dict[kv[0]] = kv[1] }
        }
        return dict
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}
