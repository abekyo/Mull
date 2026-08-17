import SwiftUI

// The toolbar button that writes what you did into Calendar.app, and the sheet that
// says what it is about to do before it does it.
//
// The timed mirror and this button write the same events, through the same marker and
// the same reconcile — press it twice and the second press is a no-op. What differs is
// what a press *means*. The mirror reads an absent event as "the user deleted this"
// and never writes it again; a press says the opposite out loud, so it writes over a
// tombstone. Someone who cleared a day and changed their mind has no other way back.
//
// And because a press is a gesture, its writes go through `CalendarWriter` inside one
// undo group: ⌘Z takes back the whole press, which is the promise SECURITY.md makes
// about every write the user asks for by hand.
extension CalendarWeekView {

    /// What a press would do, held between opening the sheet and confirming it, so the
    /// counts the user agreed to are the ones that get written.
    struct ExportProposal: Identifiable {
        let plan: CalendarMirror.Plan
        let calendar: CalendarService.WritableCalendar
        let from: Date
        let to: Date

        /// One identity per proposal, not per range.
        ///
        /// It was keyed on calendar + range, on the reasoning that re-proposing the
        /// same range should replace an open sheet rather than stack one. That buys
        /// nothing — the sheet is modal, so the button cannot be pressed while it is
        /// up — and it means two presses on the *same day* hand `sheet(item:)` the
        /// same identity twice, which is the shape of a well-worn SwiftUI failure to
        /// re-present. A second press on the same day doing nothing was reported once
        /// and cleared by a relaunch, so this is not a confirmed cause; it is the one
        /// thing in the path that could produce exactly that symptom and has no
        /// reason to stay.
        let id = UUID()

        var isEmpty: Bool { plan.isEmpty }
    }

    /// Whether a press could do anything at all, and why not when it could not. A
    /// button that is live and silent is worse than one that is visibly out of reach.
    var exportBlocker: String? {
        if appState.calendar.writableCalendars.isEmpty {
            return String(localized: "No calendar on this Mac accepts new events")
        }
        // `eventRange` is nil in Year, which has no hour axis and so no span to write.
        if eventRange == nil {
            return String(localized: "Pick a day, week or month to write")
        }
        return nil
    }

