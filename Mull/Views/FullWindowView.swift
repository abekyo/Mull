import SwiftUI
import UniformTypeIdentifiers

/// The mull window — a notebook, not a dashboard.
///
/// Like Apple Notes / Obsidian / Bear:
///   Left sidebar: pinned views + files sorted by date
///   Right main area: content of selected item
///
/// Pinned views: Home (your portrait and today's draft), Calendar, Live, Chat.
///
/// Files: me.md and now.md (written by mull), the daily summaries, and whatever
/// notes you keep yourself — all of it plain markdown in ~/mull.
struct FullWindowView: View {
    @EnvironmentObject var appState: AppState

    enum SidebarItem: Hashable {
        case home
        case calendar
        case live
        case chat
        case file(mullFile)

        /// A stable string to remember this item by between launches. A file is stored
        /// by its path — the same identity `mullFile` itself hashes on — so a note that
        /// has since been renamed or trashed simply fails to resolve rather than
        /// resolving to the wrong note.
        var storageKey: String {
            switch self {
            case .home: return "home"
            case .calendar: return "calendar"
            case .live: return "live"
            case .chat: return "chat"
            case .file(let file): return "file:" + file.path
            }
        }
    }

    @State private var selection: SidebarItem? = .home

    // MARK: What the window remembers between launches
    //
    // mull is meant to be the study you come back to, and a study you come back to
    // does not reset itself to the front page every time you close the door. Two
    // pieces of place survive a quit: the item you were reading, and which folders you
    // had open in the vault.
    //
    // These are @AppStorage rather than @SceneStorage on purpose. @SceneStorage is
    // restored by the system per *scene*, and this window is not one — the app hosts
    // it in a plain NSWindow via NSHostingController (see AppDelegate.showMainWindow),
    // outside any WindowGroup. With no scene to be identified by, @SceneStorage has
    // nowhere to write and behaves as ordinary @State, so it would have quietly
    // persisted nothing at all.

    @AppStorage("sidebar.selection") private var storedSelection = SidebarItem.home.storageKey
    /// Open folders, as a JSON array of vault-relative paths. JSON rather than a
    /// joined string because a folder name may legally contain any separator we'd pick.
    @AppStorage("sidebar.expandedFolders") private var storedExpandedFolders = "[]"

    @FocusState private var searchFocused: Bool         // ⌘K focuses the sidebar search field
    /// Where the user was when search took them to Home, so Esc can put them back.
    /// Nil whenever there is nowhere to return to.
    @State private var searchReturn: SidebarItem?
    @State private var calendarJumpDate: Date? = nil    // a search hit asked to open this day
    /// Home's reading of the record. Owned here so it survives Home being swapped
    /// out of `detail` — see `HomeAnalysis`.
    @StateObject private var homeAnalysis = HomeAnalysis()
    @State private var fileTree: [mullFileNode] = []
    @State private var editorContent: String = ""
    @State private var savedContent: String = ""   // baseline last loaded/saved (Round-trip ref)
    @State private var isDirty = false
    // The file `editorContent` actually came from. `selection` is NOT a safe save
    // target: .onChange(of: selection) fires *after* selection already points at the
    // next file, so a save derived from it would write buffer A into file B's URL.
    @State private var loadedFile: mullFile?
    // Its modification date at load time — a save that finds a newer mtime knows the
    // file was rewritten underneath us (MCP write_note, Obsidian) and refuses.
    @State private var loadedModified: Date?
    @State private var externalChange = false
    /// Non-nil when the last write to disk failed. The buffer stays dirty and the
    /// header says so — silence here loses the user's text.
    @State private var saveError: String?
    /// A note whose name collides with one that already exists; the sheet asks before
    /// anything is written rather than overwriting it.
    @State private var pendingOverwriteName: String?
    /// The file the user asked to delete, held until they confirm.
    @State private var pendingDelete: mullFile?
    @State private var searchQuery = ""
    @State private var autoRefreshTimer: Timer?
    @State private var autosaveTimer: Timer?

    // The vault changes under the app all day (mull's own writers, MCP, Obsidian,
    // Finder). The sidebar watches for that instead of being a snapshot of whatever
    // the folder looked like when the window opened.
    @State private var treeWatchTimer: Timer?
    @State private var treeSignature = ""

