import SwiftUI
import UniformTypeIdentifiers

/// The mull window.
///
/// Left sidebar: the four things a person opens. Right main area: the one selected.
///
///   Home      your portrait and today's draft
///   Calendar  what you planned beside what you did
///   Live      the record arriving, as it arrives
///   Chat      ask the record something
///
/// **This used to be a vault browser too**, and about two thirds of this file was
/// that: a file tree over `~/mull`, a markdown editor, import, rename, trash, new
/// note, new folder, conflict resolution, a disk watcher. It went on 2026-08-15
/// (DIRECTION §6.2). The vault is a folder of plain markdown, and Finder, Obsidian
/// and VS Code open one better than mull was ever going to — the author's own
/// `memory/` names two of them. What mull owes the reader is the record, not an
/// editor for it.
///
/// An `About you` page survived the first cut, on the reasoning that `me.pinned.md`
/// is how a person corrects mull's reading of them and only makes sense beside the
/// reading it corrects. It lasted a few hours. Settings › General › "Your answers"
/// already owned that file — an editor, a reset, and the lines mull is declining to
/// publish — so the page's one irreplaceable job had a home, and what was left was
/// me.md rendered read-only: a file written for an agent, shown to the person it is
/// about, on a screen in a calendar app. Two ways to edit one file is the mistake
/// this window kept making; this is the last of them.
struct FullWindowView: View {
    @EnvironmentObject var appState: AppState

    enum SidebarItem: Hashable {
        case home
        case calendar
        case live
        case chat

        /// A stable string to remember this item by between launches.
        var storageKey: String {
            switch self {
            case .home: return "home"
            case .calendar: return "calendar"
            case .live: return "live"
            case .chat: return "chat"
            }
        }
    }

    @State private var selection: SidebarItem? = .home