    @ViewBuilder
    var exportControl: some View {
        let blocker = exportBlocker
        Button { proposeExport() } label: {
            Image(systemName: "square.and.arrow.up")
                .font(DS.bodyFont)
                .foregroundStyle(blocker == nil ? DS.inkDim : DS.inkFaint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocker != nil)
        .pointingHandCursor(blocker == nil)
        .help(blocker ?? String(localized: "Write what you did into Calendar.app"))
        .accessibilityLabel("Write to Calendar")
    }

    /// Work out the plan and open the sheet. Nothing is written here.
    ///
    /// Derived off the main thread: a month on screen is six weeks of blocks to
    /// re-derive, and the window should not stop while that happens.
    func proposeExport() {
        let calendars = appState.calendar.writableCalendars
        guard !calendars.isEmpty, let (from, to) = eventRange else { return }
        // The mirror's calendar if one is set, otherwise EventKit's default — and the
        // sheet names it either way, because "which calendar did that go into" is a
        // question you only think to ask once it is in the wrong one.
        let target = calendars.first { $0.id == Preferences.mirrorCalendarID } ?? calendars[0]
        let mirror = appState.calendarMirror

        Task.detached(priority: .userInitiated) {
            let plan = mirror.manualPlan(in: target.id, from: from, to: to)
            await MainActor.run {
                // A fresh sheet asks the automatic question fresh. See `exportKeepUpdated`.
                exportKeepUpdated = false
                exportProposal = ExportProposal(plan: plan, calendar: target, from: from, to: to)
            }
        }
    }

    /// Write the proposal the user confirmed.
    func performExport(_ proposal: ExportProposal) {
        prepareWriter()
        guard let writer else { return }

        // Before the writes, not after. Pointing the mirror at a calendar is what makes
        // Settings' `onChange` clear the ledger, and a ledger cleared *after* this press
        // would throw away the record of what the press just wrote.
        if exportKeepUpdated {
            Preferences.enableMirror(calendarID: proposal.calendar.id)
            appState.calendarMirror.reschedule()
        }

        // One group, so ⌘Z reverses the press rather than the last event in it.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName(String(localized: "Write to Calendar"))
        defer { undoManager?.endUndoGrouping() }

        var created: [String] = []
        var deleted: [String] = []
        var updated = 0

        for entry in proposal.plan.create {
            let fields = CalendarService.EventFields(title: entry.title, start: entry.start,
                                                     end: entry.end, calendarID: proposal.calendar.id)
            let extras = CalendarService.EventExtras(url: CalendarMirror.marker(entry.key))
            if writer.create(fields, extras: extras, undo: undoManager,
                             name: String(localized: "Write to Calendar")) != nil {
                created.append(entry.key)
            }
        }

        for change in proposal.plan.update {
            guard let before = writer.currentFields(change.handle) else { continue }
            let after = CalendarService.EventFields(title: change.entry.title, start: change.entry.start,
                                                    end: change.entry.end, calendarID: proposal.calendar.id)
            writer.update(ref: writer.ref(for: change.handle), from: before, to: after, undo: undoManager)
            updated += 1
        }

        for removal in proposal.plan.delete {
            guard let fields = writer.currentFields(removal.handle) else { continue }
            writer.delete(ref: writer.ref(for: removal.handle), fields: fields, undo: undoManager)
            deleted.append(removal.key)
        }

        appState.calendarMirror.recordManualResult(proposal.plan, created: created,
                                                   updated: updated, deleted: deleted)
    }

    /// What the press is about to do, in the units the reader is looking at.
    @ViewBuilder
    func exportSheet(_ proposal: ExportProposal) -> some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text("Write what you did to “\(proposal.calendar.title)”?")
                .font(DS.titleFont)

            if proposal.isEmpty {
                Text("Nothing to write. Either this range has no finished work in it, or “\(proposal.calendar.title)” already matches it. Work still in progress is never written.")
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: DS.xs) {
                    if !proposal.plan.create.isEmpty {
                        let n = proposal.plan.create.count
                        Label(counted(n, one: "1 new event", other: "\(n) new events"),
                              systemImage: DS.Glyph.add)
                    }
                    if !proposal.plan.update.isEmpty {
                        let n = proposal.plan.update.count
                        Label(counted(n, one: "1 event brought up to date",
                                      other: "\(n) events brought up to date"),
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    if !proposal.plan.delete.isEmpty {
                        let n = proposal.plan.delete.count
                        Label(counted(n, one: "1 event removed — no longer how the day reads",
                                      other: "\(n) events removed — no longer how the day reads"),
                              systemImage: "trash")
                    }
                }
                .font(DS.captionFont)
                .foregroundStyle(DS.inkDim)

                qualityNote(proposal.plan.quality)

                Text("Only finished work is written, so nothing here will move afterwards. ⌘Z takes the whole write back.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !proposal.calendar.isLocal, !proposal.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").font(DS.miniFont)
                    Text("“\(proposal.calendar.title)” syncs with \(proposal.calendar.accountName). These titles are taken from your window titles and will leave this Mac for that account.")
                        .font(DS.captionFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DS.error)
            }

            if !proposal.isEmpty {
                Divider()
                keepUpdatedBox(proposal)
            }

            HStack {
                Spacer()
                Button("Cancel") { exportProposal = nil }
                    .keyboardShortcut(.cancelAction)
                if !proposal.isEmpty {
                    Button("Write") {
                        performExport(proposal)
                        exportProposal = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(DS.xl)
        .frame(width: 420)
    }

    /// How much of this range mull could actually name.
    ///
    /// On the sheet rather than in a log, because this is the number that decides
    /// whether the feature is worth having and the reader is about to act on it. A day
    /// mull can name is a row of "Mull — CalendarView.swift"; a day it cannot is a row
    /// of "Xcode", eight times. Both are true. Only one of them is worth syncing to a
    /// phone, and until this line nothing anywhere said which one you were getting.
    @ViewBuilder
    func qualityNote(_ quality: CalendarMirror.Quality) -> some View {
        if quality.considered > 0 || quality.tooShort > 0 {
            VStack(alignment: .leading, spacing: DS.hair) {
                if let fraction = quality.namedFraction {
                    Label {
                        Text("\(quality.named) of \(quality.considered) named from what you had open · \(Int((fraction * 100).rounded()))%")
                    } icon: {
                        Image(systemName: "textformat")
                    }
                }
                if quality.fellBack > 0 {
                    Text(counted(quality.fellBack,
                                 one: "1 event will just say the app's name — mull couldn't read a title worth writing.",
                                 other: "\(quality.fellBack) events will just say the app's name — mull couldn't read a title worth writing."))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if quality.tooShort > 0 {
                    let minutes = Int(CalendarMirror.minimumDuration / 60)
                    Text(counted(quality.tooShort,
                                 one: "1 short stretch left out, under \(minutes) minutes.",
                                 other: "\(quality.tooShort) short stretches left out, under \(minutes) minutes."))
                }
            }
            .font(DS.captionFont)
            .foregroundStyle(DS.inkFaint)
        }
    }

    /// The doorway.
    ///
    /// The automatic mirror had exactly one way in — a toggle in a Settings pane, next
    /// to a calendar picker that has to be set separately or the timer does nothing —
    /// and on 2026-08-14 neither preference had ever been written on the machine of the
    /// person who built it, while 37 events sat in the ledger from this button. The
    /// feature was not refused. It was never found.
    ///
    /// So the offer is made here, at the moment somebody has just decided they want
    /// their work in their calendar, and it names the calendar it would use rather than
    /// asking them to go and pick one.
    @ViewBuilder
    func keepUpdatedBox(_ proposal: ExportProposal) -> some View {
        if Preferences.mirrorEnabled, Preferences.mirrorCalendarID == proposal.calendar.id {
            Label {
                Text("mull already keeps “\(proposal.calendar.title)” up to date on its own.")
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .font(DS.captionFont)
            .foregroundStyle(DS.inkDim)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: DS.hair) {
                Toggle(isOn: $exportKeepUpdated) {
                    Text("Keep “\(proposal.calendar.title)” up to date from now on")
                }
                .toggleStyle(.checkbox)
                Text("Finished work is written every hour, once it can no longer change. Anything you delete there stays deleted, and you can stop it in Settings.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
