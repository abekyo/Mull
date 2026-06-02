import SwiftUI

/// The mull window — a notebook, not a dashboard.
///
/// Like Apple Notes / Obsidian / Bear:
///   Left sidebar: pinned views + files sorted by date
///   Right main area: content of selected item
///
/// Pinned views:
///   📌 Home — AI passport control center
///   📌 Live — real-time event stream
///
/// Files:
///   📄 me.md, now.md — auto-generated context
///   📄 daily summaries — one per day
///   📄 user notes — anything the user creates
struct FullWindowView: View {
    @EnvironmentObject var appState: AppState

    enum SidebarItem: Hashable {
        case home
        case calendar
        case live
        case chat
        case file(mullFile)
    }

    @State private var selection: SidebarItem? = .home
    @State private var fileTree: [mullFileNode] = []
    @State private var editorContent: String = ""
    @State private var isDirty = false
    @State private var searchQuery = ""
    @State private var autoRefreshTimer: Timer?

    // Dialog state
    @State private var showNewFile = false
    @State private var dialogName = ""

    private var mullDir: URL { MullDirectory.root }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            detail
        }
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search projects, files, keywords...")
        .frame(minWidth: 760, minHeight: 560)
        .onAppear { refreshFileTree() }
        .sheet(isPresented: $showNewFile) { newFileSheet }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("mull")
                    .font(DS.smallMedium)
                    .foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: DS.sm) {
                    sidebarButton(icon: "doc.badge.plus", help: "New Note") {
                        dialogName = ""
                        showNewFile = true
                    }
                    sidebarButton(icon: "arrow.clockwise", help: "Refresh") { refreshFileTree() }
                    sidebarButton(icon: "folder", help: "Open in Finder") { NSWorkspace.shared.open(mullDir) }
                }
            }
            .padding(.horizontal, DS.md)
            .padding(.vertical, DS.sm)

            Divider()

            // Copy to AI button
            Button {
                appState.copyContextToClipboard()
            } label: {
                HStack(spacing: DS.sm) {
                    Image(systemName: "doc.on.clipboard")
                        .font(DS.captionFont)
                    Text("Copy to AI")
                        .font(DS.bodyMedium)
                    Spacer()
                    Text("⇧⌘C")
                        .font(DS.miniMedium)
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, DS.md)
                .padding(.vertical, DS.sm)
                .background(Color.accentColor.opacity(0.06))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.xs)

            Divider()

            List(selection: $selection) {
                // Pinned views
                Section("Pinned") {
                    Label("Home", systemImage: "house")
                        .tag(SidebarItem.home)

                    Label("Calendar", systemImage: "calendar")
                        .tag(SidebarItem.calendar)

                    Label("Live", systemImage: "waveform")
                        .tag(SidebarItem.live)

                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                        .tag(SidebarItem.chat)
                }

                // Context files
                Section("Context") {
                    ForEach(contextFiles, id: \.path) { file in
                        sidebarRow(file: file)
                            .tag(SidebarItem.file(file))
                    }
                }

                // Daily summaries
                let dailyFiles = dailySummaryFiles
                if !dailyFiles.isEmpty {
                    Section("Daily") {
                        ForEach(dailyFiles, id: \.path) { file in
                            sidebarRow(file: file)
                                .tag(SidebarItem.file(file))
                        }
                    }
                }

                // Memory files
                let memoryFiles = memoryFolderFiles
                if !memoryFiles.isEmpty {
                    Section("Memory") {
                        ForEach(memoryFiles, id: \.path) { file in
                            sidebarRow(file: file)
                                .tag(SidebarItem.file(file))
                        }
                    }
                }

                // User notes
                let notes = userNoteFiles
                if !notes.isEmpty {
                    Section("Notes") {
                        ForEach(notes, id: \.path) { file in
                            sidebarRow(file: file)
                                .tag(SidebarItem.file(file))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(Color(.controlBackgroundColor).opacity(0.3))
    }

    private func sidebarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(DS.captionFont)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(help)
    }

    private func sidebarRow(file: mullFile) -> some View {
        HStack(spacing: DS.sm) {
            Circle()
                .fill(fileAccent(file))
                .frame(width: 6, height: 6)

            Text(displayName(file))
                .font(DS.bodyFont)
                .lineLimit(1)

            Spacer()

            if file.isAutoGenerated {
                Circle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: 4, height: 4)
            }
        }
        .contextMenu { fileContextMenu(file: file) }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            HomeTab(searchQuery: $searchQuery)
                .environmentObject(appState)

        case .calendar:
            CalendarWeekView()
                .environmentObject(appState)

        case .live:
            LiveTab()
                .environmentObject(appState)

        case .chat:
            ChatPanelView()
                .environmentObject(appState)

        case .file(let file):
            fileEditor(file: file)

        case nil:
            VStack(spacing: DS.lg) {
                Image(systemName: "doc.text")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(.quaternary)
                Text("Select a file or view")
                    .font(DS.titleFont)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.textBackgroundColor))
        }
    }

    // MARK: - File Editor

    private func fileEditor(file: mullFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack(spacing: DS.md) {
                Circle().fill(fileAccent(file)).frame(width: 8, height: 8)
                Text(displayName(file))
                    .font(DS.titleFont)

                if file.isAutoGenerated {
                    Text("auto-generated")
                        .font(DS.miniMedium)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, DS.xs)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                Text(file.sizeFormatted)
                    .font(DS.microFont)
                    .foregroundStyle(.quaternary)

                if !file.isAutoGenerated {
                    if isDirty {
                        Text("Edited")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.paused)
                    }

                    Button("Save") { saveCurrentFile() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isDirty)
                        .keyboardShortcut("s", modifiers: .command)
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(editorContent, forType: .string)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy content")
            }
            .padding(.horizontal, DS.xl)
            .padding(.vertical, DS.sm)

            Divider()

            if file.isAutoGenerated {
                // Read-only view with live refresh
                ScrollView {
                    Text(editorContent)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.lg)
                        .padding(.top, DS.md)
                }
            } else {
                TextEditor(text: $editorContent)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .lineSpacing(4)
                    .padding(.horizontal, DS.lg)
                    .padding(.top, DS.md)
                    .onChange(of: editorContent) { _, _ in isDirty = true }
            }
        }
        .background(Color(.textBackgroundColor))
        .onAppear {
            loadFile(file)
            startAutoRefreshIfNeeded(file)
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .onChange(of: selection) { _, newVal in
            if case .file(let newFile) = newVal {
                loadFile(newFile)
                startAutoRefreshIfNeeded(newFile)
            } else {
                stopAutoRefresh()
            }
        }
    }

    private func startAutoRefreshIfNeeded(_ file: mullFile) {
        stopAutoRefresh()
        guard file.isAutoGenerated else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            guard case .file(let current) = selection, current == file else { return }
            let content = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
            if content != editorContent {
                editorContent = content
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    // MARK: - File Operations

    private func loadFile(_ file: mullFile) {
        if isDirty { saveCurrentFile() }
        editorContent = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        isDirty = false
    }

    private func saveCurrentFile() {
        guard case .file(let file) = selection else { return }
        try? editorContent.write(to: file.url, atomically: true, encoding: .utf8)
        isDirty = false
    }

    // MARK: - New File Sheet

    private var newFileSheet: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("New Note").font(DS.titleFont)
            TextField("filename", text: $dialogName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createNote() }
            Text("~/mull/notes/\(sanitized(dialogName)).md")
                .font(DS.captionFont)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Cancel") { showNewFile = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { createNote() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(dialogName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.xl)
        .frame(width: 300)
    }

    private func createNote() {
        let name = sanitized(dialogName)
        guard !name.isEmpty else { return }
        let notesDir = mullDir.appendingPathComponent("notes")
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let fileName = name.hasSuffix(".md") ? name : "\(name).md"
        let filePath = notesDir.appendingPathComponent(fileName)
        let content = "# \(dialogName.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        try? content.write(to: filePath, atomically: true, encoding: .utf8)
        showNewFile = false
        dialogName = ""
        refreshFileTree()
        let file = mullFile(name: fileName, url: filePath, size: Int64(content.utf8.count), modified: Date(), isAutoGenerated: false)
        selection = .file(file)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func fileContextMenu(file: mullFile) -> some View {
        Button("Open in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        Button("Copy Content") {
            if let content = try? String(contentsOf: file.url, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            }
        }
        if !file.isAutoGenerated {
            Divider()
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(at: file.url)
                selection = .home
                refreshFileTree()
            }
        }
    }

    // MARK: - File Discovery

    private var contextFiles: [mullFile] {
        ["me.md", "now.md", "MEMORY.md"].compactMap { name in
            let url = mullDir.appendingPathComponent(name)
            return makeFile(url: url, autoGenerated: true)
        }
    }

    private var dailySummaryFiles: [mullFile] {
        let dailyDir = mullDir.appendingPathComponent("daily")
        return findMarkdownFiles(in: dailyDir, autoGenerated: true)
            .sorted { $0.modified > $1.modified }
    }

    private var memoryFolderFiles: [mullFile] {
        let memoryDir = mullDir.appendingPathComponent("memory")
        return findMarkdownFiles(in: memoryDir, autoGenerated: true)
    }

    private var userNoteFiles: [mullFile] {
        let notesDir = mullDir.appendingPathComponent("notes")
        return findMarkdownFiles(in: notesDir, autoGenerated: false)
    }

    private func makeFile(url: URL, autoGenerated: Bool) -> mullFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return mullFile(
            name: url.lastPathComponent,
            url: url,
            size: attrs?[.size] as? Int64 ?? 0,
            modified: attrs?[.modificationDate] as? Date ?? Date(),
            isAutoGenerated: autoGenerated
        )
    }

    private func findMarkdownFiles(in directory: URL, autoGenerated: Bool) -> [mullFile] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }

        var files: [mullFile] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if values?.isDirectory == true { continue }
            guard url.pathExtension == "md" else { continue }
            files.append(mullFile(
                name: url.lastPathComponent,
                url: url,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? Date(),
                isAutoGenerated: autoGenerated
            ))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    private func refreshFileTree() {
        // Trigger re-evaluation of computed properties by updating fileTree
        let dailyDir = mullDir.appendingPathComponent("daily")
        let memoryDir = mullDir.appendingPathComponent("memory")
        let notesDir = mullDir.appendingPathComponent("notes")
        var nodes: [mullFileNode] = []
        for dir in [dailyDir, memoryDir, notesDir] {
            let files = findMarkdownFiles(in: dir, autoGenerated: dir != notesDir)
            if !files.isEmpty {
                nodes.append(mullFileNode(name: dir.lastPathComponent, isDirectory: true, file: nil,
                    children: files.map { mullFileNode(name: $0.name, isDirectory: false, file: $0, children: []) }))
            }
        }
        fileTree = nodes
    }

    // MARK: - Helpers

    private func sanitized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    private func displayName(_ file: mullFile) -> String {
        switch file.name {
        case "me.md": return "About Me"
        case "now.md": return "Current Context"
        case "MEMORY.md": return "Memory Index"
        default:
            // Daily files: show date nicely
            if file.name.count == 14 && file.name.hasSuffix(".md") && file.name.contains("-") {
                return String(file.name.dropLast(3)) // "2026-04-02"
            }
            return file.name.replacingOccurrences(of: ".md", with: "")
                .replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private func fileAccent(_ file: mullFile) -> Color {
        switch file.name {
        case "me.md": return .blue
        case "now.md": return DS.recording
        case "MEMORY.md": return DS.paused
        default:
            if file.isAutoGenerated { return Color.accentColor.opacity(0.5) }
            return .secondary.opacity(0.5)
        }
    }
}

// MARK: - Live Tab (kept from original)

struct LiveTab: View {
    @EnvironmentObject var appState: AppState
    @State private var liveEvents: [RecordingEvent] = []
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.md) {
                HStack(spacing: DS.sm) {
                    Circle()
                        .fill(appState.isRecordingDegraded ? DS.paused : (appState.isRecording ? DS.recording : DS.error))
                        .frame(width: 8, height: 8)
                        .shadow(color: appState.isRecording && !appState.isRecordingDegraded ? DS.recording.opacity(0.5) : .clear, radius: 4)
                    Text(appState.isRecordingDegraded ? "Limited" : (appState.isRecording ? "Recording" : "Stopped"))
                        .font(DS.bodyMedium)
                }

                Spacer()

                Text("\(appState.todayEventCount) events")
                    .font(DS.captionFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text(appState.todayStorageFormatted)
                    .font(DS.captionFont)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.xl)
            .padding(.vertical, DS.md)

            HStack(spacing: DS.lg) {
                legendDot(color: DS.eventKeystroke, label: "Keyboard")
                legendDot(color: DS.eventClipboard, label: "Clipboard")
                legendDot(color: DS.eventWindow, label: "Window")
                legendDot(color: DS.eventApp, label: "App")
            }
            .font(DS.captionFont)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, DS.xl)
            .padding(.bottom, DS.sm)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(liveEvents.enumerated()), id: \.offset) { index, event in
                            LiveEventRow(event: event)
                                .id(index)
                        }
                    }
                    .padding(.vertical, DS.sm)
                }
                .onChange(of: liveEvents.count) { _, _ in
                    if let last = liveEvents.indices.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear { startRefresh() }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private func startRefresh() {
        loadEvents()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            loadEvents()
        }
    }

    private func loadEvents() {
        let start = Calendar.current.startOfDay(for: Date())
        let all = appState.database.fetchEvents(from: start, to: Date())
        liveEvents = Array(all.suffix(150))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: DS.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }
}