    // A regenerated read-only file that is ready but deliberately not shown yet —
    // see `startAutoRefreshIfNeeded`. Held until the reader isn't mid-page.
    @State private var pendingAutoUpdate: String?
    @State private var readScrolledAway = false
    @State private var lastReadInteraction: Date = .distantPast

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
                // One width, pinned — not a range.
                //
                // AppKit lays the title bar's sidebar-toggle button out against the
                // *split divider*, not against the traffic lights: the button sits a
                // fixed distance to the right of wherever the sidebar ends. So a column
                // declared as min/ideal/max is a column whose width SwiftUI is free to
                // re-resolve whenever the sidebar's content changes what it would like
                // to be — a longer file name appearing, a folder opening, the tree being
                // rebuilt — and every one of those re-resolutions slid the toggle button
                // sideways in the title bar. The button appeared to wander on its own,
                // because the thing it is anchored to was wandering.
                //
                // A fixed width can't drift, so the divider can't move and neither can
                // the button. The cost is that the column is no longer drag-resizable;
                // the sidebar holds one search field and a list of file names, all of
                // which already truncate to one line, so there is nothing here that a
                // wider column would reveal.
                .navigationSplitViewColumnWidth(240)
                // Nothing else goes in this window's toolbar, and that is deliberate:
                // the toggle button is laid out *after* whatever items precede it, so
                // every item added here is another thing that can move it. Measured: a
                // single empty item pushed it 44pt to the right.
        } detail: {
            // A page must not be able to decide how tall the window's split view is.
            //
            // Every detail surface here reports an ideal height equal to all of its
            // content — a ScrollView's ideal is its content's, and an NSScrollView
            // wrapping an `isVerticallyResizable` NSTextView answers with the full
            // laid-out height of the note. That ideal used to travel up into the
            // NavigationSplitView, which then laid itself out at *that* height and
            // overflowed the window in both directions. Measured on a 914pt window:
            // a 1610pt split view whose top sat 374pt above the title bar. Both columns
            // rode up with it — the sidebar's search field, "Copy context", Home /
            // Calendar / Live / Chat and the Files header all off the top of the screen,
            // the traffic lights drawn over the file list, the note's own header row
            // gone. Selecting a file with any real content in it was all it took.
            //
            // A GeometryReader takes the size it is offered and never passes a child's
            // appetite upward, so the split view is sized by the window and the page
            // scrolls inside it. (`maxHeight: .infinity` on the page does not do this:
            // it caps how far a view may stretch, not what height it asks for.)
            GeometryReader { _ in
                detail
            }
        }
        // The field belongs to the window; the results are drawn by Home and nowhere
        // else. So typing a query while Calendar, Live, Chat or a note was open used
        // to be swallowed in silence — the box took the text and no surface ever
        // answered it, which reads as "search is broken", not "search is elsewhere".
        // A non-empty query is a request to look something up, so it goes where looking
        // is visible. This is now the *only* thing that moves you: clicking or ⌘K-ing
        // into the field does not, because until there is a query there is nothing to
        // show and nothing worth losing your place over.
        .onChange(of: searchQuery) { _, query in
            let asked = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if asked, selection != .home { leaveForSearch() }
        }
        // Esc is the way back out of search, from anywhere in the window. It used to be
        // handled nowhere in the app at all: once search had moved you to Home there
        // was no keystroke that undid it, and the note you were editing had to be found
        // again by hand in the sidebar.
        .onExitCommand { endSearch() }
        .onChange(of: selection) { _, new in
            storedSelection = (new ?? .home).storageKey
            // Choosing something else yourself ends the round trip. Esc should not then
            // throw you back to a note you had already decided to leave.
            if new != .home { searchReturn = nil }
        }
        // Force the warm brand accent on native controls (buttons, pickers, selection):
        // the user's macOS accent-colour setting otherwise overrides the asset with
        // e.g. system blue, which clashes with the warm palette (DS rule: no raw colors).
        .frame(minWidth: 760, minHeight: 560)
        // One in-app place where mull says what it just did — import, export, a
        // conflict set aside, a context copied. A system notification is invisible
        // under Do Not Disturb; this is not.
        .overlay(alignment: .bottom) { noticeBar }
        .animation(.easeOut(duration: 0.18), value: appState.actionNotice)
        .onAppear {
            scaffoldPinnedFile()
            refreshFileTree()
            restoreSelection()
            startTreeWatch()
        }
        .onDisappear { stopTreeWatch() }
        // The vault is a folder other things write to (mull's own 60s pass, the MCP
        // server, Obsidian, Finder). Coming back to the window is the moment the
        // sidebar most needs to be true. *This* window: the notification fires for
        // every window in the app — the menu-bar panel, Settings, sheets — and each
        // of those used to rebuild (and date-resort) the tree behind your back.
        //
        // Not forced: the click that brings mull forward from another app is the same
        // click that is about to select a note, so a re-sort here lands between the
        // mouse going down and the row being chosen (see `refreshFileTree`). A note
        // added or removed elsewhere still shows up — that changes the vault signature.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window === AppDelegate.shared?.mainWindow else { return }
            // Signature first, off the main thread — the same care the tree watch
            // takes, for the same reason: it walks the whole vault, and this is the
            // one path that ran it inline. On a large vault the click that brings
            // mull forward paid for the walk before the window would draw.
            let root = mullDir
            DispatchQueue.global(qos: .userInitiated).async {
                let signature = Self.vaultSignature(root: root)
                DispatchQueue.main.async {
                    guard signature != treeSignature else { return }
                    refreshFileTree()
                }
            }
        }
        .sheet(isPresented: $showNewFile) { newFileSheet }
        .sheet(isPresented: $showNewFolder) { newFolderSheet }
        // Attached to the window, not to the context menu — the menu is gone by the
        // time the dialog would present.
        .confirmationDialog(
            "Move \"\(pendingDelete?.name ?? "")\" to the Trash?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let file = pendingDelete { trash(file) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("You can put it back from the Trash.")
        }
    }

    // MARK: - Search — a place you can get to, and get back from

    /// Put the caret in the search field. Invoked by the field's own magnifier and by
    /// its ⌘K equivalent.
    ///
    /// It does *nothing else*. Results are drawn by Home and by nowhere else, so search
    /// does eventually have to move you — but only once you have asked something, which
    /// is what `.onChange(of: searchQuery)` below does. Moving on the click itself threw
    /// you off the note you were reading before you had typed a character, and if you had
    /// come to the field by accident there was nothing to show for it but a lost place.
    private func beginSearch() {
        searchFocused = true
    }

    /// Go to Home on search's behalf, remembering where from.
    private func leaveForSearch() {
        flushPendingEdit()
        searchReturn = selection
        selection = .home
    }

    /// Put the query away and, if search had moved the user, put them back.
    private func endSearch() {
        searchQuery = ""
        searchFocused = false
        guard let back = searchReturn else { return }
        searchReturn = nil
        // The note may have gone while search was open — trashed from the context menu,
        // or moved in Finder. Returning to a path that no longer resolves would open an
        // editor onto nothing; staying on Home is the honest outcome.
        if case .file(let file) = back,
           !FileManager.default.fileExists(atPath: file.path) { return }
        selection = back
    }

    // MARK: - Restoring where you were

    /// Reopen whatever was on screen when the window last closed.
    ///
    /// A file that has since been renamed, trashed or moved out of the vault is simply
    /// gone — landing on Home is better than opening an empty editor onto a path that
    /// no longer resolves. The vault-root check is the same one every other read here
    /// makes: a stale default must not be able to name a file outside ~/mull.
    private func restoreSelection() {
        switch storedSelection {
        case SidebarItem.calendar.storageKey: selection = .calendar
        case SidebarItem.live.storageKey: selection = .live
        case SidebarItem.chat.storageKey: selection = .chat
        case SidebarItem.home.storageKey: selection = .home
        default:
            guard storedSelection.hasPrefix("file:") else { selection = .home; return }
            let path = String(storedSelection.dropFirst("file:".count))
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(mullDir.standardizedFileURL.path + "/"),
                  let file = makeFile(url: url, autoGenerated: isAutoGenerated(url)) else {
                selection = .home
                return
            }
            selection = .file(file)
        }
    }

    /// Whether mull writes this file itself — the same rule `buildTree` and
    /// `contextFiles` apply, stated once so a restored file cannot come back editable
    /// when the sidebar considers it read-only.
    private func isAutoGenerated(_ url: URL) -> Bool {
        if url.path.contains("/daily/") || url.path.contains("/memory/") { return true }
        return Self.pinnedRootFiles.first { $0.name == url.lastPathComponent }?.autoGenerated ?? false
    }

    /// Which vault folders are open, by path. Held in defaults so the shape you left
    /// the sidebar in is the shape you find it in.
    private var expandedFolders: Binding<Set<String>> {
        Binding(
            get: {
                guard let data = storedExpandedFolders.data(using: .utf8),
                      let paths = try? JSONDecoder().decode([String].self, from: data)
                else { return [] }
                return Set(paths)
            },
            set: { open in
                guard let data = try? JSONEncoder().encode(open.sorted()),
                      let text = String(data: data, encoding: .utf8) else { return }
                storedExpandedFolders = text
            }
        )
    }

    // MARK: - Notice bar

    @ViewBuilder
    private var noticeBar: some View {
        if let notice = appState.actionNotice {
            HStack(alignment: .firstTextBaseline, spacing: DS.md) {
                Image(systemName: notice.isProblem ? "exclamationmark.circle" : "checkmark.circle")
                    .font(DS.captionFont)
                    .foregroundStyle(notice.isProblem ? DS.error : DS.moon)
                VStack(alignment: .leading, spacing: DS.hair) {
                    Text(notice.text)
                        .font(DS.bodyMedium)
                        .foregroundStyle(DS.ink)
                    if let detail = notice.detail {
                        Text(detail)
                            .font(DS.captionFont)
                            .foregroundStyle(DS.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: DS.md)
                if let url = notice.revealURL {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.plain)
                    .font(DS.captionMedium)
                    .foregroundStyle(DS.moon)
                }
                Button { appState.dismissNotice() } label: {
                    Image(systemName: "xmark").font(DS.miniMedium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.inkFaint)
                .help("Dismiss")
                .accessibilityLabel("Dismiss notice")
            }
            .padding(.horizontal, DS.lg)
            .padding(.vertical, DS.md)
            .frame(maxWidth: 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMd).fill(DS.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .strokeBorder(notice.isProblem ? DS.error.opacity(0.35) : DS.hairline, lineWidth: 0.75)
            )
            .shadow(color: DS.ink.opacity(0.12), radius: 14, y: 5)
            .padding(DS.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Watching the vault

    /// Poll the vault's *shape* every few seconds and rebuild the sidebar when it
    /// moves. The signature is folder mtimes + file names, not file contents: adding,
    /// renaming or removing a note changes it, typing inside one does not — so the
    /// list never reshuffles under the cursor while you write.
    private func startTreeWatch() {
        stopTreeWatch()
        let root = mullDir
        treeWatchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // Off the main thread: this walks the whole vault.
            DispatchQueue.global(qos: .utility).async {
                let signature = Self.vaultSignature(root: root)
                DispatchQueue.main.async {
                    guard signature != treeSignature else { return }
                    refreshFileTree()
                }
            }
        }
    }

    private func stopTreeWatch() {
        treeWatchTimer?.invalidate()
        treeWatchTimer = nil
    }

    private nonisolated static func vaultSignature(root: URL) -> String {
        // Relative paths only — no mtimes. Folder mtimes looked like a cheap "did
        // the shape move" bit, but every atomic save (write temp + rename, which is
        // how both the 0.8s autosave and mull's own 60s context pass write) bumps
        // the parent folder's mtime. So the signature moved while you typed, and the
        // sidebar rebuilt and reshuffled under the cursor — the exact thing it was
        // built to prevent. A path changes exactly when the shape changes: a note or
        // folder added, removed, renamed, or moved. Typing inside one changes none.
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return "" }
        let rootPath = root.path
        var parts: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard isDir || url.pathExtension == "md" else { continue }
            var rel = url.path
            if rel.hasPrefix(rootPath) { rel = String(rel.dropFirst(rootPath.count)) }
            parts.append(isDir ? rel + "/" : rel)
        }
        // Enumeration order is the filesystem's business, not a change in shape.
        return parts.sorted().joined(separator: "|")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — utility actions only (the window title already says "mull").
            HStack {
                Spacer()
                sidebarButton(
                    icon: "arrow.clockwise",
                    label: "Reread your mull folder",
                    hint: "Reloads ~/mull from disk, picking up edits made outside mull",
                    help: "Reread ~/mull from disk (⌘R)"
                ) { refreshFileTree(force: true) }   // asked for by hand: always rebuild
                    .keyboardShortcut("r", modifiers: .command)
                sidebarButton(
                    icon: "folder",
                    label: "Reveal your mull folder in Finder",
                    help: "Reveal ~/mull in Finder"
                ) { NSWorkspace.shared.open(mullDir) }
                sidebarButton(
                    icon: "gearshape",
                    label: "Settings",
                    help: "Settings (⌘,)"
                ) { openSettingsWindow() }
            }
            .padding(.horizontal, DS.md)
            .padding(.vertical, DS.sm)

            searchField
                .padding(.horizontal, DS.sm)
                .padding(.bottom, DS.sm)

            Divider()

            // Lend your context to whatever you're talking to.
            Button {
                appState.copyContextToClipboard()
            } label: {
                HStack(spacing: DS.sm) {
                    Image(systemName: "doc.on.clipboard")
                        .font(DS.captionFont)
                    Text("Copy context")
                        .font(DS.bodyMedium)
                    Spacer()
                    Text("⇧⌘C")
                        .font(DS.miniMedium)
                        .foregroundStyle(DS.inkFaint)
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
                        VaultNode(node: node,
                                  path: node.name,
                                  expandedFolders: expandedFolders) { file in fileRow(file) }
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

    /// The search field, in one fixed place.
    ///
    /// It used to be `.searchable(placement: .toolbar)`, which on macOS is a *collapsing*
    /// toolbar item: unfocused it is a magnifier glyph, and the click meant to focus it
    /// is the click that expands it into a field — so the control slid out from under the
    /// pointer at the moment it was aimed at. A box you have to catch is worse than one
    /// that is simply always there, and the sidebar has the room. So it lives here and it
    /// does not move: same size focused or not, same place whatever the detail shows.
    private var searchField: some View {
        HStack(spacing: DS.sm) {
            // ⌘K rides on the visible glyph rather than on a hidden, empty-titled button
            // in the window's background: a command with no affordance is one only its
            // author knows about, and VoiceOver read the old one out as an unnamed button.
            Button { beginSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(DS.iconSmall)
                    .foregroundStyle(DS.inkFaint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Search (⌘K)")
            .accessibilityLabel("Search")
            .accessibilityHint("Results appear on Home. Esc clears the query and puts you back.")

            TextField("Search projects, files, keywords…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(DS.bodyFont)
                .foregroundStyle(DS.ink)
                .focused($searchFocused)
                .accessibilityLabel("Search")

            // Hidden rather than absent while there is nothing to clear: taking the
            // button out of the layout would resize the field the moment you typed,
            // which is the same twitch this whole change is here to remove.
            Button { endSearch() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(DS.iconSmall)
                    .foregroundStyle(DS.inkFaint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(searchQuery.isEmpty ? 0 : 1)
            .disabled(searchQuery.isEmpty)
            .accessibilityHidden(searchQuery.isEmpty)
            .help("Clear search")
            .accessibilityLabel("Clear search")
        }
        .padding(.horizontal, DS.sm)
        .padding(.vertical, DS.xs + 1)
        .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSm)
            .strokeBorder(searchFocused ? DS.moon.opacity(0.4) : DS.hairline, lineWidth: 0.75))
    }

    /// Open the macOS Settings window. The app is a menu-bar app whose main window
    /// is a custom NSWindow (outside the SwiftUI scene), so we open Settings via the
    /// AppKit action rather than SettingsLink/openSettings (which need the App scene env).
    private func openSettingsWindow() {
        AppDelegate.shared?.showSettings()
    }

    /// `help:` is a mouse tooltip and nothing else — it never reaches VoiceOver.
    /// An icon-only button therefore needs `label`/`hint` as well, which is why
    /// these are separate parameters rather than one string reused for both: the
    /// tooltip can carry the key equivalent ("⌘R"), the spoken label should not.
    private func sidebarButton(
        icon: String,
        label: String,
        // Only where the hint has something the label and tooltip don't already say.
        // A hint that paraphrases its own label is read aloud as a second sentence
        // that carries no second fact.
        hint: String = "",
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(DS.iconBody)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.inkDim)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    /// A file row — a document icon + name. Who wrote the file is said once, by the
    /// "auto-generated" badge in the editor header; a second marker in the sidebar
    /// spent an icon on a bit the user has already been told.
    private func fileRow(_ file: mullFile) -> some View {
        Label {
            Text(displayName(file))
                .font(DS.bodyFont)
                .lineLimit(1)
                .help(displayName(file))
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(fileAccent(file))
        }
        .contextMenu { fileContextMenu(file: file) }
    }

    private var filesHeader: some View {
        HStack(spacing: DS.xs) {
            Text("Files")
            Spacer(minLength: 0)
            Menu {
                Button { startNew(.note) } label: { Label("New Note", systemImage: "doc.badge.plus") }
                Button { startNew(.folder) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Divider()
                Button { importFiles() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { exportVault() } label: { Label("Export mull Folder (.zip)…", systemImage: "square.and.arrow.up") }
                Button { revealVault() } label: { Label("Reveal in Finder", systemImage: "folder") }
            } label: {
                // A quiet, header-scaled plus — thin, tobacco, with a comfortable
                // square hit target so it sits flush with the "Files" baseline.
                Image(systemName: "plus")
                    .font(DS.iconMini.weight(.semibold))
                    .foregroundStyle(DS.moon)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("New · import · export · reveal")
            .accessibilityLabel("File actions")
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

    /// Copy the chosen items into ~/mull/notes and say what happened. Silence used to
    /// cover both outcomes equally: a file that copied and a file that didn't looked
    /// exactly the same from the outside.
    private func importURLs(_ urls: [URL]) {
        let fm = FileManager.default
        let dest = mullDir.appendingPathComponent("notes")
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            appState.postNotice("Couldn't import into ~/mull/notes",
                                detail: error.localizedDescription, isProblem: true)
            return
        }

        var imported: [URL] = []
        var failures: [String] = []
        for url in urls {
            let target = uniqueURL(dest.appendingPathComponent(url.lastPathComponent))
            do {
                try fm.copyItem(at: url, to: target)
                imported.append(target)
            } catch {
                failures.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        refreshFileTree()

        let names = imported.map(\.lastPathComponent)
        if failures.isEmpty {
            guard !imported.isEmpty else { return }
            appState.postNotice(
                imported.count == 1 ? "Imported \(names[0])" : "Imported \(imported.count) items",
                detail: "Copied into ~/mull/notes — still plain files, still yours.",
                revealURL: imported.first)
        } else if imported.isEmpty {
            appState.postNotice("Nothing was imported",
                                detail: failures.joined(separator: "\n"), isProblem: true)
        } else {
            appState.postNotice("Imported \(imported.count) of \(urls.count)",
                                detail: "Couldn't copy:\n" + failures.joined(separator: "\n"),
                                revealURL: imported.first, isProblem: true)
        }
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

    /// Export the whole vault as a .zip. The zip is built off the main thread (a large
    /// vault used to freeze the window on `waitUntilExit`), into a temporary file
    /// beside the destination — so a failed export can neither destroy a zip that was
    /// already there nor end with Finder proudly revealing an empty folder.
    private func exportVault() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mull-folder.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let source = mullDir
        appState.postNotice("Exporting your mull folder…", detail: "Zipping ~/mull. A large folder takes a moment.")
        Task {
            switch await Self.zipVault(source: source, to: dest) {
            case .success:
                appState.postNotice("mull folder exported",
                                    detail: "\(dest.lastPathComponent) — plain markdown, readable without mull.",
                                    revealURL: dest)
            case .failure(let message):
                appState.postNotice("Export failed", detail: message, isProblem: true)
            }
        }
    }

    private enum ExportOutcome: Sendable {
        case success
        case failure(String)
    }

    private nonisolated static func zipVault(source: URL, to dest: URL) async -> ExportOutcome {
        await Task.detached(priority: .userInitiated) { () -> ExportOutcome in
            let fm = FileManager.default
            // Same directory as the destination, so the final move stays on one volume.
            let staging = dest.deletingLastPathComponent()
                .appendingPathComponent(".mull-export-\(UUID().uuidString).zip")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, staging.path]
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return .failure(error.localizedDescription)
            }
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                try? fm.removeItem(at: staging)
                let text = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .failure(text.isEmpty ? "ditto exited with code \(process.terminationStatus)." : text)
            }

            do {
                if fm.fileExists(atPath: dest.path) {
                    _ = try fm.replaceItemAt(dest, withItemAt: staging)
                } else {
                    try fm.moveItem(at: staging, to: dest)
                }
            } catch {
                try? fm.removeItem(at: staging)
                return .failure(error.localizedDescription)
            }
            return .success
        }.value
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            // `homeAnalysis` is held here rather than inside HomeTab because this
            // switch is what destroys HomeTab: each branch has its own identity, so
            // leaving Home threw away the fortnight of analysis it had just run and
            // the filters the reader had set. See `HomeAnalysis`.
            HomeTab(analysis: homeAnalysis, searchQuery: $searchQuery, onOpenDay: { date in
                calendarJumpDate = date
                selection = .calendar
            })
                .environmentObject(appState)

        case .calendar:
            CalendarWeekView(jumpDate: $calendarJumpDate)
                .environmentObject(appState)

        case .live:
            LiveTab()
                .environmentObject(appState)

        case .chat:
            ChatPanelView(chat: appState.chat)
                .environmentObject(appState)

        case .file(let file):
            fileEditor(file: file)

        case nil:
            VStack(spacing: DS.lg) {
                Image(systemName: "doc.text")
                    .font(DS.iconHero.weight(.thin))
                    .foregroundStyle(DS.inkFaint)
                Text("Select a file or view")
                    .font(DS.titleFont)
                    .foregroundStyle(DS.inkFaint)
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
                HStack(spacing: DS.md) {
                    Circle().fill(fileAccent(file)).frame(width: 8, height: 8)
                    Text(displayName(file))
                        .font(DS.titleFont)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(fileRole(file))

                if file.isAutoGenerated {
                    // Read-only is a fact about who may write here, not a decorative
                    // tag — it says so in words, with the lock, at reading size.
                    // No tooltip: every auto-generated file carries a custode note under
                    // this header that says the same thing at reading size, and for me.md
                    // hands over the button that acts on it.
                    Label("Written by mull · read-only", systemImage: "lock")
                        .font(DS.captionMedium)
                        .foregroundStyle(DS.inkDim)
                }

                Spacer()

                // A newer version of a read-only file is ready, but the user is
                // mid-page — showing it is their call, not a timer's (see
                // `startAutoRefreshIfNeeded`).
                if file.isAutoGenerated, pendingAutoUpdate != nil {
                    Button {
                        applyPendingAutoUpdate()
                    } label: {
                        Label("mull updated this — show", systemImage: "arrow.down.circle")
                            .font(DS.captionMedium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.moon)
                    .help("A newer version is ready. Your place on the page is kept until you ask for it.")
                }

                if !file.isAutoGenerated {
                    Text(editorStats)
                        .font(DS.microFont)
                        .foregroundStyle(DS.inkFaint)
                        .help("Live word and character count for this note")
                }

                Text(file.sizeFormatted)
                    .font(DS.microFont)
                    .foregroundStyle(DS.inkFaint)

                if !file.isAutoGenerated {
                    if let saveError {
                        // The write failed. Say so, keep Save enabled, and never let
                        // the badge imply the text is safely on disk.
                        Text("Not saved")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.error)
                            .help("mull couldn't write this file: \(saveError)\n\nYour text is still here. Try Save again, or copy it out.")
                    } else if externalChange {
                        // Someone else (MCP, Obsidian, Finder) rewrote this file while
                        // it was open. Autosave has stopped writing so their text is
                        // safe; the banner below offers both ways out.
                        Text("Changed on disk")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.error)
                            .help("This file changed outside mull. Choose which version to keep — the other one is set aside, not lost.")
                    } else if isDirty {
                        Text("Edited")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.paused)
                    }

                    // ⌘S during a conflict must not quietly erase the other writer's
                    // text: it goes through the same keep-mine path as the banner,
                    // which copies the disk version aside first.
                    Button("Save") {
                        if externalChange { resolveConflict(file, keepMine: true) }
                        else { saveFile(file, force: true) }
                    }
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
                .accessibilityLabel("Copy content")
                .accessibilityHint("Copies the whole of \(displayName(file)) to the clipboard")
                .help("Copy content")
            }
            .padding(.horizontal, DS.xl)
            .padding(.vertical, DS.sm)

            Divider()

            if externalChange, !file.isAutoGenerated {
                conflictBanner(file: file)
            }

            if file.isAutoGenerated {
                // Read-only: render the display layer (表示層), measure-capped & centered.
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.lg) {
                        custodeNote(for: file)
                        MarkdownView(editorContent,
                                     sourcePath: vaultRelativePath(of: file),
                                     onOpenVaultFile: openVaultFile)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: DS.readMeasure, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, DS.readMargin)
                    .padding(.top, DS.lg)
                    .padding(.bottom, 160)
                    // Where the page has been scrolled to. Used only to decide whether
                    // a background regeneration may replace the text under the reader.
                    .background(
                        GeometryReader { proxy in
                            let offset = proxy.frame(in: .named(Self.readScrollSpace)).minY
                            Color.clear
                                .onChange(of: offset) { _, new in readScrolledAway = new < -8 }
                        }
                    )
                }
                .coordinateSpace(name: Self.readScrollSpace)
                // A fresh page per file, exactly as the editor gets one. Without this the
                // same ScrollView is reused from one read-only file to the next, and it
                // keeps the scroll offset it had: leave me.md scrolled to the bottom, open
                // MEMORY.md, and it opens at the bottom too — or partway down a page you
                // have never seen. A file opens at its top.
                .id(file.path)
                // Moving the pointer over the page is the cheapest available signal
                // that someone is actually reading it (a text selection is invisible
                // to SwiftUI). It only ever delays an update; it never blocks one.
                .onContinuousHover { phase in
                    if case .active = phase { lastReadInteraction = Date() }
                }
            } else {
                if file.name == Curator.pinnedFileName {
                    custodeNote(for: file)
                        .frame(maxWidth: DS.readMeasure, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, DS.readMargin)
                        .padding(.top, DS.lg)
                }
                // Editable: Bear-style live decoration over plain markdown. The buffer on
                // disk stays byte-identical (原則6); only its on-screen appearance is
                // enriched. Typography/colours live inside the NSTextView, so the measure
                // cap and margins are all that's left here.
                // Sized from the room available, never from the length of the note.
                //
                // An NSScrollView holding an `isVerticallyResizable` NSTextView answers
                // "how big would you like to be?" with the full laid-out height of the
                // text, and that answer used to travel all the way up: the VStack took
                // it, and so did the whole NavigationSplitView. Measured on a 914pt
                // window — a 1610pt split view whose top sat 374pt above the title bar,
                // carrying *both* columns up out of view. The sidebar's search field,
                // "Copy context", Home/Calendar/Live/Chat and the Files header were all
                // off the top of the screen, the traffic lights ended up drawn over the
                // file list, and the note's own header row was gone. Selecting a long
                // enough note was all it took; the read-only files, which render through
                // a SwiftUI ScrollView instead, were never affected.
                //
                // A GeometryReader is what breaks the chain: it always takes the size it
                // is offered and never reports a child's appetite upward. `maxHeight:
                // .infinity` and the representable's own `sizeThatFits` were both tried
                // first and neither held — the ideal size still escaped.
                GeometryReader { room in
                    MarkdownTextEditor(text: $editorContent, sourcePath: vaultRelativePath(of: file))
                        // Fresh editor per file: switching notes rebuilds the NSTextView,
                        // so content swaps can never fight a live editing session (and
                        // the undo stack no longer bleeds across files).
                        .id(file.path)
                        .frame(width: min(room.size.width, DS.readMeasure),
                               height: room.size.height)
                        .frame(width: room.size.width, alignment: .center)
                }
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
            flushPendingEdit()   // never lose an edit on close
            stopAutoRefresh()
        }
        .onChange(of: selection) { _, newVal in
            if case .file(let newFile) = newVal {
                loadFile(newFile)
                startAutoRefreshIfNeeded(newFile)
            } else {
                // Leaving the editor for Home/Calendar/…: .onDisappear is not
                // guaranteed to run before the buffer is torn down, so flush here too.
                flushPendingEdit()
                stopAutoRefresh()
            }
        }
        // Autosave is a 0.8s debounce and .onDisappear does not run on quit, so ⌘Q
        // within that window used to drop the last keystrokes. Terminate and window
        // close are the two remaining exits — flush on both.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushPendingEdit()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            flushPendingEdit()
        }
    }

    /// Word · character count for the open buffer, shown in the editor toolbar.
    /// Words are ICU word segments (`.byWords`), so Japanese text — which has no
    /// spaces for a naive split to find — counts correctly. Above a size no real
    /// mull note reaches, the per-keystroke enumeration is dropped and only the
    /// character count remains.
    private var editorStats: String {
        let chars = editorContent.count
        guard chars <= 100_000 else { return "\(chars.formatted()) chars" }
        var words = 0
        editorContent.enumerateSubstrings(in: editorContent.startIndex...,
                                          options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        return "\(words.formatted()) words · \(chars.formatted()) chars"
    }

    /// Write the buffer to the file it was loaded from, if it has unsaved changes.
    private func flushPendingEdit() {
        guard isDirty, let file = loadedFile else { return }
        saveFile(file)
    }

    /// Keep a read-only file current — without yanking the page out from under the
    /// person reading it.
    ///
    /// This used to reassign `editorContent` every 5 seconds regardless, which
    /// rebuilds the rendered markdown: scroll position back to the top, any text
    /// selection gone, mid-sentence. Now an unchanged file is left completely alone,
    /// and a changed one is only swapped in when the reader is demonstrably not in
    /// the middle of the page. Otherwise the new text waits behind a quiet "show"
    /// button in the header — mull offers, the reader decides.
    private func startAutoRefreshIfNeeded(_ file: mullFile) {
        stopAutoRefresh()
        pendingAutoUpdate = nil
        guard file.isAutoGenerated else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            guard case .file(let current) = selection, current == file else { return }
            let content = displayContent(of: file)
            guard content != editorContent else {
                pendingAutoUpdate = nil   // whatever was pending is now what's on screen
                return
            }
            if isReadingActively {
                pendingAutoUpdate = content
            } else {
                editorContent = content
                pendingAutoUpdate = nil
            }
        }
    }

    /// Scrolled off the top, or the pointer moved over the page in the last 20s.
    private var isReadingActively: Bool {
        readScrolledAway || Date().timeIntervalSince(lastReadInteraction) < 20
    }

    private func applyPendingAutoUpdate() {
        guard let content = pendingAutoUpdate else { return }
        editorContent = content
        pendingAutoUpdate = nil
    }

    private func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        pendingAutoUpdate = nil
    }

    // MARK: - Conflicts (never destroy either version)

    /// Someone else wrote this file while it was open in mull. Both texts are real
    /// work; whichever one loses the file is written beside it and the user is told
    /// where it went. Nothing is discarded on the user's behalf.
    private func conflictBanner(file: mullFile) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text("\(file.name) changed outside mull")
                .font(DS.bodyMedium)
                .foregroundStyle(DS.ink)
            Text("Something else — the MCP server, Obsidian, Finder — rewrote this file while you were editing it. Both versions still exist. Whichever one you set aside is kept as a file next to this one; mull throws neither of them away.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.sm) {
                Button("Keep my version") { resolveConflict(file, keepMine: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Take the version on disk") { resolveConflict(file, keepMine: false) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, DS.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.moon.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }

    private static let conflictStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func resolveConflict(_ file: mullFile, keepMine: Bool) {
        let disk = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        let mine = editorContent

        // Write the losing version beside the file BEFORE anything is overwritten.
        var sidecar: URL?
        if disk != mine {
            let losing = keepMine ? disk : mine
            let label = keepMine ? "from-disk" : "your-edit"
            let base = file.url.deletingPathExtension().lastPathComponent
            let ext = file.url.pathExtension.isEmpty ? "md" : file.url.pathExtension
            let name = "\(base).conflict-\(Self.conflictStamp.string(from: Date()))-\(label).\(ext)"
            let target = uniqueURL(file.url.deletingLastPathComponent().appendingPathComponent(name))
            do {
                try losing.write(to: target, atomically: true, encoding: .utf8)
                FilePrivacy.protectFile(at: target)
                sidecar = target
            } catch {
                // Couldn't preserve the other side — so don't destroy it either.
                appState.postNotice("Couldn't set the other version aside",
                                    detail: "\(error.localizedDescription)\n\nNothing was overwritten. Copy your text out, or open the file in Finder, before choosing again.",
                                    revealURL: file.url, isProblem: true)
                return
            }
        }

        if keepMine {
            do {
                try mine.write(to: file.url, atomically: true, encoding: .utf8)
                FilePrivacy.protectFile(at: file.url)
            } catch {
                appState.postNotice("Couldn't write \(file.name)",
                                    detail: error.localizedDescription, isProblem: true)
                return
            }
            savedContent = mine
        } else {
            editorContent = disk
            savedContent = disk
        }

        loadedModified = modificationDate(of: file.url)
        externalChange = false
        saveError = nil
        isDirty = false
        refreshFileTree()

        let detail: String
        if let sidecar {
            detail = keepMine
                ? "The version that was on disk is safe in \(sidecar.lastPathComponent)."
                : "Your edit is safe in \(sidecar.lastPathComponent)."
        } else {
            detail = "Both versions were identical — there was nothing to set aside."
        }
        appState.postNotice(keepMine ? "Kept your version" : "Took the version on disk",
                            detail: detail, revealURL: sidecar)
    }

    // MARK: - Custode notes (who may write here, and how you correct it)

    /// A short, plain explanation above a file mull owns — and, for me.md, the way
    /// out: the pinned file is the user's means of correction, so it gets a real
    /// invitation rather than a lock icon and silence.
    @ViewBuilder
    private func custodeNote(for file: mullFile) -> some View {
        switch file.name {
        case "me.md":
            VStack(alignment: .leading, spacing: DS.sm) {
                Text("This is mull's reading of you, rewritten as it learns. That's why you can't type into it — the next pass would write over you.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Anything you write in \(Curator.pinnedFileName) is taken as true and kept above mull's own guesses. It is never overwritten. That file is how you correct what mull thinks.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    openPinnedFile()
                } label: {
                    Label("Correct this in \(Curator.pinnedFileName)", systemImage: "square.and.pencil")
                        .font(DS.smallMedium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.moon)
                .padding(.top, DS.xs)
            }
            .padding(DS.md)
            .background(RoundedRectangle(cornerRadius: DS.radiusSm).fill(DS.moon.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusSm).strokeBorder(DS.moon.opacity(0.18), lineWidth: 0.75))

        case Curator.pinnedFileName:
            Text("You own this file. mull reads it and never writes to it — every line that isn't a comment is placed above mull's own guesses in About Me.")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)

        default:
            if file.isAutoGenerated {
                Text("Copy it, move it, open it in anything — it's plain markdown either way.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Open me.pinned.md, creating it from the template if this is the first time.
    private func openPinnedFile() {
        _ = Curator.pinnedFacts()   // scaffolds the file if it isn't there yet
        refreshFileTree()
        let url = mullDir.appendingPathComponent(Curator.pinnedFileName)
        guard let file = makeFile(url: url, autoGenerated: false) else {
            appState.postNotice("Couldn't open \(Curator.pinnedFileName)",
                                detail: "mull could not create it in ~/mull. Check the folder is writable.",
                                isProblem: true)
            return
        }
        selection = .file(file)
    }

    // MARK: - File Operations

    private func loadFile(_ file: mullFile) {
        // Flush the OUTGOING file explicitly. By the time .onChange(of: selection)
        // calls us, `selection` is already the new file — deriving the save target
        // from it wrote the previous buffer over the newly opened note.
        //
        // If that flush FAILS, the outgoing text exists nowhere but in `editorContent`,
        // and the next line is about to overwrite it. Stay on the file that didn't
        // save, with the error showing, rather than navigating over the user's words.
        if isDirty, let previous = loadedFile, previous != file {
            guard saveFile(previous) else {
                selection = .file(previous)
                return
            }
        }
        // Nothing to load when the buffer already *is* this file and holds words
        // that are not on disk. Reading the file back here would destroy them, and
        // every route into that is a route this view takes on its own:
        //
        //   - the refusal above assigns `selection`, which re-fires
        //     .onChange(of: selection) and calls straight back in with the file
        //     whose save just failed. The flush guard cannot catch it (`previous ==
        //     file`), so the next line would overwrite exactly the text it had just
        //     refused to navigate away from;
        //   - leaving for Home and coming back does the same thing a slower way,
        //     because the flush on the way out is allowed to fail quietly.
        //
        // Both used to end with the conflict banner gone and the edits with it.
        if isDirty, loadedFile == file { return }
        editorContent = displayContent(of: file)
        savedContent = editorContent   // baseline: a freshly loaded file is never dirty
        loadedFile = file
        loadedModified = modificationDate(of: file.url)
        externalChange = false
        saveError = nil   // a previous file's write failure isn't this file's problem
        isDirty = false
        // A fresh page: nothing held back, nothing scrolled, no reading in progress.
        pendingAutoUpdate = nil
        readScrolledAway = false
        lastReadInteraction = .distantPast
    }

    /// Coordinate space for the read-only page, so its scroll offset can be observed.
    private static let readScrollSpace = "mull.readScroll"

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The editor changed. Dirty is measured against the loaded baseline (so the
    /// programmatic load assignment doesn't count), and we schedule a debounced
    /// autosave so data is never lost — Crane MD principle 5 (速度と信頼が美意識).
    private func editorChanged() {
        isDirty = (editorContent != savedContent)
        autosaveTimer?.invalidate()
        guard isDirty, let file = loadedFile else { return }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            // Captured, not re-derived: the timer must write to the file this buffer
            // belongs to even if the user has since selected another note.
            saveFile(file)
        }
    }

    /// A file's path relative to the vault root, which is the frame every link in
    /// these documents is written in. Nil for anything outside ~/mull.
    private func vaultRelativePath(of file: mullFile) -> String? {
        let root = mullDir.standardizedFileURL.path + "/"
        let path = file.url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }

    /// Follow a link into another vault file: select it in the sidebar and open it,
    /// exactly as clicking it there would. `MEMORY.md` is an index of these, and an
    /// index whose entries send you to Finder is not an index.
    private func openVaultFile(_ relativePath: String) {
        let url = MullDirectory.url(for: relativePath).standardizedFileURL
        guard url.path.hasPrefix(mullDir.standardizedFileURL.path + "/"),
              let file = makeFile(url: url, autoGenerated: isAutoGenerated(url)) else { return }
        selection = .file(file)
    }

    /// Content to show in the editor. Auto-generated files (me.md, MEMORY.md, …)
    /// are read-only and keep Curator provenance markers on disk — strip those
    /// markers for display so the user sees clean text, not internal metadata.
    private func displayContent(of file: mullFile) -> String {
        let raw = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        return file.isAutoGenerated ? ContextBlockFile.stripMarkers(raw) : raw
    }

    /// Write the buffer to `file` — always the file the buffer was loaded from,
    /// never whatever is selected right now. `force` is the user pressing Save,
    /// which is allowed to win a conflict with an outside writer.
    /// Returns false when the buffer is NOT safely on disk, so callers that are about
    /// to discard it (switching files, closing) can refuse.
    @discardableResult
    private func saveFile(_ file: mullFile, force: Bool = false) -> Bool {
        autosaveTimer?.invalidate()
        // 原則6 (Round-trip safety) — three guards:
        // 1. Auto-generated files carry Curator markers we STRIP for display; writing
        //    the stripped buffer back would destroy them. They're read-only. Refuse.
        guard !file.isAutoGenerated else { isDirty = false; return true }
        // 2. No-op write guard: if the buffer is byte-identical to disk, don't touch
        //    the file at all — no mtime churn, no chance of altering bytes the user
        //    never edited. A load→save with no change is a true no-op.
        let onDisk = try? String(contentsOf: file.url, encoding: .utf8)
        guard onDisk != editorContent else {
            savedContent = editorContent
            loadedModified = modificationDate(of: file.url)
            externalChange = false
            saveError = nil
            isDirty = false
            return true
        }
        // 3. Clobber guard: the editor deliberately refuses to sync an external write
        //    into a first-responder text view (IME safety), so the buffer can be stale.
        //    If the file's mtime moved since we loaded it, someone else (MCP write_note,
        //    Obsidian) owns the newer text — an automatic save must not erase it. The
        //    user's edit stays in the buffer, and an explicit Save can still override.
        if !force, file == loadedFile, let loadedAt = loadedModified,
           let current = modificationDate(of: file.url), current > loadedAt.addingTimeInterval(0.5) {
            externalChange = true
            return false   // the buffer is not on disk — do not let a caller discard it
        }
        // 4. A failed write must never look like a successful one. This used to be
        //    `try?` followed unconditionally by `isDirty = false`, so a full disk or a
        //    revoked folder permission cleared the "Edited" badge and greyed out Save
        //    while the text existed nowhere but in memory — the user closed the window
        //    and lost it. Keep the buffer dirty and say what went wrong.
        do {
            try editorContent.write(to: file.url, atomically: true, encoding: .utf8)
            FilePrivacy.protectFile(at: file.url)
        } catch {
            saveError = error.localizedDescription
            return false
        }
        saveError = nil
        savedContent = editorContent
        if file == loadedFile {
            loadedModified = modificationDate(of: file.url)
            externalChange = false
            isDirty = false
        }
        return true
    }

    // MARK: - New File Sheet

    private var newFileSheet: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("New Note").font(DS.titleFont)
            TextField("filename", text: $dialogName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createNote() }
            Text(newNotePathPreview(dialogName))
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
                .confirmationDialog(
                    "\"\(pendingOverwriteName ?? "")\" already exists",
                    isPresented: Binding(
                        get: { pendingOverwriteName != nil },
                        set: { if !$0 { pendingOverwriteName = nil } }
                    )
                ) {
                    Button("Open the existing note") {
                        if let name = pendingOverwriteName { openExistingNote(fileName: name) }
                        pendingOverwriteName = nil
                    }
                    Button("Replace it", role: .destructive) {
                        if let name = pendingOverwriteName {
                            let url = mullDir.appendingPathComponent("notes").appendingPathComponent(name)
                            writeNewNote(at: url, fileName: name)
                        }
                        pendingOverwriteName = nil
                    }
                    Button("Cancel", role: .cancel) { pendingOverwriteName = nil }
                } message: {
                    Text("Replacing it discards everything that note currently contains. This cannot be undone.")
                }
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
        let fileName = noteFileName(dialogName)
        guard !fileName.isEmpty else {
            appState.postNotice("That name can't be used",
                                detail: "A note needs at least one character that can go in a file name.",
                                isProblem: true)
            return
        }
        let notesDir = mullDir.appendingPathComponent("notes")
        do {
            try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        } catch {
            appState.postNotice("Couldn't create ~/mull/notes",
                                detail: error.localizedDescription, isProblem: true)
            return
        }
        let filePath = notesDir.appendingPathComponent(fileName)
        // Creating a note twice under the same name used to overwrite the first one
        // with an empty stub — no warning, no undo, the note simply gone. Ask.
        if FileManager.default.fileExists(atPath: filePath.path) {
            pendingOverwriteName = fileName
            return
        }
        writeNewNote(at: filePath, fileName: fileName)
    }

    /// The actual creation, shared by the first-time path and the "open the existing
    /// one" path so both end up selecting the same file.
    private func writeNewNote(at filePath: URL, fileName: String) {
        let content = "# \(dialogName.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        do {
            try content.write(to: filePath, atomically: true, encoding: .utf8)
            FilePrivacy.protectFile(at: filePath)
        } catch {
            // The sheet stays open, and the failure is said out loud — `saveError`
            // alone only shows in the editor header, which isn't on screen yet.
            saveError = error.localizedDescription
            appState.postNotice("Couldn't create \(fileName)",
                                detail: error.localizedDescription, isProblem: true)
            return
        }
        showNewFile = false
        dialogName = ""
        refreshFileTree()
        let file = mullFile(name: fileName, url: filePath, size: Int64(content.utf8.count), modified: Date(), isAutoGenerated: false)
        selection = .file(file)
    }

    /// Open the note that already carries this name, instead of creating a second one.
    private func openExistingNote(fileName: String) {
        let url = mullDir.appendingPathComponent("notes").appendingPathComponent(fileName)
        showNewFile = false
        dialogName = ""
        refreshFileTree()
        if let file = makeFile(url: url, autoGenerated: false) {
            selection = .file(file)
        }
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("New Folder").font(DS.titleFont)
            TextField("folder name", text: $dialogName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createFolder() }
            Text(sanitized(dialogName).isEmpty ? "~/mull/notes/…" : "~/mull/notes/\(sanitized(dialogName))/")
                .font(DS.captionFont)
                .foregroundStyle(DS.inkFaint)
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
        guard !name.isEmpty else {
            appState.postNotice("That name can't be used",
                                detail: "A folder needs at least one character that can go in a folder name.",
                                isProblem: true)
            return
        }
        let dir = mullDir.appendingPathComponent("notes").appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            appState.postNotice("Couldn't create \(name)",
                                detail: error.localizedDescription, isProblem: true)
            return
        }
        showNewFolder = false
        dialogName = ""
        refreshFileTree()
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func fileContextMenu(file: mullFile) -> some View {
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        Button("Copy content") {
            if let content = try? String(contentsOf: file.url, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            }
        }
        if !file.isAutoGenerated {
            Divider()
            Button("Move to Trash", role: .destructive) { pendingDelete = file }
        }
    }

    /// Deleting used to be one unconfirmed click straight to `removeItem` — no
    /// dialog, no Trash, no undo, and a silent no-op when it failed. The vault is
    /// the user's own writing; it gets the same treatment Finder would give it.
    private func trash(_ file: mullFile) {
        do {
            try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        } catch {
            // Not `saveError`: that renders as the "Not saved" badge in the *open*
            // file's header, so a failed trash either accused a different, perfectly
            // saved note of being unwritten, or — with no file open — was reported
            // nowhere at all, which is the silent no-op this method exists to end.
            appState.postNotice(
                "Couldn't move \(file.name) to the Trash",
                detail: error.localizedDescription,
                isProblem: true
            )
            return
        }
        if case .file(let open) = selection, open == file { selection = .home }
        refreshFileTree()
    }

    // MARK: - File Discovery

    /// Lay down `me.pinned.md` if it isn't there yet, so the sidebar has something to
    /// list. Once per window, on appear — the file is the user's, and deciding whether
    /// to write it is not something to do again every time the sidebar draws.
    private func scaffoldPinnedFile() {
        _ = Curator.pinnedFacts()
    }

    /// The root files the sidebar pins above the vault tree — in the order it shows
    /// them, and who writes each one.
    ///
    /// One table, because this list used to be spelled out by hand in three places and
    /// one of them spelled it short: `buildTree`'s skip set named me.md, now.md and
    /// MEMORY.md but not `me.pinned.md`, so that file was drawn **twice** — once in the
    /// pinned section and again down among the root files of the tree. Both rows carry
    /// the same `.tag`, so selecting it highlighted two rows for one file and the List
    /// scrolled off to the second one, which is what "the sidebar moves" looked like.
    /// A list that three call sites have to agree about is a list that belongs in one
    /// place.
    private static let pinnedRootFiles: [(name: String, autoGenerated: Bool)] = [
        ("me.md", true),                    // mull's reading of you — read-only
        (Curator.pinnedFileName, false),    // yours; mull reads it and never writes it
        ("now.md", true),
        ("MEMORY.md", true),
    ]

    /// The same names as a set, for "is this row already drawn above?" questions.
    private static let pinnedRootNames = Set(pinnedRootFiles.map(\.name))

    private var contextFiles: [mullFile] {
        // me.md is mull's read-only guess. me.pinned.md sits right under it and IS
        // editable — it's how you correct/lock facts mull got wrong. mull places its
        // non-comment lines at the top of me.md and never overwrites them.
        // The scaffolding this used to do lives in `scaffoldPinnedFile()` now. It is
        // a *write* — `Curator.readPinned()` lays the template down when the file is
        // missing or still untouched — and this property is read from inside `body`,
        // which re-runs on AppState's 3s republish and on every search keystroke.
        // Disk reads and a conditional file write, on the main thread, as a side
        // effect of drawing a sidebar.
        Self.pinnedRootFiles.compactMap {
            makeFile(url: mullDir.appendingPathComponent($0.name), autoGenerated: $0.autoGenerated)
        }
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

    /// Rebuild the sidebar from disk — but only when the vault's *shape* actually
    /// moved, unless the user asked for it by hand (⌘R).
    ///
    /// Rebuilding unconditionally is not free: `buildTree` sorts every folder's notes
    /// by modification date, and mull rewrites its own files all day (now.md and me.md
    /// on the 60s pass, the daily file, memory/…). So a rebuild that found no new note
    /// still handed the List a *differently ordered* array — rows moved under the
    /// pointer and the table scrolled to keep the selection in view.
    ///
    /// The worst possible moment for that is the window becoming key, because the click
    /// that activates mull from another app is the same click that is about to land on
    /// a row: the list re-sorted between the mouse going down and the row being chosen.
    /// The signature guard is the one the tree watch already applies (see
    /// `vaultSignature`); this path used to be the hole in it.
    private func refreshFileTree(force: Bool = false) {
        let signature = Self.vaultSignature(root: mullDir)
        guard force || signature != treeSignature else { return }
        fileTree = buildTree(mullDir, isRoot: true)
        treeSignature = signature
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
        let pinned = Self.pinnedRootNames
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
        // By NAME, never by modification date. Date order meant that writing in a note
        // moved it: the row you were working in jumped to the top of its folder the
        // next time the tree was rebuilt, and everything below it slid down. A sidebar
        // is a place you learn where things are — a note has to stay where you left it,
        // and the one you are editing least of all should move.
        //
        // `daily/` is the exception that keeps its sense of time, and gets it for free:
        // its files are named yyyy-MM-dd, so descending by name IS newest-first, and it
        // is stable because a name only changes when the file does.
        let newestFirst = dir.lastPathComponent == "daily"
        files.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return newestFirst ? order == .orderedDescending : order == .orderedAscending
        }
        return folders + files
    }

    // MARK: - Helpers

    /// Make a name safe to put on disk without rewriting what the user meant.
    ///
    /// Path separators become hyphens (a "/" used to sail through and quietly target
    /// a folder that doesn't exist, so creation just failed), runs of whitespace
    /// become single hyphens, and leading dots are dropped (they'd hide the file).
    /// Capitalisation is the user's business: lowercasing it turned "iOS-notes" into
    /// something they didn't type.
    private func sanitized(_ name: String) -> String {
        var value = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        while value.hasPrefix(".") { value.removeFirst() }
        return value
    }

    /// The file name a note will actually get — ".md" appended only when it isn't
    /// already there, so "foo.md" stays "foo.md" instead of becoming "foo.md.md".
    private func noteFileName(_ raw: String) -> String {
        let base = sanitized(raw)
        guard !base.isEmpty else { return "" }
        return base.lowercased().hasSuffix(".md") ? base : base + ".md"
    }

    /// The path the note will really be written to, shown before it is.
    private func newNotePathPreview(_ raw: String) -> String {
        let name = noteFileName(raw)
        return name.isEmpty ? "~/mull/notes/…" : "~/mull/notes/\(name)"
    }

    private static let dailyFileNameFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dailyDisplayFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        return f
    }()

    /// What to call a file in the UI.
    ///
    /// Only files mull generates get a friendlier name. A note the user named is
    /// shown exactly as it sits on disk: the old rule title-cased it, swapped its
    /// hyphens for spaces and stripped ".md" — so "iOS-notes.md" appeared as
    /// "Ios Notes", which is neither the file's name nor anything you could search
    /// Finder for. On-disk names are never touched by any of this.
    private func displayName(_ file: mullFile) -> String {
        switch file.name {
        case "me.md": return "About Me"
        case Curator.pinnedFileName: return "About Me — your edits"
        case "now.md": return "Current Context"
        case "MEMORY.md": return "Memory Index"
        default:
            // A generated daily summary is named for its date — read it back as one.
            if file.isAutoGenerated, file.name.hasSuffix(".md"),
               let date = Self.dailyFileNameFormat.date(from: String(file.name.dropLast(3))) {
                return Self.dailyDisplayFormat.string(from: date)
            }
            return file.name
        }
    }

    /// The words for what `fileAccent` says in colour. The dot beside the file name
    /// is the only thing distinguishing "mull wrote this" from "you wrote this", so
    /// the distinction has to exist as text too or it does not exist for anyone
    /// using VoiceOver — or, for that matter, anyone who cannot separate slate from
    /// tobacco at 8 points.
    private func fileRole(_ file: mullFile) -> String {
        switch file.name {
        case "me.md": return "Your profile, written by mull"
        case Curator.pinnedFileName: return "Your own edits to your profile"
        case "now.md": return "Current context, written by mull"
        case "MEMORY.md": return "Memory index, written by mull"
        default:
            if file.isAutoGenerated { return "Written by mull" }
            return "Your note"
        }
    }

    private func fileAccent(_ file: mullFile) -> Color {
        switch file.name {
        case "me.md": return DS.slate
        case Curator.pinnedFileName: return DS.moon
        case "now.md": return DS.recording
        case "MEMORY.md": return DS.paused
        default:
            if file.isAutoGenerated { return DS.moon.opacity(0.5) }
            return DS.inkFaint
        }
    }
}

// MARK: - Live Tab (kept from original)

struct LiveTab: View {
    @EnvironmentObject var appState: AppState
    @State private var liveEvents: [RecordingEvent] = []
    @State private var refreshTimer: Timer?
    /// Whether the stream is currently resting on its newest row. Following the tail
    /// used to be unconditional, so scrolling up to read anything was undone by the
    /// next poll (≤1.5s) — the history was all there and none of it was readable.
    /// mull follows only while you are already at the bottom; the moment you scroll
    /// away it stops and waits for you to come back down.
    @State private var pinnedToBottom = true

    /// Coordinate space for the stream, so the content's bottom edge can be compared
    /// against the visible height.
    private static let streamSpace = "mull.liveStream"

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
                // "Limited" alone does not say limited-how; the dot's colour was
                // carrying the severity. Combine the pair so the dot stops
                // announcing as a stray image, and spell the state out as the value.
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording status")
                .accessibilityValue(
                    appState.isRecordingDegraded
                        ? "Limited — mull is running, but a permission it needs was withheld"
                        : (appState.isRecording
                            ? "Recording — mull is capturing your activity"
                            : "Stopped — mull is not capturing anything")
                )

                Spacer()

                // Not a score for the day. This is how many records mull stored —
                // named for the mechanism, pluralised properly, and kept quiet enough
                // that it reads as a footnote rather than a result.
                Text(appState.todayCaptureLabel)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .monospacedDigit()
                    .help("Records stored today: buffered keystroke lines, clipboard entries, window and app changes. A count of what was kept, not a measure of what you did.")

                Text(appState.todayStorageFormatted)
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
            }
            .padding(.horizontal, DS.xl)
            .padding(.vertical, DS.md)

            // Every colour the stream can draw has a key here. Two of them (the page
            // body and audio) used to appear in the list with nothing to read them
            // against, which turns a legend from an explanation into a half-truth.
            HStack(spacing: DS.lg) {
                legendDot(color: DS.eventKeystroke, label: "Keyboard")
                legendDot(color: DS.eventClipboard, label: "Clipboard")
                legendDot(color: DS.eventWindow, label: "Window")
                legendDot(color: LiveEventRow.pageBodyColor, label: "Page text")
                legendDot(color: DS.eventApp, label: "App")
                legendDot(color: DS.eventAudio, label: "Audio")
            }
            .font(DS.captionFont)
            .foregroundStyle(DS.inkFaint)
            .padding(.horizontal, DS.xl)
            .padding(.bottom, DS.sm)

            Divider()

            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.hair) {
                            if liveEvents.isEmpty {
                                emptyState
                            } else {
                                // Keyed by row id, not by index: the list is a sliding
                                // window, so index N is a different event every refresh
                                // — hover and text selection used to jump to whatever
                                // slid into that slot.
                                ForEach(liveEvents, id: \.id) { event in
                                    LiveEventRow(event: event)
                                }
                            }
                        }
                        .padding(.vertical, DS.sm)
                        // Measured on the stack itself rather than on a marker row at
                        // the end: a LazyVStack doesn't build rows that are scrolled
                        // out of sight, so a bottom marker wouldn't exist at exactly
                        // the moment we need to ask where the bottom is.
                        .background(
                            GeometryReader { content in
                                Color.clear
                                    .onChange(of: content.frame(in: .named(Self.streamSpace)).maxY) { _, bottom in
                                        pinnedToBottom = bottom <= viewport.size.height + 24
                                    }
                            }
                        )
                    }
                    .coordinateSpace(name: Self.streamSpace)
                    // Keyed off the newest row, not the count: the stream is a 150-row
                    // sliding window, so once it fills, the count stops changing while
                    // the content keeps moving.
                    .onChange(of: liveEvents.last?.id) { _, _ in
                        guard pinnedToBottom, let last = liveEvents.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onAppear { startRefresh() }
        .onDisappear { stopRefresh() }
    }

    private func startRefresh() {
        // .onAppear can fire again without an intervening .onDisappear (tab swaps,
        // window re-shows). Without this the old timer stayed alive and kept polling
        // the database forever with nothing to render into.
        stopRefresh()
        loadEvents()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            loadEvents()
        }
    }

    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// The tail of today's stream. Bounded in SQL — this runs every 1.5s, and
    /// fetching every event since midnight (text and all) just to keep the last
    /// 150 got heavier with every hour of the day.
    private func loadEvents() {
        // Off the main thread. This is a synchronous `dbPool.read` fired by a 1.5s
        // timer, so a slow one — a large table, contention with a WAL checkpoint —
        // stuttered the whole window on every tick, for the length of the visit.
        let database = appState.database
        let start = Calendar.current.startOfDay(for: Date())
        Task {
            let newest = await Task.detached(priority: .userInitiated) {
                database.fetchCandidates(query: "", since: start, useFTS: false, limit: 150)
            }.value
            guard !Task.isCancelled else { return }
            liveEvents = newest.reversed()   // fetched newest-first; the stream reads oldest→newest
        }
    }

    // MARK: - Nothing kept yet

    /// What the page says before the first capture of the day.
    ///
    /// There was nothing here at all: a header reading "no records", a legend, a rule,
    /// and then a permanently blank scroll area — which is exactly what a broken
    /// window looks like, and it is the first thing a new user sees. What ought to be
    /// said depends entirely on whether mull is actually listening, so it asks before
    /// it speaks.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            StippleRings.roundel()
                .frame(width: 48, height: 48)
                .opacity(0.5)
                .padding(.bottom, DS.xs)
            Text(emptyTitle)
                .font(DS.titleFont)
                .foregroundStyle(DS.ink)
            Text(emptyBody)
                .font(DS.bodyFont)
                .foregroundStyle(DS.inkDim)
                .fixedSize(horizontal: false, vertical: true)
            if !appState.isRecording || appState.isRecordingDegraded {
                Button {
                    AppDelegate.shared?.showSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .font(DS.smallMedium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.moon)
                .padding(.top, DS.xs)
            }
        }
        .frame(maxWidth: DS.readMeasure, alignment: .leading)
        .padding(.horizontal, DS.xl)
        .padding(.top, DS.xxl)
    }

    private var emptyTitle: String {
        if !appState.isRecording { return "mull isn't recording" }
        if appState.isRecordingDegraded { return "Listening, with a gap" }
        return "Nothing kept yet today"
    }

    private var emptyBody: String {
        if !appState.isRecording {
            return "Nothing is being kept, so there is nothing to show. Turn recording back on in Settings and this page fills as you work — on this Mac, in your own files, going nowhere else."
        }
        if appState.isRecordingDegraded {
            return "mull is running, but a permission it needs was withheld, so part of your day isn't reaching this page. Settings › Data says which one, and what it would let mull keep."
        }
        return "mull is listening. The first line appears as soon as you type something, copy something, or move to another app — usually within a minute of starting work."
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: DS.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
        // The dot is the swatch the label defines; announcing them separately gives
        // an unnamed image followed by an orphaned word.
        .accessibilityElement(children: .combine)
    }
}

struct LiveEventRow: View {
    let event: RecordingEvent
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.sm) {
            // A clock reading is one word. 48pt fits `HH:mm:ss` at the base text
            // size, but `microFont` scales with Dynamic Type, and at the larger
            // sizes the string outgrew the column and SwiftUI broke it across two
            // lines — a time cut in half mid-value. `lineLimit(1)` + `fixedSize`
            // says it never wraps and never truncates; the 48pt becomes a floor,
            // so the column widens with the type instead of chopping it.
            Text(timeStr)
                .font(DS.microFont)
                .foregroundStyle(DS.inkFaint)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 48, alignment: .trailing)

            Circle()
                .fill(typeColor)
                .frame(width: 5, height: 5)
                .padding(.top, 5)
                // A 5-point dot in one of six earth dyes is the row's only statement
                // of what kind of event this is, and the key for it is a legend
                // sitting somewhere else on the page. Say the kind here.
                .accessibilityLabel(typeName)

            // A stable height, whatever the row contains. Hover used to expand the
            // text from one line to five, so every row below the pointer shifted
            // down as the mouse crossed the list — the thing you were reaching for
            // moved before you got to it. The full text is still available, in a
            // tooltip, which costs the layout nothing. A *minimum*, not a fixed
            // height: both lines are already pinned to one line each, so the only
            // thing a hard 28pt did was shave the descenders off at larger system
            // text sizes.
            VStack(alignment: .leading, spacing: 0) {
                if let app = event.appName {
                    Text(app)
                        .font(DS.miniMedium)
                        .foregroundStyle(DS.inkFaint)
                        .lineLimit(1)
                }
                Text(detail)
                    .font(DS.captionFont)
                    .foregroundStyle(isHovered ? DS.ink : DS.inkDim)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 28, alignment: .top)

            Spacer()
        }
        .padding(.horizontal, DS.xl)
        .padding(.vertical, 2)
        .background(isHovered ? DS.surfaceHi : Color.clear)
        .onHover { isHovered = $0 }
        .help(hoverText)
    }

    /// What this row actually says.
    ///
    /// `textContent` is empty for every event that carries no text of its own — an app
    /// switch, a window change — and rendering that empty string left a timestamp, a
    /// coloured dot and a blank gap, which reads as a defect rather than as "you moved
    /// to Xcode". Name the event instead of showing nothing. The app name is already
    /// on the line above, so these lines don't repeat it.
    private var detail: String {
        if let text = event.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let title = event.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        switch event.eventType {
        case .appSwitch:  return "Came to the front"
        case .screenText: return "Window changed"
        case .windowBody: return "No readable text on the page"
        case .clipboard:  return "Copied something that wasn't text"
        case .keystroke:  return "Typing"
        case .audio:      return "Audio"
        }
    }

    /// The whole record, for the tooltip — what the single line had to truncate.
    private var hoverText: String {
        var lines: [String] = []
        for value in [event.appName, event.windowTitle] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty, !lines.contains(trimmed) { lines.append(trimmed) }
        }
        if !lines.contains(detail) { lines.append(detail) }
        return lines.joined(separator: "\n")
    }

    /// One formatter for the whole stream. Building a DateFormatter is expensive and
    /// this ran per row, per render, 1.5s apart, over 150 rows.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var timeStr: String {
        Self.timeFormatter.string(from: event.timestamp)
    }

    /// The body of the focused window is the quieter sibling of its title, so it takes
    /// a tint of the same dye. It used to be `DS.taupe`, which IS `DS.eventKeystroke`
    /// — two different kinds of event drawing the identical dot, and no legend entry
    /// could have told them apart.
    static let pageBodyColor = DS.eventWindow.opacity(0.5)

    /// The words for what `typeColor` says in colour — same six cases, same order.
    private var typeName: String {
        switch event.eventType {
        case .keystroke: "Typed"
        case .clipboard: "Copied"
        case .screenText: "Window title"
        case .windowBody: "Page text"
        case .appSwitch: "App switch"
        case .audio: "Audio"
        }
    }

    private var typeColor: Color {
        switch event.eventType {
        case .keystroke: DS.eventKeystroke
        case .clipboard: DS.eventClipboard
        case .screenText: DS.eventWindow
        case .windowBody: Self.pageBodyColor
        case .appSwitch: DS.eventApp
        case .audio: DS.eventAudio
        }
    }
}

// MARK: - Flow Layout (kept for HomeTab/ProfileTab)

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
    /// This folder's path within the vault — the identity its open/closed state is
    /// remembered under. Assembled from the names of its parents rather than taken from
    /// `node.id`, because two folders in different parts of the tree may share a name
    /// and must not share a disclosure state.
    let path: String
    @Binding var expandedFolders: Set<String>
    let rowFor: (mullFile) -> Row

    var body: some View {
        if let file = node.file {
            rowFor(file).tag(FullWindowView.SidebarItem.file(file))
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { expandedFolders.contains(path) },
                set: { isOpen in
                    if isOpen { expandedFolders.insert(path) } else { expandedFolders.remove(path) }
                }
            )) {
                ForEach(node.children) { child in
                    VaultNode(node: child,
                              path: path + "/" + child.name,
                              expandedFolders: $expandedFolders,
                              rowFor: rowFor)
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.moon.opacity(0.75))
            }
        }
    }
}
