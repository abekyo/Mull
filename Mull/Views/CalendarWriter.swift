import Foundation

/// Every calendar write mull makes, and its way back.
///
/// The grid gained the ability to create, edit and delete events without gaining
/// any way to take one back — ⌘Z did nothing, and a two-click confirmation on
/// Delete is a speed bump, not a safety net. Writing to somebody's real calendar
/// without an undo is the kind of thing that is fine a hundred times and then
/// isn't.
///
/// Every operation here registers its own inverse, and each inverse registers *its*
/// inverse in turn, so a chain of undos and redos alternates correctly instead of
/// unwinding once and getting stuck.
final class CalendarWriter {

    private let service: CalendarService
    /// Where a failure goes. The caller owns the alert; this owns the wording.
    var onError: ((String) -> Void)?
    /// Called after anything lands, so the grid can read the calendar back.
    var onChange: (() -> Void)?

    init(service: CalendarService) {
        self.service = service
    }

    /// A handle on an event that survives being deleted and made again.
    ///
    /// EventKit hands out a fresh identifier every time a row is written, so undoing
    /// a delete cannot restore the row that was thrown away — it writes a new one,
    /// with a new identifier. An undo chain that stored the *handle* would be
    /// pointing at nothing from its second step onward; storing the box means every
    /// later step follows the event wherever it is recreated.
    final class Ref {
        fileprivate(set) var handle: CalendarService.EventHandle?
        fileprivate init(_ handle: CalendarService.EventHandle?) { self.handle = handle }
    }

    /// One box per event, shared by every operation that touches it.
    ///
    /// Each UI gesture used to mint its own `Ref`. Two boxes for one event are
    /// identical right up until an undo deletes and recreates it: the box that did
    /// the recreating learns the new identifier and the other one goes on pointing
    /// at the row that was thrown away, so the next step of the chain fails with
    /// "that event isn't in your calendar any more" and the rest of the redo is
    /// lost. Handing out the same box for the same event is what keeps a chain of
    /// mixed operations walkable in both directions.
    ///
    /// It grows by one entry per distinct event touched in a window session, and
    /// has to live as long as the undo stack that refers to it.
    private var refs: [CalendarService.EventHandle: Ref] = [:]

    /// The box for an event, made on first sight and shared from then on.
    func ref(for handle: CalendarService.EventHandle) -> Ref {
        if let existing = refs[handle] { return existing }
        let fresh = Ref(handle)
        refs[handle] = fresh
        return fresh
    }

    // MARK: - The three operations

    /// `extras` carries the mirror's marker when the calendar export writes an event,
    /// and is nil for one the user typed. `performDelete` reads whatever is on the
    /// event back before removing it, so the marker survives an undo/redo cycle rather
    /// than being dropped the first time ⌘Z touches it.
    @discardableResult
    func create(_ fields: CalendarService.EventFields,
                extras: CalendarService.EventExtras? = nil,
                undo: UndoManager?, name: String = "New Event") -> Ref? {
        let ref = Ref(nil)
        guard performCreate(ref: ref, fields: fields, extras: extras,
                            undo: undo, name: name) else { return nil }
        return ref
    }

    func update(ref: Ref, from previous: CalendarService.EventFields,
                to fields: CalendarService.EventFields, undo: UndoManager?) {
        performUpdate(ref: ref, from: previous, to: fields, undo: undo, name: String(localized: "Edit Event"))
    }

    func delete(ref: Ref, fields: CalendarService.EventFields, undo: UndoManager?) {
        performDelete(ref: ref, fields: fields, undo: undo, name: String(localized: "Delete Event"))
    }

    /// The fields an event has right now — the "before" half of an edit, read from
    /// EventKit rather than from what the grid last drew, because the grid's copy
    /// can be a minute old and undo has to restore what was really there.
    func currentFields(_ handle: CalendarService.EventHandle) -> CalendarService.EventFields? {
        service.fields(for: handle)
    }

    // MARK: - Each step, and the step that reverses it

    @discardableResult
    private func performCreate(ref: Ref, fields: CalendarService.EventFields,
                               extras: CalendarService.EventExtras?,
                               undo: UndoManager?, name: String) -> Bool {
        do {
            adopt(ref, handle: try service.createEvent(fields, extras: extras))
            register(undo, name: name) { [weak self] undo in
                self?.performDelete(ref: ref, fields: fields, undo: undo, name: name)
            }
            onChange?()
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func performDelete(ref: Ref, fields: CalendarService.EventFields,
                               undo: UndoManager?, name: String) {
        guard let handle = ref.handle else { return }
        do {
            // Read the event back before removing it: what undo has to restore is
            // whatever is in EventKit now, not what mull was handed when the card
            // was drawn — and not only the six fields the editor shows, or the note
            // and the alarm on it come back missing.
            let restore = service.fields(for: handle) ?? fields
            let extras = service.extras(for: handle)
            try service.deleteEvent(handle)
            adopt(ref, handle: nil)
            // An occurrence taken out of a series cannot be put back into it —
            // EventKit exposes no way to remove the exception a `.thisEvent` delete
            // creates — so undo writes a standalone event at that hour instead. The
            // Edit menu says which of the two it is about to do rather than
            // promising to restore something it cannot.
            register(undo, name: extras?.wasRecurring == true ? String(localized: "Delete Occurrence") : name) {
                [weak self] undo in
                self?.performCreate(ref: ref, fields: restore, extras: extras,
                                    undo: undo, name: name)
            }
            onChange?()
        } catch {
            report(error)
        }
    }

    private func performUpdate(ref: Ref, from previous: CalendarService.EventFields,
                               to fields: CalendarService.EventFields,
                               undo: UndoManager?, name: String) {
        guard let handle = ref.handle else { return }
        do {
            try service.updateEvent(handle, to: fields)
            register(undo, name: name) { [weak self] undo in
                self?.performUpdate(ref: ref, from: fields, to: previous, undo: undo, name: name)
            }
            onChange?()
        } catch {
            report(error)
        }
    }

    // MARK: - Plumbing

    /// Point the box at where the event is now, and make sure a later lookup by its
    /// *new* handle finds this same box rather than minting a second one that knows
    /// nothing about the undo steps already registered against the first.
    private func adopt(_ ref: Ref, handle: CalendarService.EventHandle?) {
        ref.handle = handle
        if let handle { refs[handle] = ref }
    }

    /// `UndoManager` calls the handler back on whichever thread invoked `undo()`,
    /// which for a menu item or ⌘Z is the main one — the same place every caller
    /// here already is.
    private func register(_ undo: UndoManager?, name: String,
                          _ inverse: @escaping (UndoManager?) -> Void) {
        guard let undo else { return }
        // The manager is handed back to the inverse rather than captured by it: the
        // closure is stored *on* the manager, so a closure holding the manager (to
        // register the next flip with it) is the manager holding itself, and neither
        // is freed when the window they belonged to goes away.
        undo.registerUndo(withTarget: self) { [weak undo] _ in inverse(undo) }
        // Named so the Edit menu reads "Undo New Event" rather than a bare "Undo",
        // which is the difference between confidence and a guess.
        undo.setActionName(name)
    }

    private func report(_ error: Error) {
        onError?((error as? CalendarService.WriteError)?.errorDescription
                 ?? error.localizedDescription)
    }
}