    /// Whether the sidebar is showing, as `NavigationSplitView` wants it.
    ///
    /// The truth is `appState.sidebarVisible`, not a `@State` here, because the
    /// button that flips it is a title-bar accessory outside this view's tree — see
    /// `AppDelegate.installSidebarToggle` for why it had to leave. Anything other
    /// than `.detailOnly` counts as showing: SwiftUI may hand back `.all` or
    /// `.doubleColumn` for the same visible two-column window.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { appState.sidebarVisible ? .all : .detailOnly },
            set: { appState.sidebarVisible = ($0 != .detailOnly) }
        )
    }

    // MARK: What the window remembers between launches
    //
    // mull is meant to be the study you come back to, and a study you come back to
    // does not reset itself to the front page every time you close the door.
    //
    // @AppStorage rather than @SceneStorage on purpose. @SceneStorage is restored by
    // the system per *scene*, and this window is not one — the app hosts it in a
    // plain NSWindow via NSHostingController (see AppDelegate.showMainWindow),
    // outside any WindowGroup. With no scene to be identified by, @SceneStorage has
    // nowhere to write and behaves as ordinary @State.

    @AppStorage("sidebar.selection") private var storedSelection = SidebarItem.home.storageKey

    @FocusState private var searchFocused: Bool         // ⌘K focuses the sidebar search field
    /// Where the user was when search took them to Home, so Esc can put them back.
    /// Nil whenever there is nowhere to return to.
    @State private var searchReturn: SidebarItem?
    @State private var calendarJumpDate: Date? = nil    // a search hit asked to open this day
    /// Home's reading of the record. Owned here so it survives Home being swapped
    /// out of `detail` — see `HomeAnalysis`.
    @StateObject private var homeAnalysis = HomeAnalysis()
    @State private var searchQuery = ""

    private var mullDir: URL { MullDirectory.root }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebar
                // Drag-resizable, and a real range rather than one pinned number.
                //
                // The pin was a workaround, not a preference. AppKit lays the title
                // bar's *automatic* sidebar-toggle button out against the split
                // divider, so every re-resolution of a min/ideal/max column slid that
                // button sideways, and collapsing the sidebar threw it ~190pt left to
                // the traffic lights. mull now draws the toggle itself, measured from
                // the traffic lights (`AppDelegate.installSidebarToggle`), so nothing
                // is anchored to the divider and the divider is free to move.
                //
                // Before the width, because `.toolbar` wraps the view it is applied
                // to and the column-width preference has to be the outermost thing
                // the split view reads.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
                // Nothing goes in this window's toolbar, and that is deliberate: it is
                // the empty strip mull's own toggle sits in.
        } detail: {
            // A page must not be able to decide how tall the window's split view is.
            //
            // Every detail surface here reports an ideal height equal to all of its
            // content, and that ideal used to travel up into the NavigationSplitView,
            // which then laid itself out at *that* height and overflowed the window in
            // both directions — the sidebar riding up off the top of the screen with
            // it. A GeometryReader takes the size it is offered and never passes a
            // child's appetite upward, so the split view is sized by the window and
            // the page scrolls inside it. (`maxHeight: .infinity` on the page does not
            // do this: it caps how far a view may stretch, not what height it asks
            // for.)
            GeometryReader { _ in
                detail
            }
        }
        // The field belongs to the window; the results are drawn by Home and nowhere
        // else. So typing a query while Calendar, Live or Chat was open used to be
        // swallowed in silence — the box took the text and no surface ever answered
        // it, which reads as "search is broken", not "search is elsewhere". A
        // non-empty query is a request to look something up, so it goes where looking
        // is visible. This is the *only* thing that moves you: clicking or ⌘K-ing into
        // the field does not, because until there is a query there is nothing to show
        // and nothing worth losing your place over.
        .onChange(of: searchQuery) { _, query in
            let asked = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if asked, selection != .home { leaveForSearch() }
        }
        // Esc is the way back out of search, from anywhere in the window.
        .onExitCommand { endSearch() }
        .onChange(of: selection) { _, new in
            storedSelection = (new ?? .home).storageKey
            // Choosing something else yourself ends the round trip. Esc should not then
            // throw you back to a page you had already decided to leave.
            if new != .home { searchReturn = nil }
        }
        .frame(minWidth: 760, minHeight: 560)
        // One in-app place where mull says what it just did — an export, a context
        // copied. A system notification is invisible under Do Not Disturb; this is not.
        .overlay(alignment: .bottom) { noticeBar }
        .animation(.easeOut(duration: 0.18), value: appState.actionNotice)
        .onAppear { restoreSelection() }
    }

    // MARK: - Search — a place you can get to, and get back from

    /// Put the caret in the search field. Invoked by the field's own magnifier and by
    /// its ⌘K equivalent.
    ///
    /// It does *nothing else*. Results are drawn by Home and by nowhere else, so
    /// search does eventually have to move you — but only once you have asked
    /// something, which is what `.onChange(of: searchQuery)` above does.
    private func beginSearch() {
        searchFocused = true
    }

    /// Go to Home on search's behalf, remembering where from.
    private func leaveForSearch() {
        searchReturn = selection
        selection = .home
    }

    /// Put the query away and, if search had moved the user, put them back.
    private func endSearch() {
        searchQuery = ""
        searchFocused = false
        guard let back = searchReturn else { return }
        searchReturn = nil
        selection = back
    }

    // MARK: - Restoring where you were

    /// Reopen whatever was on screen when the window last closed.
    ///
    /// Anything unrecognised lands on Home — including the `file:…` keys the vault
    /// browser used to write here, which is what a window last closed on a note will
    /// be carrying.
    private func restoreSelection() {
        switch storedSelection {
        case SidebarItem.calendar.storageKey: selection = .calendar
        case SidebarItem.live.storageKey: selection = .live
        case SidebarItem.chat.storageKey: selection = .chat
        default: selection = .home
        }
    }

    // MARK: - Notice bar

    @ViewBuilder
    private var noticeBar: some View {
        if let notice = appState.actionNotice {
            HStack(alignment: .firstTextBaseline, spacing: DS.md) {
                Image(systemName: notice.isProblem ? DS.Glyph.problem : DS.Glyph.success)
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
                    Image(systemName: "xmark").font(DS.miniMedium).iconHitTarget()
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — utility actions only (the window title already says "mull").
            // The first acts on ~/mull, the second opens the app's own settings, and
            // a rule between them says where the subject changes.
            HStack(spacing: DS.xs) {
                Spacer()
                Menu {
                    Button { revealVault() } label: { Label("Reveal in Finder", systemImage: DS.Glyph.folder) }
                    Button { exportVault() } label: { Label("Export mull Folder (.zip)…", systemImage: "square.and.arrow.up") }
                } label: {
                    Image(systemName: DS.Glyph.folder)
                        .font(DS.iconBody)
                        .iconHitTarget()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(DS.inkDim)
                .help("Your mull folder — reveal or export")
                .accessibilityLabel("Your mull folder")
                .accessibilityHint("Reveal ~/mull in Finder, or export it as a zip")

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, DS.hair)

                sidebarButton(
                    icon: DS.Glyph.settings,
                    label: "Settings",
                    help: String(localized: "Settings (⌘,)")
                ) { openSettingsWindow() }
            }
            .padding(.horizontal, DS.md)
            .padding(.vertical, DS.sm)

            searchField
                .padding(.horizontal, DS.sm)
                .padding(.bottom, DS.sm)

            Divider()

            // Lend your context to whatever you're talking to.
            //
            // Drawn in the neutral surface, not in tobacco. It used to be a
            // moon-tinted, moon-bordered, moon-lettered pill — which is exactly how
            // this List draws the *selected* row, so the loudest thing in the sidebar
            // was a button that looked like the current selection. Two different
            // meanings cannot share one appearance: the accent belongs to "you are
            // here", and this is "press me".
            Button {
                appState.copyContextToClipboard()
            } label: {
                HStack(spacing: DS.sm) {
                    Image(systemName: DS.Glyph.copy)
                        .font(DS.iconSmall)
                    // One line, always. The column is drag-resizable, so this label
                    // has to survive being narrowed: left to wrap it broke "Copy
                    // context" across four lines and took the row's height with it.
                    Text("Copy context")
                        .font(DS.bodyMedium)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: DS.xs)
                    Text("⇧⌘C")
                        .font(DS.miniMedium)
                        .foregroundStyle(DS.inkFaint)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                .padding(.horizontal, DS.md)
                .padding(.vertical, DS.sm)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusSm)
                        .fill(DS.surface)
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusSm)
                            .strokeBorder(DS.hairline, lineWidth: 0.75))
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.ink)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, DS.xs)
            .help("Copy your me.md, now.md and current context to the clipboard (⇧⌘C)")
            .accessibilityLabel("Copy context")
            .accessibilityHint("Puts mull's picture of your current work on the clipboard, ready to paste into an agent")

            Divider()

            List(selection: $selection) {
                // A `Label` list sizes its icon column to the widest glyph in it, so
                // every row here carries a one-unit glyph.
                Label("Home", systemImage: DS.Glyph.home).tag(SidebarItem.home)
                Label("Calendar", systemImage: DS.Glyph.calendar).tag(SidebarItem.calendar)
                Label("Live", systemImage: DS.Glyph.live).tag(SidebarItem.live)
                Label("Chat", systemImage: DS.Glyph.chat).tag(SidebarItem.chat)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        // `.ignoresSafeArea()` on the fill, not on the sidebar.
        //
        // A plain `.background(DS.canvas)` paints the VStack's bounds, and the VStack
        // is laid out *inside* the column's safe area. The column itself is bigger
        // than that: on macOS 26 the sidebar is an inset panel that runs the whole
        // height of the window. So the ivory stopped where the content's safe area
        // stopped and the panel's own material showed through beyond it.
        //
        // (`containerBackground(_:for: .navigation)` would be the direct way to say
        // this. `.navigation` is iOS-only — it does not compile on macOS.)
        .background(DS.canvas.ignoresSafeArea())
    }

    /// The search field, in one fixed place.
    ///
    /// It used to be `.searchable(placement: .toolbar)`, which on macOS is a
    /// *collapsing* toolbar item: unfocused it is a magnifier glyph, and the click
    /// meant to focus it is the click that expands it into a field — so the control
    /// slid out from under the pointer at the moment it was aimed at. A box you have
    /// to catch is worse than one that is simply always there.
    private var searchField: some View {
        HStack(spacing: DS.sm) {
            // ⌘K rides on the visible glyph rather than on a hidden, empty-titled
            // button in the window's background: a command with no affordance is one
            // only its author knows about, and VoiceOver read the old one out as an
            // unnamed button.
            Button { beginSearch() } label: {
                Image(systemName: DS.Glyph.search)
                    .font(DS.iconSmall)
                    .foregroundStyle(DS.inkFaint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Search (⌘K)")
            .accessibilityLabel("Search")
            .accessibilityHint("Results appear on Home. Esc clears the query and puts you back.")

            // The placeholder has to fit the column at its narrowest. "Search
            // projects, files, keywords…" was cut mid-word, with no ellipsis to say
            // it had been cut; "your records" is the phrase the results view already
            // uses, and the honest one — this searches projects, the activity
            // timeline and daily summaries.
            TextField("Search your records…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(DS.bodyFont)
                .foregroundStyle(DS.ink)
                .focused($searchFocused)
                .accessibilityLabel("Search")

            // Hidden rather than absent while there is nothing to clear: taking the
            // button out of the layout would resize the field the moment you typed.
            Button { endSearch() } label: {
                Image(systemName: DS.Glyph.clearField)
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

    /// Open the macOS Settings window. The app is a menu-bar app whose main window is
    /// a custom NSWindow (outside the SwiftUI scene), so we open Settings via the
    /// AppKit action rather than SettingsLink/openSettings.
    private func openSettingsWindow() {
        AppDelegate.shared?.showSettings()
    }

    /// `help:` is a mouse tooltip and nothing else — it never reaches VoiceOver. An
    /// icon-only button therefore needs `label`/`hint` as well, which is why these
    /// are separate parameters rather than one string reused for both: the tooltip
    /// can carry the key equivalent, the spoken label should not.
    private func sidebarButton(
        icon: String,
        label: String,
        hint: String = "",
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(DS.iconBody)
                .iconHitTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.inkDim)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    // MARK: - Vault actions (it's just a folder of md — Obsidian/Finder open it too)

    /// Reveal the whole ~/mull vault in Finder — the bridge to Obsidian/Bear/etc.
    private func revealVault() {
        NSWorkspace.shared.activateFileViewerSelecting([mullDir])
    }

    /// Take the whole vault away as a zip. The one export the app has, and the reason
    /// Settings does not offer a second one (see `SettingsView`).
    private func exportVault() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mull-folder.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let source = mullDir
        appState.postNotice(String(localized: "Exporting your mull folder…"), detail: String(localized: "Zipping ~/mull. A large folder takes a moment."))
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

        case nil:
            VStack(spacing: DS.lg) {
                Image(systemName: DS.Glyph.file)
                    .font(DS.iconHero.weight(.thin))
                    .foregroundStyle(DS.inkFaint)
                Text("Select a view")
                    .font(DS.titleFont)
                    .foregroundStyle(DS.inkFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.canvas)
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
                legendDot(color: LiveEventRow.pageBodyColor, label: String(localized: "Page text"))
                legendDot(color: DS.eventApp, label: "App")
                legendDot(color: DS.eventAudio, label: String(localized: "Audio"))
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
                    Label("Open Settings", systemImage: DS.Glyph.settings)
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
        if !appState.isRecording { return String(localized: "mull isn't recording") }
        if appState.isRecordingDegraded { return String(localized: "Recording, with a gap") }
        return String(localized: "Nothing kept yet today")
    }

    private var emptyBody: String {
        if !appState.isRecording {
            return String(localized: "Nothing is being kept, so there is nothing to show. Turn recording back on in Settings and this page fills as you work — on this Mac, in your own files, going nowhere else.")
        }
        if appState.isRecordingDegraded {
            return String(localized: "mull is running, but a permission it needs was withheld, so part of your day isn't reaching this page. Settings › Data says which one, and what it would let mull keep.")
        }
        return String(localized: "mull is recording. The first line appears as soon as you type something, copy something, or move to another app — usually within a minute of starting work.")
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
        case .appSwitch:  return String(localized: "Came to the front")
        case .screenText: return String(localized: "Window changed")
        case .windowBody: return String(localized: "No readable text on the page")
        case .clipboard:  return String(localized: "Copied something that wasn't text")
        case .keystroke:  return "Typing"
        case .audio:      return String(localized: "Audio")
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
        case .keystroke: String(localized: "Typed")
        case .clipboard: String(localized: "Copied")
        case .screenText: String(localized: "Window title")
        case .windowBody: String(localized: "Page text")
        case .appSwitch: String(localized: "App switch")
        case .audio: String(localized: "Audio")
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

// MARK: - Flow Layout (kept for HomeTab)

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

