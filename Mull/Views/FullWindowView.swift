import SwiftUI
import UniformTypeIdentifiers

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
    @State private var savedContent: String = ""   // baseline last loaded/saved (Round-trip ref)
    @State private var isDirty = false
    @State private var searchQuery = ""
    @State private var autoRefreshTimer: Timer?
    @State private var autosaveTimer: Timer?

    // Dialog state
    @State private var showNewFile = false
    @State private var showNewFolder = false
    @State private var dialogName = ""

    private enum NewKind { case note, folder }
    private func startNew(_ kind: NewKind) {
        dialogName = ""
        switch kind {
        case .note: showNewFile = true
        case .folder: showNewFolder = true
        }
    }

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
        .sheet(isPresented: $showNewFolder) { newFolderSheet }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — utility actions only (the window title already says "mull").
            HStack {
                Spacer()
                sidebarButton(icon: "arrow.clockwise", help: "Refresh") { refreshFileTree() }
                sidebarButton(icon: "folder", help: "Reveal ~/mull in Finder") { NSWorkspace.shared.open(mullDir) }
                sidebarButton(icon: "gearshape", help: "Settings (⌘,)") { openSettingsWindow() }
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
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusSm)
                        .fill(DS.moon.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusSm)
                            .strokeBorder(DS.moon.opacity(0.20), lineWidth: 0.75))
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.moon)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.xs)

            Divider()

            List(selection: $selection) {
                // ── The app: primary surfaces ──
                Section {
                    Label("Home", systemImage: "house").tag(SidebarItem.home)
                    Label("Calendar", systemImage: "calendar").tag(SidebarItem.calendar)
                    Label("Live", systemImage: "waveform").tag(SidebarItem.live)
                    Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(SidebarItem.chat)
                }

                // ── Your files: the ~/mull vault — arbitrary nesting, editable,
                //    and openable in Obsidian/Finder (it's just a folder of md). ──
                Section {
                    // Core context, pinned at the top.
                    ForEach(contextFiles, id: \.path) { file in
                        fileRow(file).tag(SidebarItem.file(file))
                    }
                    // The rest of the vault: nested folders + notes, recursively.
                    // A recursive View struct (NOT OutlineGroup) so leaf rows inside
                    // folders stay selectable in the List — OutlineGroup's selection
                    // model doesn't honor per-row .tag the way DisclosureGroup does.
                    ForEach(fileTree) { node in
                        VaultNode(node: node) { file in fileRow(file) }
                    }
                } header: { filesHeader }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // Drag files/folders from Finder onto the vault to import them.
            .dropDestination(for: URL.self) { urls, _ in importURLs(urls); return true }
        }
        .background(DS.canvas)
    }

    /// Open the macOS Settings window. The app is a menu-bar app whose main window
    /// is a custom NSWindow (outside the SwiftUI scene), so we open Settings via the
    /// AppKit action rather than SettingsLink/openSettings (which need the App scene env).
    private func openSettingsWindow() {
        AppDelegate.shared?.showSettings()
    }

    private func sidebarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.inkDim)
        .help(help)
    }

    /// A file row — a document icon + name, with an "auto" mark for mull-generated files.
    private func fileRow(_ file: mullFile) -> some View {
        Label {
            HStack(spacing: DS.sm) {
                Text(displayName(file))
                    .font(DS.bodyFont)
                    .lineLimit(1)
                Spacer()
                if file.isAutoGenerated {
                    Image(systemName: "sparkles")
                        .font(.system(size: 8))
                        .foregroundStyle(DS.moon.opacity(0.55))
                        .help("Auto-generated by mull")
                }
            }
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(fileAccent(file))
        }
        .contextMenu { fileContextMenu(file: file) }
    }

    /// A real, collapsible folder row — folder icon + name + item count.
    @ViewBuilder
    private func folderDisclosure(_ name: String, files: [mullFile]) -> some View {
        if !files.isEmpty {
            DisclosureGroup {
                ForEach(files, id: \.path) { file in
                    fileRow(file).tag(SidebarItem.file(file))
                }
            } label: {
                HStack(spacing: DS.sm) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(DS.moon.opacity(0.7))
                    Text(name).font(DS.bodyFont)
                    Spacer()
                    Text("\(files.count)")
                        .font(DS.miniFont)
                        .foregroundStyle(DS.inkFaint)
                }
            }
        }
    }

    private var filesHeader: some View {
        HStack {
            Text("Files")
            Spacer()
            Menu {
                Button { startNew(.note) } label: { Label("New Note", systemImage: "doc.badge.plus") }
                Button { startNew(.folder) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Divider()
                Button { importFiles() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { exportVault() } label: { Label("Export Vault (.zip)…", systemImage: "square.and.arrow.up") }
                Button { revealVault() } label: { Label("Reveal in Finder", systemImage: "folder") }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.moon)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New · import · export · reveal")
        }
    }

    // MARK: - Vault actions (it's just a folder of md — Obsidian/Finder open it too)

    /// Reveal the whole ~/mull vault in Finder — the bridge to Obsidian/Bear/etc.
    private func revealVault() {
        NSWorkspace.shared.activateFileViewerSelecting([mullDir])
    }

    /// Import files/folders into the vault (copied under notes/, names de-duped).
    private func importFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    private func importURLs(_ urls: [URL]) {
        let fm = FileManager.default
        let dest = mullDir.appendingPathComponent("notes")
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for url in urls {
            let target = uniqueURL(dest.appendingPathComponent(url.lastPathComponent))
            try? fm.copyItem(at: url, to: target)
        }
        refreshFileTree()
    }

    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    /// Export the whole vault as a .zip (via ditto), then reveal it in Finder.
    private func exportVault() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mull-vault.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", mullDir.path, dest.path]
        try? p.run()
        p.waitUntilExit()
        NSWorkspace.shared.activateFileViewerSelecting([dest])
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
            .background(DS.canvas)
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
                // Read-only: render the display layer (表示層), measure-capped & centered.
                ScrollView {
                    MarkdownView(editorContent)
                        .textSelection(.enabled)
                        .frame(maxWidth: DS.readMeasure, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, DS.readMargin)
                        .padding(.top, DS.lg)
                        .padding(.bottom, 160)
                }
            } else {
                // Editable: plain text (原則6 — bytes are never normalised), but with
                // the reading surface's typography and a capped measure for comfort.
                TextEditor(text: $editorContent)
                    .font(DS.readFont)
                    .foregroundStyle(DS.ink)
                    .scrollContentBackground(.hidden)
                    .lineSpacing(DS.readLineSpacing)
                    .frame(maxWidth: DS.readMeasure)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, DS.readMargin)
                    .padding(.top, DS.lg)
                    .onChange(of: editorContent) { _, _ in editorChanged() }
            }
        }
        .background(DS.canvas)
        .onAppear {
            loadFile(file)
            startAutoRefreshIfNeeded(file)
        }
        .onDisappear {
            if isDirty { saveCurrentFile() }   // never lose an edit on close
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
            let content = displayContent(of: file)
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
        editorContent = displayContent(of: file)
        savedContent = editorContent   // baseline: a freshly loaded file is never dirty
        isDirty = false
    }

    /// The editor changed. Dirty is measured against the loaded baseline (so the
    /// programmatic load assignment doesn't count), and we schedule a debounced
    /// autosave so data is never lost — Crane MD principle 5 (速度と信頼が美意識).
    private func editorChanged() {
        isDirty = (editorContent != savedContent)
        autosaveTimer?.invalidate()
        guard isDirty else { return }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            saveCurrentFile()
        }
    }

    /// Content to show in the editor. Auto-generated files (me.md, MEMORY.md, …)
    /// are read-only and keep Curator provenance markers on disk — strip those
    /// markers for display so the user sees clean text, not internal metadata.
    private func displayContent(of file: mullFile) -> String {
        let raw = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        return file.isAutoGenerated ? ContextBlockFile.stripMarkers(raw) : raw
    }

    private func saveCurrentFile() {
        autosaveTimer?.invalidate()
        guard case .file(let file) = selection else { return }
        // 原則6 (Round-trip safety) — two guards:
        // 1. Auto-generated files carry Curator markers we STRIP for display; writing
        //    the stripped buffer back would destroy them. They're read-only. Refuse.
        guard !file.isAutoGenerated else { isDirty = false; return }
        // 2. No-op write guard: if the buffer is byte-identical to disk, don't touch
        //    the file at all — no mtime churn, no chance of altering bytes the user
        //    never edited. A load→save with no change is a true no-op.
        let onDisk = try? String(contentsOf: file.url, encoding: .utf8)
        guard onDisk != editorContent else { savedContent = editorContent; isDirty = false; return }
        try? editorContent.write(to: file.url, atomically: true, encoding: .utf8)
        savedContent = editorContent
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

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("New Folder").font(DS.titleFont)
            TextField("folder name", text: $dialogName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createFolder() }
            Text("~/mull/notes/\(sanitized(dialogName))/")
                .font(DS.captionFont)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Cancel") { showNewFolder = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { createFolder() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(dialogName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.xl)
        .frame(width: 300)
    }

    private func createFolder() {
        let name = sanitized(dialogName)
        guard !name.isEmpty else { return }
        let dir = mullDir.appendingPathComponent("notes").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        showNewFolder = false
        dialogName = ""
        refreshFileTree()
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
        // me.md is mull's read-only guess. me.pinned.md sits right under it and IS
        // editable — it's how you correct/lock facts mull got wrong. mull places its
        // non-comment lines at the top of me.md and never overwrites them.
        _ = Curator.pinnedFacts()   // scaffold me.pinned.md on first run so it's findable
        var files: [mullFile] = []
        if let me = makeFile(url: mullDir.appendingPathComponent("me.md"), autoGenerated: true) {
            files.append(me)
        }
        if let pinned = makeFile(url: mullDir.appendingPathComponent(Curator.pinnedFileName), autoGenerated: false) {
            files.append(pinned)
        }
        for name in ["now.md", "MEMORY.md"] {
            if let f = makeFile(url: mullDir.appendingPathComponent(name), autoGenerated: true) {
                files.append(f)
            }
        }
        return files
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
        fileTree = buildTree(mullDir, isRoot: true)
    }

    /// Walk the vault recursively: folders (with their nested children) then md
    /// files. At the root, the pinned context files are skipped (shown above).
    private func buildTree(_ dir: URL, isRoot: Bool = false) -> [mullFileNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var folders: [mullFileNode] = []
        var files: [mullFileNode] = []
        let pinned: Set<String> = ["me.md", "now.md", "MEMORY.md"]
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                folders.append(mullFileNode(name: url.lastPathComponent, isDirectory: true,
                                            file: nil, children: buildTree(url)))
            } else if url.pathExtension == "md" {
                if isRoot && pinned.contains(url.lastPathComponent) { continue }
                let auto = url.path.contains("/daily/") || url.path.contains("/memory/")
                if let f = makeFile(url: url, autoGenerated: auto) {
                    files.append(mullFileNode(name: f.name, isDirectory: false, file: f, children: []))
                }
            }
        }
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        files.sort { ($0.file?.modified ?? .distantPast) > ($1.file?.modified ?? .distantPast) }
        return folders + files
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
        case Curator.pinnedFileName: return "About Me — your edits"
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
        case Curator.pinnedFileName: return DS.moon
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

/// One row of the vault tree. A recursive View *struct* (a concrete type can refer
/// to itself, unlike an opaque `some View` function) so folders nest to any depth.
/// The leaf's `.tag` is on a concrete row, so List selection works inside folders —
/// which OutlineGroup did not.
private struct VaultNode<Row: View>: View {
    let node: mullFileNode
    let rowFor: (mullFile) -> Row

    var body: some View {
        if let file = node.file {
            rowFor(file).tag(FullWindowView.SidebarItem.file(file))
        } else {
            DisclosureGroup {
                ForEach(node.children) { child in
                    VaultNode(node: child, rowFor: rowFor)
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.moon.opacity(0.75))
            }
        }
    }
}
