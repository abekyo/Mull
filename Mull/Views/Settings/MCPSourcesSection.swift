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
    @State private var pullStatus: String?
    @State private var isPulling = false

    /// MCP-pullable connectors (local "capture" is excluded — it's not an MCP source).
    private var connectorChoices: [String] {
        FolderOntology.rawConnectors.filter { $0 != "capture" }
    }

    var body: some View {
        Section("Sources (MCP)") {
            if sources.isEmpty {
                Text("No sources yet. Add an MCP server below to pull email, calendar, GitHub, etc. Nothing is pulled until you add one.")
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }

            ForEach(Array(sources.enumerated()), id: \.offset) { idx, src in
                sourceRow(idx: idx, src: src)
            }

            addForm

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

                if let pullStatus {
                    Text(pullStatus)
                        .font(DS.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Rows

    private func sourceRow(idx: Int, src: MCPSourceConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(src.connectorID) · \(src.tool)")
                    .font(DS.bodyMedium)
                Text("\(src.server.command) \(src.server.args.joined(separator: " "))")
                    .font(DS.miniFont)
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { sources[idx].enabled },
                set: { sources[idx].enabled = $0; persist() }
            ))
            .labelsHidden()
            Button(role: .destructive) {
                sources.remove(at: idx)
                persist()
            } label: {
                Image(systemName: "trash").font(DS.captionFont)
            }
            .buttonStyle(.plain)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("Add source").font(DS.captionFont).foregroundStyle(.secondary)
            Picker("Folder", selection: $newConnector) {
                ForEach(connectorChoices, id: \.self) { Text($0).tag($0) }
            }
            TextField("Command (e.g. npx)", text: $newCommand)
            TextField("Args (space-separated, e.g. -y @org/mcp-gmail)", text: $newArgs)
            TextField("Tool to call (e.g. search_messages)", text: $newTool)
            TextField("Tool args (k=v, comma-separated — optional)", text: $newToolArgs)
            Button("Add") { addSource() }
                .disabled(newCommand.trimmingCharacters(in: .whitespaces).isEmpty
                          || newTool.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.vertical, DS.xs)
    }

    // MARK: - Actions

    private func addSource() {
        let args = newArgs.split(whereSeparator: { $0 == " " }).map(String.init)
        let toolArgs = parseKeyValues(newToolArgs)
        let config = MCPSourceConfig(
            connectorID: newConnector,
            server: .init(command: newCommand.trimmingCharacters(in: .whitespaces), args: args),
            tool: newTool.trimmingCharacters(in: .whitespaces),
            arguments: toolArgs,
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
        pullStatus = nil
        Task {
            let service = IngestionService.fromConfiguredSources()
            let outcomes = await service.runOnce()
            let summary = outcomes.map { o -> String in
                o.error != nil ? "\(o.connector): error" : "\(o.connector): +\(o.new)"
            }.joined(separator: ", ")
            await MainActor.run {
                pullStatus = summary.isEmpty ? "No enabled sources" : summary
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
}