struct LiveEventRow: View {
    let event: RecordingEvent
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.sm) {
            Text(timeStr)
                .font(DS.microFont)
                .foregroundStyle(.quaternary)
                .frame(width: 48, alignment: .trailing)

            Circle()
                .fill(typeColor)
                .frame(width: 5, height: 5)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 0) {
                if let app = event.appName {
                    Text(app)
                        .font(DS.miniMedium)
                        .foregroundStyle(.tertiary)
                }
                Text(event.textContent ?? "")
                    .font(DS.captionFont)
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(isHovered ? 5 : 1)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, 2)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .onHover { isHovered = $0 }
    }

    private var timeStr: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: event.timestamp)
    }

    private var typeColor: Color {
        switch event.eventType {
        case .keystroke: DS.eventKeystroke
        case .clipboard: DS.eventClipboard
        case .screenText: DS.eventWindow
        case .appSwitch: DS.eventApp
        case .audio: DS.eventAudio
        }
    }
}

// MARK: - Flow Layout (kept for HomeTab/InsightsTab)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

// MARK: - Data Types

struct mullFile: Identifiable, Hashable {
    let name: String
    let url: URL
    let size: Int64
    let modified: Date
    let isAutoGenerated: Bool
    var id: String { url.path }
    var path: String { url.path }
    var sizeFormatted: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    func hash(into hasher: inout Hasher) { hasher.combine(url.path) }
    static func == (lhs: mullFile, rhs: mullFile) -> Bool { lhs.url.path == rhs.url.path }
}

struct mullFileNode: Identifiable {
    let name: String
    let isDirectory: Bool
    let file: mullFile?
    let children: [mullFileNode]
    var id: String { name + (isDirectory ? "/" : "") + (file?.path ?? "") }
}
